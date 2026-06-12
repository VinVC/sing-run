#!/bin/zsh
# sing-run-node-check.sh: Real proxy health checks for nodes

_sing_node_check_find_free_port() {
  local start="${1:-19080}"
  local port

  for ((port=start; port<start+200; port++)); do
    if ! lsof -iTCP:"$port" -sTCP:LISTEN &>/dev/null 2>&1; then
      echo "$port"
      return 0
    fi
  done

  return 1
}

_sing_node_check_cache_file() {
  local source="$1"
  local region="$2"
  echo "$SING_RUN_DIR/node-checks/$source/$region.json"
}

_sing_node_check_name_hash() {
  local name="$1"
  NODE_NAME="$name" python3 - <<'PY'
import hashlib
import os

print(hashlib.sha256(os.environ["NODE_NAME"].encode("utf-8")).hexdigest())
PY
}

_sing_node_check_save_result() {
  local source="$1"
  local region="$2"
  local idx="$3"
  local node_name="$4"
  local probe_status="$5"
  local latency="$6"
  local reason="$7"
  local checked_at
  checked_at=$(date "+%Y-%m-%d %H:%M:%S %z")

  local cache_file
  cache_file=$(_sing_node_check_cache_file "$source" "$region")
  mkdir -p "$(dirname "$cache_file")"

  CACHE_FILE="$cache_file" \
  SOURCE="$source" \
  REGION="$region" \
  NODE_INDEX="$idx" \
  NODE_HASH="$(_sing_node_check_name_hash "$node_name")" \
  PROBE_STATUS="$probe_status" \
  LATENCY="$latency" \
  REASON="$reason" \
  CHECKED_AT="$checked_at" \
  python3 - <<'PY'
import json
import os
from pathlib import Path

path = Path(os.environ["CACHE_FILE"])
if path.exists():
    try:
        data = json.loads(path.read_text())
    except Exception:
        data = {}
else:
    data = {}

data.setdefault("version", 1)
data["source"] = os.environ["SOURCE"]
data["region"] = os.environ["REGION"]
data["updated_at"] = os.environ["CHECKED_AT"]
nodes = data.setdefault("nodes", {})
nodes[os.environ["NODE_INDEX"]] = {
    "name_hash": os.environ["NODE_HASH"],
    "status": os.environ["PROBE_STATUS"],
    "latency": os.environ["LATENCY"],
    "result": os.environ["REASON"],
    "checked_at": os.environ["CHECKED_AT"],
}

path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
PY
}

