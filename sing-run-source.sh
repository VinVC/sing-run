#!/bin/bash
# sing-run-source.sh: Source management for sing-run
# This module handles proxy source selection and management
#
# All source definitions are loaded from sources.sh (user config).
# This module provides the logic for querying and managing sources.

# =============================================================================
# Source Definition Parser
# =============================================================================

# Parse SING_RUN_SOURCE_DEFS into individual arrays
# Format: "显示名 | 短名(=code) | 订阅URL"
# Called once after sources.sh is loaded
_sing_source_parse_defs() {
  typeset -gA SING_RUN_SOURCES
  typeset -gA SING_RUN_SOURCE_FILES
  typeset -gA SING_RUN_SOURCE_COLORS
  typeset -gA SING_RUN_SOURCE_UPDATE_URL
  typeset -ga SING_RUN_SOURCE_ORDER

  SING_RUN_SOURCE_ORDER=()

  local default_colors=(35 33 36 32 34 31)  # magenta yellow cyan green blue red
  local color_idx=1
  local proxies_dir="${SING_RUN_PROXIES_DIR:-$SING_RUN_DIR}"

  local def
  for def in "${SING_RUN_SOURCE_DEFS[@]}"; do
    # Split by | and trim whitespace
    # Bash: split by | (no here-string garbage, fix array indices 1→0, 2→1, 3→2)
    IFS="|" read -ra parts <<< "$def"
    local name="${parts[0]# }"; name="${name% }"
    local code="${parts[1]// /}"
    local url="${parts[2]# }"; url="${url% }"

    [[ -z "$code" ]] && continue

    SING_RUN_SOURCES[$code]="${name:-$code}"
    SING_RUN_SOURCE_FILES[$code]="$proxies_dir/proxies-$code.yaml"
    SING_RUN_SOURCE_COLORS[$code]="${default_colors[$color_idx]}"
    color_idx=$(( color_idx % ${#default_colors[@]} + 1 ))
    [[ -n "$url" ]] && SING_RUN_SOURCE_UPDATE_URL[$code]="$url"
    SING_RUN_SOURCE_ORDER+=("$code")
  done
}

# Run parser if SING_RUN_SOURCE_DEFS is set (new format)
# Otherwise fall back to legacy individual arrays (backward compat)
if (( ${#SING_RUN_SOURCE_DEFS[@]} > 0 )); then
  _sing_source_parse_defs
fi

# =============================================================================
# Source Query
# =============================================================================

# Get the ANSI color code for a source
_sing_source_get_color() {
  local source="$1"
  echo "${SING_RUN_SOURCE_COLORS[$source]:-33}"
}

# Get the YAML file path for a source
_sing_source_get_file() {
  local source="$1"
  local file="${SING_RUN_SOURCE_FILES[$source]}"
  if [[ -n "$file" ]]; then
    echo "$file"
  else
    echo "错误: 未知的源 '$1'" >&2
    echo "可用的源: ${(j:, :)SING_RUN_SOURCE_ORDER}" >&2
    return 1
  fi
}

# Check if a source file exists
_sing_source_file_exists() {
  local source="$1"
  local file=$(_sing_source_get_file "$source")
  [[ $? -eq 0 ]] && [[ -f "$file" ]]
}

# Get source display name
_sing_source_get_name() {
  local source="$1"
  echo "${SING_RUN_SOURCES[$source]:-$source}"
}

# Check if a source code is valid
_sing_source_is_valid() {
  local source="$1"
  [[ -n "${SING_RUN_SOURCES[$source]}" ]]
}

# =============================================================================
# Instance Source State Management
# =============================================================================

# Get source for a specific instance region
_sing_source_get_instance() {
  local region="$1"
  local instance_state_dir="$SING_RUN_INSTANCES_DIR/$region/state"
  local source_file="$instance_state_dir/source.txt"
  
  if [[ -f "$source_file" ]]; then
    local saved_source
    saved_source=$(cat "$source_file")
    # Validate saved source is still configured
    if _sing_source_is_valid "$saved_source"; then
      echo "$saved_source"
    else
      # Saved source no longer configured, fall back to first available
      echo "${SING_RUN_SOURCE_ORDER[1]}"
    fi
  else
    # Default to the first available source
    echo "${SING_RUN_SOURCE_ORDER[1]}"
  fi
}

# Set source for a specific instance region
_sing_source_set_instance() {
  local region="$1"
  local source="$2"
  
  # Validate source is configured
  if ! _sing_source_is_valid "$source"; then
    echo "错误: 未知的源 '$source'" >&2
    echo "可用的源: ${(j:, :)SING_RUN_SOURCE_ORDER}" >&2
    return 1
  fi
  
  # Validate source file exists
  if ! _sing_source_file_exists "$source"; then
    local file=$(_sing_source_get_file "$source" 2>/dev/null)
    echo "错误: 源文件不存在: ${file:-未知}" >&2
    echo "请先运行 'sing-run update-nodes $source' 更新节点数据" >&2
    return 1
  fi
  
  # Ensure directory exists
  local instance_state_dir="$SING_RUN_INSTANCES_DIR/$region/state"
  mkdir -p "$instance_state_dir"
  
  echo "$source" > "$instance_state_dir/source.txt"
  echo "已设置 $region 实例源为: $(_sing_source_get_name "$source") ($source)"
}

# =============================================================================
# Source Listing and Information
# =============================================================================

# List all available sources with their status and node details
_sing_source_list() {
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "                        可用代理源"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  
  local info_pattern="${SING_RUN_NODE_FILTER_PATTERN:-剩余流量|下次重置|套餐到期|用户群|使用说明}"
  local display_name color file node_count all_names
  local region_name region_nodes active_node inst_source idx first
  
  for source in "${SING_RUN_SOURCE_ORDER[@]}"; do
    display_name="${SING_RUN_SOURCES[$source]}"
    color="${SING_RUN_SOURCE_COLORS[$source]:-33}"
    file=$(_sing_source_get_file "$source")
    
    echo ""
    
    if [[ ! -f "$file" ]]; then
      echo -e "  \033[${color}m[${source}]\033[0m ${display_name}"
      echo "    ⚠️  文件不存在，请运行: sing-run update-nodes $source"
      continue
    fi
    
    node_count=$(yq e '.proxies | length' "$file" 2>/dev/null || echo "0")
    echo -e "  \033[${color}m[${source}]\033[0m \033[1m${display_name}\033[0m · ${node_count} 个节点"
    echo ""
    
    # Get all valid node names with a single yq call (same filter as _sing_region_get_nodes)
    all_names=$(yq e '.proxies[] | select(.name | test("'"$info_pattern"'") | not) | select((.type == "vmess" and .uuid) or (.type == "ss" and .password)) | .name' "$file" 2>/dev/null)
    
    if [[ -z "$all_names" ]]; then
      echo "    (无有效节点)"
      continue
    fi
    
    # Table header
    printf "    \033[2m%-12s  %4s  %s\033[0m\n" "区域" "数量" "节点"
    printf "    \033[2m────────────  ────  ─────────────────────────────────────────\033[0m\n"
    
    # Group by region and display as table rows
    for region_code in "${SING_RUN_REGION_ORDER[@]}"; do
      region_name="${SING_RUN_REGIONS[$region_code]}"
      
      # Filter nodes for this region
      region_nodes=()
      while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        if [[ "$name" == *"$region_name"* ]]; then
          region_nodes+=("$name")
        fi
      done <<< "$all_names"
      
      [[ ${#region_nodes[@]} -eq 0 ]] && continue
      
      # Check if this region is running with this source
      active_node=-1
      if _sing_instance_is_running "$region_code"; then
        inst_source=$(_sing_source_get_instance "$region_code")
        if [[ "$inst_source" == "$source" ]]; then
          active_node=$(_sing_instance_get_node "$region_code")
        fi
      fi
      
      # Build compact node list (show up to 5, then +N)
      local node_list="" max_show=5
      idx=0
      first=1
      for name in "${region_nodes[@]}"; do
        if [[ $idx -ge $max_show ]]; then
          node_list+=" \033[2m(+$((${#region_nodes[@]} - max_show)))\033[0m"
          break
        fi
        if [[ $first -eq 1 ]]; then
          first=0
        else
          node_list+=" \033[2m·\033[0m "
        fi
        if [[ $idx -eq $active_node ]]; then
          node_list+="\033[32m${name}\033[0m"
        else
          node_list+="$name"
        fi
        ((idx++))
      done
      
      # Region name with code: "台湾 tw"
      local region_label="${region_name} \033[2m${region_code}\033[0m"
      printf "    %-8s \033[2m%-3s\033[0m  %4d  " "$region_name" "$region_code" ${#region_nodes[@]}
      echo -e "$node_list"
    done
  done
  
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  运行中的实例"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  
  # Check running instances
  local has_running=0 instance_source source_color node_idx
  for region in "${SING_RUN_REGION_ORDER[@]}"; do
    if _sing_instance_is_running "$region"; then
      has_running=1
      instance_source=$(_sing_source_get_instance "$region")
      region_name="${SING_RUN_REGIONS[$region]}"
      source_color=$(_sing_source_get_color "$instance_source")
      node_idx=$(_sing_instance_get_node "$region")
      printf "  %-6s %-8s \033[${source_color}m%s (%s)\033[0m · 节点 %d\n" "$region" "$region_name" "$(_sing_source_get_name "$instance_source")" "$instance_source" "$node_idx"
    fi
  done
  
  if [[ $has_running -eq 0 ]]; then
    echo "  无运行中的实例"
  fi
  
  echo ""
  echo "  切换源: sing-run <区域> --source <源名称>"
  echo "  查看节点详情: sing-run <区域> nodes"
  echo ""
}

# =============================================================================
# Source Update (subscription download and parsing)
# =============================================================================

# Show help for update-nodes command
_sing_source_update_help() {
  cat << 'EOF'
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                    sing-run update-nodes - 更新节点订阅
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

用法:
  sing-run update-nodes                  # 更新所有源
  sing-run update-nodes all              # 更新所有源（同无参数）
  sing-run update-nodes <源名称>         # 更新指定源
  sing-run update-nodes -h, --help       # 显示此帮助

源特定更新选项:
  sing-run update-nodes <源> --url <URL>       # 从 URL 更新
  sing-run update-nodes <源> --file <路径>     # 从本地文件更新
  sing-run update-nodes <源> --string <BASE64> # 从 base64 字符串更新

示例:
  sing-run update-nodes                  # 更新所有配置的源
  sing-run update-nodes iku              # 只更新 iku 源
  sing-run update-nodes iku --url "https://example.com/sub"
  sing-run update-nodes edn --file ~/nodes.txt

说明:
  此命令从订阅链接、本地文件或 base64 字符串获取节点信息，
  并转换为 sing-box 可用的格式保存到 proxies-<源>.yaml。

  若未指定更新方式，将按以下顺序查找:
  1. 源配置中定义的订阅 URL
  2. data/<源> 文件

EOF
}

# Update a source's proxies YAML from subscription
# Usage: _sing_source_update <source> [--url URL | --file PATH | --string BASE64]
_sing_source_update() {
  local source="$1"
  shift
  
  # Validate source
  if ! _sing_source_is_valid "$source"; then
    echo "错误: 未知的源 '$source'" >&2
    echo "可用的源: ${(j:, :)SING_RUN_SOURCE_ORDER}" >&2
    return 1
  fi
  
  local display_name=$(_sing_source_get_name "$source")
  local target_file=$(_sing_source_get_file "$source")
  
  # Parse input method
  local input_type=""
  local input_value=""
  
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --url)
        input_type="url"
        input_value="$2"
        shift 2
        ;;
      --file)
        input_type="file"
        input_value="$2"
        shift 2
        ;;
      --string)
        input_type="string"
        input_value="$2"
        shift 2
        ;;
      *)
        shift
        ;;
    esac
  done
  
  # If no input type specified, use configured URL
  if [[ -z "$input_type" ]]; then
    local configured_url="${SING_RUN_SOURCE_UPDATE_URL[$source]}"
    if [[ -n "$configured_url" ]]; then
      input_type="url"
      input_value="$configured_url"
    elif [[ -f "$SING_RUN_SCRIPT_DIR/data/$source" ]]; then
      input_type="file"
      input_value="$SING_RUN_SCRIPT_DIR/data/$source"
    else
      echo "错误: 未指定更新方式，且源 '$source' 未配置订阅 URL" >&2
      echo "也未找到本地数据文件: $SING_RUN_SCRIPT_DIR/data/$source" >&2
      echo "" >&2
      echo "用法:" >&2
      echo "  sing-run update-nodes $source --url <订阅URL>" >&2
      echo "  sing-run update-nodes $source --file <文件路径>" >&2
      echo "  sing-run update-nodes $source --string <base64内容>" >&2
      echo "  或将数据文件放入 data/$source" >&2
      return 1
    fi
  fi
  
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "更新源: $display_name ($source)"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  
  local temp_raw="/tmp/sing-run-update-raw-$$.tmp"
  local temp_yaml="/tmp/sing-run-update-yaml-$$.tmp"
  
  # Step 1: Get raw data
  case "$input_type" in
    url)
      echo "从 URL 下载..."
      curl -s -L "$input_value" -o "$temp_raw"
      if [[ $? -ne 0 ]] || [[ ! -s "$temp_raw" ]]; then
        echo "错误: 下载失败" >&2
        rm -f "$temp_raw"
        return 1
      fi
      echo "已下载 $(wc -c < "$temp_raw" | tr -d ' ') 字节"
      ;;
    file)
      if [[ ! -f "$input_value" ]]; then
        echo "错误: 文件不存在: $input_value" >&2
        return 1
      fi
      cp "$input_value" "$temp_raw"
      echo "从文件读取: $input_value ($(wc -c < "$temp_raw" | tr -d ' ') 字节)"
      ;;
    string)
      echo "$input_value" > "$temp_raw"
      echo "从字符串读取 ($(wc -c < "$temp_raw" | tr -d ' ') 字节)"
      ;;
  esac
  
  # Step 2: Detect format and parse
  if grep -qE "^proxies:" "$temp_raw" 2>/dev/null || head -c 500 "$temp_raw" 2>/dev/null | grep -q "port: "; then
    # Clash YAML format
    echo "检测到 Clash 配置格式，正在转换..."
    
    if ! command -v yq &> /dev/null; then
      echo "错误: 需要 yq 工具来处理 YAML" >&2
      rm -f "$temp_raw"
      return 1
    fi
    
    yq e '{"proxies": [.proxies[] | select(.type == "vmess" or .type == "ss") | {"name": .name, "type": .type, "server": .server, "port": .port, "uuid": .uuid, "alterId": (.alterId // 0), "cipher": (.cipher // "auto"), "password": .password, "network": (.network // "tcp"), "tls": (.tls // false)}]}' "$temp_raw" > "$temp_yaml" 2>/dev/null
    
    if [[ $? -ne 0 ]]; then
      echo "错误: YAML 转换失败" >&2
      rm -f "$temp_raw" "$temp_yaml"
      return 1
    fi
  else
    # vmess:// subscription format (possibly base64 encoded)
    echo "检测到订阅格式，正在解析..."
    
    # Process all vmess links in a single Python3 call for speed and encoding safety
    PYTHONIOENCODING=utf-8 python3 -c "
import sys, json, base64

raw = open(sys.argv[1], 'r', encoding='utf-8', errors='replace').read().strip()

# Try base64 decode the whole content
try:
    decoded = base64.b64decode(raw).decode('utf-8', errors='replace')
    if 'vmess://' in decoded:
        raw = decoded
        print('已解码 base64 内容', file=sys.stderr)
except Exception:
    pass

lines = [l.strip() for l in raw.splitlines() if l.strip().startswith('vmess://')]

if not lines:
    print('错误: 未找到 vmess:// 链接', file=sys.stderr)
    sys.exit(1)

out = open(sys.argv[2], 'w', encoding='utf-8')
out.write('proxies:\n')

count = 0
errors = 0
for line in lines:
    b64_data = line[len('vmess://'):]
    try:
        node_json = base64.b64decode(b64_data + '==').decode('utf-8', errors='replace')
        d = json.loads(node_json)
    except Exception:
        errors += 1
        continue

    name = str(d.get('ps', 'Unknown'))
    server = str(d.get('add', ''))
    port = d.get('port', '')
    uuid = str(d.get('id', ''))
    aid = d.get('aid', 0)
    net = str(d.get('net', 'tcp'))
    tls_val = str(d.get('tls', ''))

    if not server or not port or not uuid:
        errors += 1
        continue

    # Escape YAML special chars in name
    safe_name = name.replace('\"', '\\\\\"')

    out.write(f'  - name: \"{safe_name}\"\n')
    out.write(f'    type: vmess\n')
    out.write(f'    server: {server}\n')
    out.write(f'    port: {port}\n')
    out.write(f'    uuid: {uuid}\n')
    out.write(f'    alterId: {aid}\n')
    out.write(f'    cipher: auto\n')
    out.write(f'    network: {net}\n')
    if tls_val and tls_val.lower() not in ('', 'null', 'false', 'none', '0'):
        out.write(f'    tls: true\n')
    count += 1

out.close()

if errors > 0:
    print(f'跳过 {errors} 个无效链接', file=sys.stderr)
print(f'解析到 {count} 个节点', file=sys.stderr)

if count == 0:
    sys.exit(1)
" "$temp_raw" "$temp_yaml" 2>&1
    
    if [[ $? -ne 0 ]]; then
      echo "错误: vmess 解析失败" >&2
      rm -f "$temp_raw" "$temp_yaml"
      return 1
    fi
  fi
  
  # Step 3: Validate result
  if [[ ! -f "$temp_yaml" ]]; then
    echo "错误: 解析失败" >&2
    rm -f "$temp_raw"
    return 1
  fi
  
  local final_count=$(yq e '.proxies | length' "$temp_yaml" 2>/dev/null || echo "0")
  
  if [[ "$final_count" -eq 0 ]]; then
    echo "错误: 未解析到任何有效节点" >&2
    rm -f "$temp_raw" "$temp_yaml"
    return 1
  fi
  
  # Step 4: Save to target file
  local target_dir=$(dirname "$target_file")
  mkdir -p "$target_dir" 2>/dev/null
  
  mv "$temp_yaml" "$target_file"
  rm -f "$temp_raw"
  
  echo ""
  echo "已保存 $final_count 个节点到: $target_file"
  echo ""
  
  # Show region breakdown
  echo "各区域节点数:"
  for region in "${SING_RUN_REGION_ORDER[@]}"; do
    local region_name="${SING_RUN_REGIONS[$region]}"
    local count=$(yq e "[.proxies[] | select(.name | test(\"$region_name\"))] | length" "$target_file" 2>/dev/null || echo "0")
    if [[ "$count" -gt 0 ]]; then
      printf "  %-6s %-10s %d 个\n" "$region" "$region_name" "$count"
    fi
  done
  
  echo ""
  echo "更新完成"
}
