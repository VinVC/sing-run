#!/bin/zsh
# sing-run-region.sh: Region and node management for sing-run
# This module handles region switching and per-region node index management

# =============================================================================
# Region Configuration
# =============================================================================

# Region definitions: code -> display_name
typeset -A SING_RUN_REGIONS
SING_RUN_REGIONS[tw]="台湾"
SING_RUN_REGIONS[hk]="香港"
SING_RUN_REGIONS[jp]="日本"
SING_RUN_REGIONS[sg]="新加坡"
SING_RUN_REGIONS[usa]="美国"
SING_RUN_REGIONS[in]="印度"
SING_RUN_REGIONS[kr]="韩国"
SING_RUN_REGIONS[uk]="英国"
SING_RUN_REGIONS[de]="德国"
SING_RUN_REGIONS[ca]="加拿大"
SING_RUN_REGIONS[au]="澳大利亚"
SING_RUN_REGIONS[fr]="法国"
SING_RUN_REGIONS[ru]="俄罗斯"
SING_RUN_REGIONS[tr]="土耳其"
SING_RUN_REGIONS[ar]="阿根廷"
SING_RUN_REGIONS[ua]="乌克兰"

# Region order for display
SING_RUN_REGION_ORDER=(tw hk jp sg usa in kr uk de ca au fr ru tr ar ua)

# =============================================================================
# Region State Management (managed per-instance in sing-run-instance.sh)
# =============================================================================

# =============================================================================
# Region Node Retrieval
# =============================================================================

# Get all nodes for a region from a source's proxies file
# Parameters: 
#   $1 - region code (required)
#   $2 - source name (required, e.g. "ednovas", "iku")
# Returns: Array of node info (name|type|server|port|uuid|password|cipher|alterId)
_sing_region_get_nodes() {
  local region="$1"
  local source="$2"
  local region_name="${SING_RUN_REGIONS[$region]}"
  
  if [[ -z "$region_name" ]]; then
    echo "错误: 未知的地区代码 '$region'" >&2
    return 1
  fi
  
  if [[ -z "$source" ]]; then
    echo "错误: 未指定数据源" >&2
    return 1
  fi
  
  # Determine which proxies file to use
  local proxies_file
  proxies_file=$(_sing_source_get_file "$source")
  if [[ $? -ne 0 ]]; then
    return 1
  fi
  
  if [[ ! -f "$proxies_file" ]]; then
    echo "错误: 找不到 $proxies_file" >&2
    return 1
  fi
  
  # Parse YAML and filter nodes by region name
  local nodes=()
  local node_data
  # Use configured filter pattern (from sources.sh) or default
  local info_pattern="${SING_RUN_NODE_FILTER_PATTERN:-剩余流量|下次重置|套餐到期|用户群|使用说明}"
  
  # Use yq to extract nodes in a format easy to parse with read
  node_data=$(yq e '.proxies[] | select(.name | test("'"$region_name"'")) | 
               select(.name | test("'$info_pattern'") | not) | 
               select((.type == "vmess" and .uuid) or (.type == "ss" and .password)) | 
               [.name, (.type // "vmess"), .server, .port, (.uuid // "-"), (.password // "-"), (.cipher // "-"), (.alterId // 0)] | join("\t")' "$proxies_file" 2>/dev/null)
  
  if [[ -n "$node_data" ]]; then
    local name type server port uuid password cipher alterId
    while IFS=$'\t' read -r name type server port uuid password cipher alterId; do
      if [[ -n "$name" ]]; then
        # Replace "-" placeholders back to empty string
        [[ "$uuid" == "-" ]] && uuid=""
        [[ "$password" == "-" ]] && password=""
        [[ "$cipher" == "-" ]] && cipher=""
        
        # Store in array using a safe internal delimiter
        nodes+=("${name}::::${type}::::${server}::::${port}::::${uuid}::::${password}::::${cipher}::::${alterId}")
      fi
    done <<< "$node_data"
  fi
  
  # Output nodes
  local node
  for node in "${nodes[@]}"; do
    echo "$node"
  done
}

# =============================================================================
# Region Information Display
# =============================================================================

# List all available regions with node counts
_sing_region_list() {
  
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "                      可用地区列表"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  
  local region_code region_name node_count node_output running_status
  for region_code in "${SING_RUN_REGION_ORDER[@]}"; do
    region_name="${SING_RUN_REGIONS[$region_code]}"
    
    # Count nodes for this region using first available source
    node_output=$(_sing_region_get_nodes "$region_code" "${SING_RUN_SOURCE_ORDER[1]}" 2>/dev/null)
    if [[ -n "$node_output" ]]; then
      node_count=$(echo "$node_output" | wc -l | tr -d ' ')
    else
      node_count=0
    fi
    
    # Check if instance is running
    running_status=""
    if _sing_instance_is_running "$region_code"; then
      running_status=" [运行中]"
    fi
    
    printf "  %s  %-6s  (%d 个节点)%s\n" "$region_code" "$region_name" "$node_count" "$running_status"
  done
  
  echo ""
  echo "启动实例: sing-run <区域码>"
}


# =============================================================================
# Interactive Region Selection
# =============================================================================

# Interactive region selection (for sing-run with no arguments)
_sing_region_select_interactive() {
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "              选择要启动的区域                       "
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  
  # Display all available regions with running status
  local idx=1
  for region in "${SING_RUN_REGION_ORDER[@]}"; do
    local name="${SING_RUN_REGIONS[$region]}"
    local running=""
    
    # Check if this region instance is running
    if _sing_instance_is_running "$region"; then
      running=" [运行中]"
    fi
    
    printf "%2d. %s (%s)%s\n" $idx "$name" "$region" "$running"
    ((idx++))
  done
  
  echo ""
  echo -n "请选择区域编号 (1-${#SING_RUN_REGION_ORDER[@]}) 或按 Ctrl+C 取消: "
  read selection
  
  # Validate input
  if [[ ! "$selection" =~ ^[0-9]+$ ]]; then
    echo "错误: 无效的选择"
    return 1
  fi
  
  if [[ $selection -lt 1 || $selection -gt ${#SING_RUN_REGION_ORDER[@]} ]]; then
    echo "错误: 选择超出范围"
    return 1
  fi
  
  # Get the selected region
  local region="${SING_RUN_REGION_ORDER[$selection]}"
  
  # Start the region instance
  echo ""
  _sing_instance_start "$region"
}