_sing_node_check_summary() {
  local source="$1"
  local region="$2"
  local idx="$3"
  local node_name="$4"
  local cache_file node_hash
  cache_file=$(_sing_node_check_cache_file "$source" "$region")
  [[ ! -f "$cache_file" ]] && return
  node_hash=$(_sing_node_check_name_hash "$node_name")

  CACHE_FILE="$cache_file" NODE_INDEX="$idx" NODE_HASH="$node_hash" python3 - <<'PY'
import json
import os
import sys
from datetime import datetime

try:
    with open(os.environ["CACHE_FILE"], "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    sys.exit(0)

node = data.get("nodes", {}).get(os.environ["NODE_INDEX"])
if not node or node.get("name_hash") != os.environ["NODE_HASH"]:
    sys.exit(0)

checked_at = node.get("checked_at", "")
display_time = checked_at
try:
    display_time = datetime.strptime(checked_at, "%Y-%m-%d %H:%M:%S %z").strftime("%m-%d %H:%M")
except Exception:
    pass

status = node.get("status", "-")
latency = node.get("latency", "-")
print(f"{status} {latency} {display_time}")
PY
}

_sing_node_check_probe() {
  local node_line="$1"
  local test_url="$2"
  local timeout="$3"
  local idx="$4"

  local socks_port http_port tmp_dir config_file log_file port_base
  port_base=$((20000 + ($$ % 200) * 100 + idx * 10))
  socks_port=$(_sing_node_check_find_free_port "$port_base") || {
    echo "FAIL|-|无法找到空闲端口"
    return 1
  }
  http_port=$(_sing_node_check_find_free_port $((socks_port + 1))) || {
    echo "FAIL|-|无法找到空闲端口"
    return 1
  }

  tmp_dir="$(mktemp -d)"
  mkdir -p "$tmp_dir/logs" "$tmp_dir/cache" "$tmp_dir/config"
  config_file="$tmp_dir/config/config.json"
  log_file="$tmp_dir/logs/sing-box.log"

  # Force normal proxy mode for probes so existing TUN/system routes are untouched.
  local SING_RUN_REVERSE=""
  if ! _sing_template_generate_config "" "_" "172.19.252.1/30" "$socks_port" "$http_port" "$node_line" "$tmp_dir" false > "$config_file" 2>"$tmp_dir/generate.err"; then
    local err
    err=$(tr '\n' ' ' < "$tmp_dir/generate.err" | sed 's/[[:space:]]\+/ /g')
    rm -rf "$tmp_dir"
    echo "FAIL|-|配置生成失败: ${err:-unknown}"
    return 1
  fi

  if ! sing-box check -c "$config_file" >/dev/null 2>"$tmp_dir/check.err"; then
    local err
    err=$(tr '\n' ' ' < "$tmp_dir/check.err" | sed 's/[[:space:]]\+/ /g')
    rm -rf "$tmp_dir"
    echo "FAIL|-|配置无效: ${err:-unknown}"
    return 1
  fi

  sing-box run -c "$config_file" > "$log_file" 2>&1 &
  local probe_pid=$!
  local ready=0
  local wait_count=0

  while [[ $wait_count -lt 50 ]]; do
    if ! kill -0 "$probe_pid" 2>/dev/null; then
      local err
      err=$(tail -5 "$log_file" 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g')
      rm -rf "$tmp_dir"
      echo "FAIL|-|sing-box 退出: ${err:-unknown}"
      return 1
    fi

    if lsof -iTCP:"$socks_port" -sTCP:LISTEN &>/dev/null 2>&1; then
      ready=1
      break
    fi

    sleep 0.2
    ((wait_count++))
  done

  if [[ $ready -ne 1 ]]; then
    kill "$probe_pid" 2>/dev/null
    wait "$probe_pid" 2>/dev/null
    rm -rf "$tmp_dir"
    echo "FAIL|-|SOCKS 端口未就绪"
    return 1
  fi

  local curl_output curl_status http_code time_total
  curl_output=$(curl -sS -o /dev/null \
    -w "%{http_code} %{time_total}" \
    --connect-timeout "$timeout" \
    --max-time "$timeout" \
    -x "socks5h://127.0.0.1:$socks_port" \
    "$test_url" 2>"$tmp_dir/curl.err")
  curl_status=$?

  kill "$probe_pid" 2>/dev/null
  wait "$probe_pid" 2>/dev/null

  if [[ $curl_status -eq 0 ]]; then
    http_code="${curl_output%% *}"
    time_total="${curl_output#* }"
    if [[ "$http_code" == 2* || "$http_code" == 3* ]]; then
      rm -rf "$tmp_dir"
      echo "OK|${time_total}s|HTTP $http_code"
      return 0
    fi
    rm -rf "$tmp_dir"
    echo "FAIL|${time_total}s|HTTP $http_code"
    return 1
  fi

  local err
  err=$(tr '\n' ' ' < "$tmp_dir/curl.err" | sed 's/[[:space:]]\+/ /g')
  rm -rf "$tmp_dir"
  echo "FAIL|-|${err:-curl 失败}"
  return 1
}

_sing_node_check_help() {
  cat << 'EOF'
用法:
  sing-run <区域> --check-nodes [选项]

选项:
  --source <源>       只检测指定源，默认检测所有源
  --url <URL>         测试 URL，默认 https://www.google.com/generate_204
  --timeout <秒>      单节点 curl 超时，默认 8
  --limit <数量>      只检测前 N 个节点，默认检测全部
  --concurrency <数>  并发检测数量，默认 4
EOF
}

_sing_node_check_run_source() {
  setopt local_options no_monitor no_notify

  local region="$1"
  local source="$2"
  local test_url="$3"
  local timeout="$4"
  local limit="$5"
  local concurrency="${6:-4}"
  local region_name="${SING_RUN_REGIONS[$region]}"

  if [[ -z "$region_name" ]]; then
    echo "错误: 未知的地区代码 '$region'"
    return 1
  fi

  if ! _sing_source_is_valid "$source"; then
    echo "错误: 未知的源 '$source'" >&2
    echo "可用的源: ${(j:, :)SING_RUN_SOURCE_ORDER}" >&2
    return 1
  fi

  if [[ ! "$timeout" =~ ^[0-9]+$ || "$timeout" -lt 1 ]]; then
    echo "错误: --timeout 必须是正整数" >&2
    return 1
  fi

  if [[ ! "$limit" =~ ^[0-9]+$ ]]; then
    echo "错误: --limit 必须是非负整数" >&2
    return 1
  fi

  if [[ ! "$concurrency" =~ ^[0-9]+$ || "$concurrency" -lt 1 ]]; then
    echo "错误: --concurrency 必须是正整数" >&2
    return 1
  fi

  local node_data
  node_data=$(_sing_region_get_nodes "$region" "$source")
  if [[ $? -ne 0 ]] || [[ -z "$node_data" ]]; then
    echo "错误: 无法获取 $region_name ($region) 的节点信息" >&2
    return 1
  fi

  local nodes=()
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] && nodes+=("$line")
  done <<< "$node_data"

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "                  $region_name ($region) 节点可用性检测"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "源: $(_sing_source_get_name "$source") ($source)"
  echo "测试 URL: $test_url"
  echo "超时: ${timeout}s"
  echo "并发: $concurrency"
  echo ""
  printf "  %-4s  %-6s  %-10s  %-40s  %s\n" "#" "状态" "耗时" "节点" "结果"
  printf "  %-4s  %-6s  %-10s  %-40s  %s\n" "──" "────" "────────" "────────────────────────────────────────" "────"

  local result_dir
  result_dir="$(mktemp -d)"
  local idx=0 ok_count=0 fail_count=0 checked=0 running=0 batch_start=0
  local -a batch_indices=() batch_pids=()
  local node_name result probe_status latency reason rest result_file batch_idx pid

  while [[ $idx -lt ${#nodes[@]} ]]; do
    if [[ "$limit" -gt 0 && "$checked" -ge "$limit" ]]; then
      break
    fi

    line="${nodes[$((idx + 1))]}"
    result_file="$result_dir/$idx.result"
    (
      _sing_node_check_probe "$line" "$test_url" "$timeout" "$idx" > "$result_file"
    ) &

    batch_indices+=("$idx")
    batch_pids+=("$!")
    ((running++))
    ((checked++))
    ((idx++))

    if [[ $running -ge $concurrency || $idx -ge ${#nodes[@]} || ( "$limit" -gt 0 && "$checked" -ge "$limit" ) ]]; then
      for pid in "${batch_pids[@]}"; do
        wait "$pid" 2>/dev/null
      done

      for batch_idx in "${batch_indices[@]}"; do
        line="${nodes[$((batch_idx + 1))]}"
        node_name="${line%%::::*}"
        result_file="$result_dir/$batch_idx.result"
        result=$(cat "$result_file" 2>/dev/null)
        [[ -z "$result" ]] && result="FAIL|-|检测进程无输出"

        probe_status="${result%%|*}"
        rest="${result#*|}"
        latency="${rest%%|*}"
        reason="${rest#*|}"

        if [[ "$probe_status" == "OK" ]]; then
          ((ok_count++))
        else
          ((fail_count++))
        fi
        _sing_node_check_save_result "$source" "$region" "$batch_idx" "$node_name" "$probe_status" "$latency" "$reason"
        printf "  %-4d  %-6s  %-10s  %-40s  %s\n" "$batch_idx" "$probe_status" "$latency" "$node_name" "$reason"
      done

      batch_indices=()
      batch_pids=()
      running=0
    fi
  done

  rm -rf "$result_dir"

  echo ""
  echo "结果: $ok_count 个可用，$fail_count 个失败"
  echo "切换节点: sing-run $region --node <编号>"
  echo ""

  [[ $ok_count -gt 0 ]]
}

_sing_node_check_run() {
  local region="$1"
  local source="${2:-}"
  local test_url="${3:-https://www.google.com/generate_204}"
  local timeout="${4:-8}"
  local limit="${5:-0}"
  local concurrency="${6:-4}"
  local success=0
  local checked=0
  local src

  if [[ -n "$source" ]]; then
    _sing_node_check_run_source "$region" "$source" "$test_url" "$timeout" "$limit" "$concurrency"
    return $?
  fi

  for src in "${SING_RUN_SOURCE_ORDER[@]}"; do
    if _sing_source_file_exists "$src"; then
      ((checked++))
      _sing_node_check_run_source "$region" "$src" "$test_url" "$timeout" "$limit" "$concurrency" && success=1
    fi
  done

  [[ $checked -gt 0 && $success -eq 1 ]]
}
