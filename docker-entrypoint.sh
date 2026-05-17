#!/bin/zsh
set -e

# ---------------------------------------------------------------------------
# Prepare sources.sh
# Priority: mounted at /app/sources.sh > copy in /data > example fallback
# ---------------------------------------------------------------------------
if [[ ! -f /app/sources.sh ]]; then
  if [[ -f /data/sources.sh ]]; then
    ln -sf /data/sources.sh /app/sources.sh
  else
    cp /app/sources.sh.example /app/sources.sh
    echo "⚠️  未检测到 sources.sh，使用默认模板"
    echo "   请挂载你的配置: -v ./sources.sh:/app/sources.sh:ro"
    echo ""
  fi
fi

# ---------------------------------------------------------------------------
# Source sing-run (loads all modules, plugins, source defs)
# ---------------------------------------------------------------------------
source /app/sing-run.sh

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
region=""
source_arg=""
node_arg=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --reverse)
      export SING_RUN_REVERSE=true
      shift
      ;;
    --source) source_arg="$2"; shift 2 ;;
    --node)   node_arg="$2"; shift 2 ;;
    --tun)
      echo "⚠️  Docker 模式下不支持 TUN 透明代理"
      echo "   请使用 SOCKS/HTTP 端口代理"
      shift
      ;;
    *)
      if [[ -z "$region" ]] && [[ -n "${SING_RUN_REGIONS[$1]:-}" ]]; then
        region="$1"
      fi
      shift
      ;;
  esac
done

# Env vars override command-line arguments
[[ -n "${SING_RUN_REGION:-}" ]]  && region="$SING_RUN_REGION"
[[ -n "${SING_RUN_SOURCE:-}" ]] && source_arg="$SING_RUN_SOURCE"
[[ -n "${SING_RUN_NODE:-}" ]]   && node_arg="$SING_RUN_NODE"

# ---------------------------------------------------------------------------
# Non-region: delegate to sing-run function (sources, regions, update-nodes…)
# ---------------------------------------------------------------------------
if [[ -z "$region" ]]; then
  sing-run "$@"
  exit $?
fi

# Validate region
if [[ -z "${SING_RUN_REGIONS[$region]:-}" ]]; then
  echo "❌ 未知区域: $region" >&2
  echo "   可用区域: ${(k)SING_RUN_REGIONS}" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Region start: generate config and run sing-box in foreground
# ---------------------------------------------------------------------------
[[ -n "$source_arg" ]] && { _sing_source_set_instance "$region" "$source_arg" || exit 1; }
[[ -n "$node_arg" ]]   && { _sing_instance_set_node "$region" "$node_arg" || exit 1; }

node_index=$(_sing_instance_get_node "$region")
_sing_instance_ensure_dirs "$region"

config_file=$(_sing_instance_gen_config "$region" "$node_index" "false")
[[ $? -ne 0 ]] && { echo "❌ 配置生成失败" >&2; exit 1; }

# Patch listen address: 127.0.0.1 -> 0.0.0.0 for Docker port-forwarding
tmp=$(mktemp)
jq '.inbounds |= map(if .listen == "127.0.0.1" then .listen = "0.0.0.0" else . end)' \
  "$config_file" > "$tmp" && mv "$tmp" "$config_file"

# In reverse mode, force fixed ports (7890/7891) regardless of region
if [[ "${SING_RUN_REVERSE:-}" == "true" ]]; then
  tmp=$(mktemp)
  jq '.inbounds |= map(
    if .tag == "socks-in" then .listen_port = 7890
    elif .tag == "http-in" then .listen_port = 7891
    else . end
  )' "$config_file" > "$tmp" && mv "$tmp" "$config_file"
fi

# Read actual ports from config
read _ _ socks_port http_port _ <<< "$(_sing_instance_get_config "$region")"
if [[ "${SING_RUN_REVERSE:-}" == "true" ]]; then
  socks_port=7890
  http_port=7891
fi

source=$(_sing_source_get_instance "$region")
source_name=$(_sing_source_get_name "$source")

# Resolve node display name
node_display="#${node_index}"
nodes_output=$(_sing_region_get_nodes "$region" "$source" 2>/dev/null)
if [[ -n "$nodes_output" ]]; then
  nodes=()
  while IFS= read -r line; do [[ -n "$line" ]] && nodes+=("$line"); done <<< "$nodes_output"
  if [[ $node_index -lt ${#nodes[@]} ]]; then
    node_line="${nodes[$((node_index + 1))]}"
    node_display="${node_line%%::::*} (#${node_index})"
  fi
fi

mode_label="proxy"
[[ "${SING_RUN_REVERSE:-}" == "true" ]] && mode_label="reverse-proxy (gateway)"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  sing-run Docker"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  模式:  $mode_label"
echo "  区域:  ${SING_RUN_REGIONS[$region]} ($region)"
echo "  SOCKS: 0.0.0.0:$socks_port"
echo "  HTTP:  0.0.0.0:$http_port"
echo "  源:    $source_name ($source)"
echo "  节点:  $node_display"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

exec sing-box run -c "$config_file"
