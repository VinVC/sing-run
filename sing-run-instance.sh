#!/bin/bash
# sing-run-instance.sh: Instance management for sing-run
# Supports running multiple regions simultaneously with different TUN interfaces

# =============================================================================
# Instance Configuration
# =============================================================================

SING_RUN_INSTANCES_DIR="$SING_RUN_DIR/instances"

# Region to instance number mapping (0-based)
typeset -A SING_RUN_INSTANCE_MAP
SING_RUN_INSTANCE_MAP[usa]=0
SING_RUN_INSTANCE_MAP[jp]=1
SING_RUN_INSTANCE_MAP[hk]=2
SING_RUN_INSTANCE_MAP[tw]=3
SING_RUN_INSTANCE_MAP[sg]=4
SING_RUN_INSTANCE_MAP[kr]=5
SING_RUN_INSTANCE_MAP[in]=6
SING_RUN_INSTANCE_MAP[uk]=7
SING_RUN_INSTANCE_MAP[de]=8
SING_RUN_INSTANCE_MAP[ca]=9
SING_RUN_INSTANCE_MAP[au]=10
SING_RUN_INSTANCE_MAP[fr]=11
SING_RUN_INSTANCE_MAP[ru]=12
SING_RUN_INSTANCE_MAP[tr]=13
SING_RUN_INSTANCE_MAP[ar]=14
SING_RUN_INSTANCE_MAP[ua]=15

# =============================================================================
# Instance Configuration Functions
# =============================================================================

# Get instance number for a region
_sing_instance_region_to_num() {
  local region="$1"
  echo "${SING_RUN_INSTANCE_MAP[$region]:-0}"
}

# Find next available utun interface (starting from utun6)
# Checks both system interfaces (ifconfig) and other instances' saved interfaces
_sing_instance_find_utun() {
  local exclude_region="${1:-}"  # Region to exclude from saved interface check
  local start_num=6  # Start from utun6 to avoid conflicts with system interfaces
  local max_num=255
  
  # Collect interfaces already claimed by other running instances
  local -a claimed_interfaces=()
  for region in "${!SING_RUN_REGIONS[@]}"; do
    [[ "$region" == "$exclude_region" ]] && continue
    local iface_file="$SING_RUN_INSTANCES_DIR/$region/state/interface.txt"
    if [[ -f "$iface_file" ]] && _sing_instance_is_running "$region"; then
      claimed_interfaces+=("$(cat "$iface_file")")
    fi
  done
  
  for ((i=start_num; i<=max_num; i++)); do
    local candidate="utun$i"
    # Check if system already has this interface
    if ifconfig "$candidate" &>/dev/null 2>&1; then
      continue
    fi
    # Check if another running instance claimed this interface
    if (( ${claimed_interfaces[(Ie)$candidate]} )); then
      continue
    fi
    echo "$candidate"
    return 0
  done
  
  # Fallback if all are taken (unlikely)
  echo "utun6"
}

# Get saved interface for an instance, or allocate a new one
# Pure function: returns interface name without persisting to disk
_sing_instance_alloc_interface() {
  local region="$1"
  local interface_file="$SING_RUN_INSTANCES_DIR/$region/state/interface.txt"
  
  # Check saved interface - but validate it's not conflicting
  if [[ -f "$interface_file" ]]; then
    local saved_iface=$(cat "$interface_file")
    local conflict=false
    
    # Check if another running instance is using this interface
    for other_region in "${!SING_RUN_REGIONS[@]}"; do
      [[ "$other_region" == "$region" ]] && continue
      local other_file="$SING_RUN_INSTANCES_DIR/$other_region/state/interface.txt"
      if [[ -f "$other_file" ]] && _sing_instance_is_running "$other_region"; then
        if [[ "$(cat "$other_file")" == "$saved_iface" ]]; then
          conflict=true
          break
        fi
      fi
    done
    
    if [[ "$conflict" == "false" ]]; then
      echo "$saved_iface"
      return 0
    fi
    # Conflict detected, re-allocate
  fi
  
  # Allocate new interface (exclude this region from conflict check)
  local interface=$(_sing_instance_find_utun "$region")
  echo "$interface"
}

# Persist interface allocation to disk (call after successful TUN start)
_sing_instance_save_interface() {
  local region="$1"
  local interface="$2"
  local interface_file="$SING_RUN_INSTANCES_DIR/$region/state/interface.txt"
  mkdir -p "$(dirname "$interface_file")"
  echo "$interface" > "$interface_file"
}

# Get instance configuration for a region
# Returns: interface ip_cidr socks_port http_port config_dir
# interface is "_" when TUN is not enabled; callers should treat "_" as empty
_sing_instance_get_config() {
  local region="$1"
  local auto_route="${2:-false}"
  local instance_num=$(_sing_instance_region_to_num "$region")
  
  local interface="_"
  if [[ "$auto_route" == "true" ]]; then
    interface=$(_sing_instance_alloc_interface "$region")
  fi
  local ip_cidr="172.19.$((instance_num * 4)).1/30"
  local socks_port=$((7800 + instance_num * 10))
  local http_port=$((7801 + instance_num * 10))
  local config_dir="$SING_RUN_INSTANCES_DIR/$region"
  
  echo "$interface $ip_cidr $socks_port $http_port $config_dir"
}

# Get instance directory for a region
_sing_instance_get_dir() {
  local region="$1"
  echo "$SING_RUN_INSTANCES_DIR/$region"
}

# Get instance config file path
_sing_instance_get_config_file() {
  local region="$1"
  echo "$SING_RUN_INSTANCES_DIR/$region/config/config.json"
}

# Get instance log file path
_sing_instance_get_log_file() {
  local region="$1"
  echo "$SING_RUN_INSTANCES_DIR/$region/logs/sing-box.log"
}

# Ensure instance directories exist
_sing_instance_ensure_dirs() {
  local region="$1"
  local instance_dir=$(_sing_instance_get_dir "$region")
  
  mkdir -p "$instance_dir/config"
  mkdir -p "$instance_dir/logs"
  mkdir -p "$instance_dir/state"
  mkdir -p "$instance_dir/cache"
}

# =============================================================================
# Instance Node Management
# =============================================================================

# Get node index for an instance (default: 0)
_sing_instance_get_node() {
  local region="$1"
  local node_file="$SING_RUN_INSTANCES_DIR/$region/state/node.txt"
  
  if [[ -f "$node_file" ]]; then
    local val=$(cat "$node_file")
    # Ensure it's a valid number, default to 0 if not
    if [[ "$val" =~ ^[0-9]+$ ]]; then
      echo "$val"
    else
      echo "0"
    fi
  else
    echo "0"
  fi
}

# Set node index for an instance
_sing_instance_set_node() {
  local region="$1"
  local index="$2"
  local state_dir="$SING_RUN_INSTANCES_DIR/$region/state"
  
  mkdir -p "$state_dir"
  
  # Resolve relative indices (next/prev) to actual numbers
  if [[ "$index" == "next" || "$index" == "prev" ]]; then
    local current=$(_sing_instance_get_node "$region")
    local source=$(_sing_source_get_instance "$region")
    local nodes_output=$(_sing_region_get_nodes "$region" "$source")
    local total=0
    while IFS= read -r line; do
      [[ -n "$line" ]] && ((total++))
    done <<< "$nodes_output"
    
    if [[ $total -eq 0 ]]; then
      echo "错误: $region 区域没有可用节点" >&2
      return 1
    fi
    
    if [[ "$index" == "next" ]]; then
      index=$(( (current + 1) % total ))
    else
      index=$(( (current - 1 + total) % total ))
    fi
  fi
  
  echo "$index" > "$state_dir/node.txt"
}

# =============================================================================
# Process Management
# =============================================================================

# Get process ID for an instance
_sing_instance_get_pid() {
  local region="$1"
  local config_file=$(_sing_instance_get_config_file "$region")
  pgrep -f "sing-box.*run.*$config_file" 2>/dev/null | head -1
}

# Check if instance is running
_sing_instance_is_running() {
  local region="$1"
  local pid=$(_sing_instance_get_pid "$region")
  [[ -n "$pid" ]] && ps -p "$pid" > /dev/null 2>&1
}

# =============================================================================
# Configuration Generation
# =============================================================================

# Generate sing-box config for an instance
_sing_instance_gen_config() {
  local region="$1"
  local node_index="${2:-0}"
  local auto_route="${3:-false}"
  
  # Get instance configuration
  read interface ip_cidr socks_port http_port config_dir <<< "$(_sing_instance_get_config "$region" "$auto_route")"
  [[ "$interface" == "_" ]] && interface=""
  
  # Get source for this instance
  local source=$(_sing_source_get_instance "$region")
  
  # Get node information (with source)
  local nodes_output
  nodes_output=$(_sing_region_get_nodes "$region" "$source")
  if [[ $? -ne 0 ]] || [[ -z "$nodes_output" ]]; then
    echo "错误: 无法获取 $region 区域的节点信息" >&2
    echo "请先更新节点: sing-run update-nodes" >&2
    return 1
  fi
  
  # Parse nodes into array
  local nodes=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && nodes+=("$line")
  done <<< "$nodes_output"
  
  if [[ ${#nodes[@]} -eq 0 ]]; then
    echo "错误: $region 区域没有可用节点" >&2
    return 1
  fi
  
  # Validate node index
  if [[ $node_index -ge ${#nodes[@]} ]]; then
    node_index=0
  fi
  
  # Get selected node (zsh arrays are 1-based)
  local node_line="${nodes[$((node_index + 1))]}"
  
  # Ensure instance directories
  _sing_instance_ensure_dirs "$region"
  
  # Generate configuration from template (template auto-selected by TUN mode)
  local config=$(_sing_template_generate_config \
    "" \
    "$interface" \
    "$ip_cidr" \
    "$socks_port" \
    "$http_port" \
    "$node_line" \
    "$config_dir" \
    "$auto_route")
  
  if [[ $? -ne 0 ]]; then
    echo "错误: 配置生成失败" >&2
    return 1
  fi
  
  # Plugin post-config hook: let plugins inject outbounds/routes
  local template_name=""
  [[ "$auto_route" == "true" ]] && template_name="tun" || template_name="proxy"
  config=$(_sing_plugin_post_config "$config" "$template_name" "$auto_route")
  
  # Write configuration to file
  local config_file=$(_sing_instance_get_config_file "$region")
  echo "$config" > "$config_file"
  
  echo "$config_file"
}

# =============================================================================
# Instance Control
# =============================================================================

# Start an instance
_sing_instance_start() {
  local region="$1"
  local node_index="${2:-}"
  local auto_route="${3:-}"
  
  # Validate region
  if [[ -z "${SING_RUN_REGIONS[$region]}" ]]; then
    echo "错误: 未知的地区代码 '$region'"
    echo "可用地区: ${!SING_RUN_REGIONS[@]}"
    return 1
  fi
  
  # Check if already running
  if _sing_instance_is_running "$region"; then
    # If auto_route is specified, restart the instance
    if [[ -n "$auto_route" ]]; then
      echo "🔄 重启 $region 实例以启用 TUN 模式..."
      _sing_instance_stop "$region"
    else
      echo "⚠️  $region 实例已在运行"
      local pid=$(_sing_instance_get_pid "$region")
      echo "PID: $pid"
      return 0
    fi
  fi
  
  # Enforce auto_route exclusivity: only one instance can have auto_route
  if [[ "$auto_route" == "true" ]]; then
    for other_region in "${!SING_RUN_REGIONS[@]}"; do
      [[ "$other_region" == "$region" ]] && continue
      if _sing_instance_is_running "$other_region"; then
        local other_auto_route_file="$SING_RUN_INSTANCES_DIR/$other_region/state/auto_route.txt"
        if [[ -f "$other_auto_route_file" ]] && [[ "$(cat "$other_auto_route_file")" == "true" ]]; then
          echo "⚠️  $other_region 实例正在使用 TUN 代理，先关闭..."
          echo "🔄 重启 $other_region 实例 (关闭 TUN)..."
          # Stop first (while auto_route.txt is still true, so sudo is used)
          _sing_instance_stop "$other_region"
          echo "false" > "$other_auto_route_file"
          _sing_instance_start "$other_region" "" ""
          sleep 1
        fi
      fi
    done
  fi
  
  # Use saved node index if not specified
  if [[ -z "$node_index" ]]; then
    node_index=$(_sing_instance_get_node "$region")
  fi
  
  # Get instance configuration first (needed for config_dir)
  read interface ip_cidr socks_port http_port config_dir <<< "$(_sing_instance_get_config "$region" "$auto_route")"
  [[ "$interface" == "_" ]] && interface=""
  
  # Ensure instance directories exist before any file operations
  _sing_instance_ensure_dirs "$region"

  # Generate configuration
  if [[ "$auto_route" == "true" ]]; then
    echo "正在为 $region 生成配置 (节点索引: $node_index, TUN: ✓)..."
  else
    echo "正在为 $region 生成配置 (节点索引: $node_index)..."
  fi
  
  local config_file
  config_file=$(_sing_instance_gen_config "$region" "$node_index" "$auto_route")
  if [[ $? -ne 0 ]]; then
    return 1
  fi
  
  # Save auto_route state
  if [[ "$auto_route" == "true" ]]; then
    echo "true" > "$config_dir/state/auto_route.txt"
  else
    echo "false" > "$config_dir/state/auto_route.txt"
  fi
  
  # Get source and node info for display
  local source=$(_sing_source_get_instance "$region")
  local nodes_output=$(_sing_region_get_nodes "$region" "$source")
  local nodes=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && nodes+=("$line")
  done <<< "$nodes_output"
  
  local node_line="${nodes[$((node_index + 1))]}"
  local node_parts=("${(@s[::::])node_line}")
  local node_name="${node_parts[1]}"
  
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "              启动 $region 实例                       "
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  if [[ "$auto_route" == "true" ]]; then
    echo "模式: TUN 透明代理 🌐"
    echo "接口: $interface"
    echo "地址: $ip_cidr"
  fi
  echo "SOCKS: 127.0.0.1:$socks_port"
  echo "HTTP: 127.0.0.1:$http_port"
  echo "节点: $node_name"
  echo ""
  
  # Start sing-box
  local log_file=$(_sing_instance_get_log_file "$region")
  
  if [[ "$auto_route" == "true" ]]; then
    # TUN mode: needs sudo for interface creation
    echo "⚠️  需要 root 权限创建 TUN 接口"
    echo ""
    sudo -v
    if [[ $? -ne 0 ]]; then
      echo "❌ 需要 root 权限"
      return 1
    fi
  fi
  
  # Truncate log file to capture fresh output
  : > "$log_file"
  
  # Start sing-box in background
  if [[ "$auto_route" == "true" ]]; then
    sudo nohup sing-box run -c "$config_file" >> "$log_file" 2>&1 &
  else
    nohup sing-box run -c "$config_file" >> "$log_file" 2>&1 &
  fi
  
  # Wait for sing-box to initialize (local rule-sets, should be fast)
  local wait_secs=0
  local max_wait=10
  local started=false
  
  echo "⏳ 等待 sing-box 初始化..."
  
  while [[ $wait_secs -lt $max_wait ]]; do
    sleep 2
    ((wait_secs += 2))
    
    # Check if process crashed
    if ! _sing_instance_is_running "$region"; then
      echo ""
      echo "❌ sing-box 进程已退出"
      if [[ -f "$log_file" ]]; then
        echo "日志输出:"
        tail -5 "$log_file" | sed 's/\x1b\[[0-9;]*m//g'
      fi
      return 1
    fi
    
    # Check log for FATAL errors
    if grep -q "FATAL" "$log_file" 2>/dev/null; then
      echo ""
      echo "❌ sing-box 启动出错"
      local fatal_msg=$(grep "FATAL" "$log_file" | tail -1 | sed 's/\x1b\[[0-9;]*m//g')
      echo "错误: $fatal_msg"
      local fail_pid=$(_sing_instance_get_pid "$region")
      if [[ -n "$fail_pid" ]]; then
        if [[ "$auto_route" == "true" ]]; then
          sudo kill "$fail_pid" 2>/dev/null
        else
          kill "$fail_pid" 2>/dev/null
        fi
      fi
      return 1
    fi
    
    # Check readiness
    if [[ "$auto_route" == "true" ]]; then
      # TUN mode: check if interface is created
      if ifconfig "$interface" &>/dev/null 2>&1; then
        started=true
        break
      fi
    else
      # Proxy mode: check if SOCKS port is listening
      if lsof -i ":$socks_port" -sTCP:LISTEN &>/dev/null 2>&1; then
        started=true
        break
      fi
    fi
    
    printf "\r⏳ 初始化中... (%ds)" $wait_secs
  done
  echo ""
  
  # Final verification
  if _sing_instance_is_running "$region"; then
    local pid=$(_sing_instance_get_pid "$region")
    
    if [[ "$started" == "true" ]]; then
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      echo "✓ $region 实例启动成功 (PID: $pid)"
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    else
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      echo "⚠️  $region 实例进程已启动 (PID: $pid)，但仍在初始化"
      echo "    查看日志: tail -f $log_file"
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    fi
    
    # Save node index
    _sing_instance_set_node "$region" "$node_index"
    
    # Persist interface allocation for TUN mode
    if [[ "$auto_route" == "true" && -n "$interface" ]]; then
      _sing_instance_save_interface "$region" "$interface"
    fi
    
    return 0
  else
    echo "❌ 启动失败，请查看日志: $log_file"
    return 1
  fi
}

# Stop an instance
_sing_instance_stop() {
  local region="$1"
  
  if ! _sing_instance_is_running "$region"; then
    echo "$region 实例未运行"
    return 0
  fi
  
  local pid=$(_sing_instance_get_pid "$region")
  local config_path="$SING_RUN_INSTANCES_DIR/$region/config/config.json"
  echo "正在停止 $region 实例 (PID: $pid)..."
  
  # Determine if instance was started with sudo (TUN mode)
  local auto_route_file="$SING_RUN_INSTANCES_DIR/$region/state/auto_route.txt"
  local use_sudo=false
  if [[ -f "$auto_route_file" ]] && [[ "$(cat "$auto_route_file")" == "true" ]]; then
    use_sudo=true
  fi
  
  # Kill all processes matching this instance's config file
  if [[ "$use_sudo" == "true" ]]; then
    sudo pkill -f "sing-box run -c $config_path" 2>/dev/null || true
  else
    pkill -f "sing-box run -c $config_path" 2>/dev/null || true
  fi
  
  # Wait for ALL matching processes to exit (not just the initial PID)
  local wait_count=0
  while [[ $wait_count -lt 20 ]] && pgrep -f "sing-box.*run.*$config_path" &>/dev/null; do
    sleep 0.5
    ((wait_count++))
  done
  
  # Force kill if any matching process still alive
  if pgrep -f "sing-box.*run.*$config_path" &>/dev/null; then
    echo "强制终止..."
    if [[ "$use_sudo" == "true" ]]; then
      sudo pkill -9 -f "sing-box run -c $config_path" 2>/dev/null || true
    else
      pkill -9 -f "sing-box run -c $config_path" 2>/dev/null || true
    fi
    sleep 1
  fi
  
  if ! _sing_instance_is_running "$region"; then
    # Clean up interface reservation so it can be reused
    local interface_file="$SING_RUN_INSTANCES_DIR/$region/state/interface.txt"
    [[ -f "$interface_file" ]] && rm -f "$interface_file"
    # Wait for kernel to fully release sockets (especially root-owned)
    sleep 2
    echo "✓ $region 实例已停止"
    return 0
  else
    echo "❌ 停止失败"
    return 1
  fi
}

# Restart an instance (preserves TUN/proxy mode)
_sing_instance_restart() {
  local region="$1"
  
  if ! _sing_instance_is_running "$region"; then
    echo "$region 实例未运行"
    return 0
  fi
  
  # Remember auto_route state
  local auto_route_file="$SING_RUN_INSTANCES_DIR/$region/state/auto_route.txt"
  local auto_route=""
  if [[ -f "$auto_route_file" ]] && [[ "$(cat "$auto_route_file")" == "true" ]]; then
    auto_route="true"
  fi
  
  echo "🔄 重启 $region 实例..."
  _sing_instance_stop "$region"
  
  # Wait for port to be fully released
  read _ _ socks_port _ _ <<< "$(_sing_instance_get_config "$region")"
  local wait_count=0
  while [[ $wait_count -lt 10 ]] && lsof -i ":$socks_port" &>/dev/null 2>&1; do
    sleep 1
    ((wait_count++))
  done
  
  # Restart with same settings
  _sing_instance_start "$region" "" "$auto_route"
}

# Restart all running instances
_sing_instance_restart_all() {
  local running_regions=()
  
  for region in "${!SING_RUN_REGIONS[@]}"; do
    if _sing_instance_is_running "$region"; then
      running_regions+=("$region")
    fi
  done
  
  if [[ ${#running_regions[@]} -eq 0 ]]; then
    echo "没有运行中的实例"
    return 0
  fi
  
  echo "🔄 重启 ${#running_regions[@]} 个实例..."
  echo ""
  
  for region in "${running_regions[@]}"; do
    _sing_instance_restart "$region"
    echo ""
  done
}

# Stop all instances
_sing_instance_stop_all() {
  echo "正在停止所有实例..."
  echo ""
  
  local stopped_count=0
  local failed_count=0
  
  for region in "${!SING_RUN_REGIONS[@]}"; do
    if _sing_instance_is_running "$region"; then
      if _sing_instance_stop "$region"; then
        ((stopped_count++))
      else
        ((failed_count++))
      fi
      echo ""
    fi
  done
  
  if [[ $stopped_count -eq 0 ]]; then
    echo "没有运行的实例"
  else
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "已停止 $stopped_count 个实例"
    [[ $failed_count -gt 0 ]] && echo "失败: $failed_count 个实例"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  fi
}

# =============================================================================
# Instance Status and Listing
# =============================================================================

# Show detailed status of all instances
_sing_instance_status() {
  local running_count=0
  local status_lines=()
  
  for region in "${SING_RUN_REGION_ORDER[@]}"; do
    local region_name="${SING_RUN_REGIONS[$region]}"
    
    if _sing_instance_is_running "$region"; then
      ((running_count++))
      
      local pid=$(_sing_instance_get_pid "$region")
      
      # Check auto_route status first (needed for get_config)
      local auto_route_flag=""
      local instance_auto_route="false"
      local auto_route_file="$SING_RUN_INSTANCES_DIR/$region/state/auto_route.txt"
      if [[ -f "$auto_route_file" ]] && [[ "$(cat "$auto_route_file")" == "true" ]]; then
        auto_route_flag=" 🌐"
        instance_auto_route="true"
      fi
      read interface ip_cidr socks_port http_port config_dir <<< "$(_sing_instance_get_config "$region" "$instance_auto_route")"
      [[ "$interface" == "_" ]] && interface=""
      
      # Source info
      local source=$(_sing_source_get_instance "$region")
      local source_name=$(_sing_source_get_name "$source")
      local source_short="$source"
      local source_color=$(_sing_source_get_color "$source")
      
      # Node info
      local node_index=$(_sing_instance_get_node "$region")
      local node_display=""
      local nodes_output=$(_sing_region_get_nodes "$region" "$source" 2>/dev/null)
      local total_nodes=0
      
      if [[ -n "$nodes_output" ]]; then
        local nodes=()
        while IFS= read -r line; do
          [[ -n "$line" ]] && nodes+=("$line")
        done <<< "$nodes_output"
        total_nodes=${#nodes[@]}
        
        if [[ $node_index -lt ${#nodes[@]} ]]; then
          local node_line="${nodes[$((node_index + 1))]}"
          local node_parts=("${(@s[::::])node_line}")
          local node_name="${node_parts[1]}"
          local node_type="${node_parts[2]}"
          local node_server="${node_parts[3]}"
          local node_port="${node_parts[4]}"
          node_display="$node_name"
        fi
      fi
      
      # Line 1: region header with PID
      local header="  \033[1;32m●\033[0m \033[1m${region_name}\033[0m (${region})${auto_route_flag}"
      status_lines+=("${header}  \033[2m·\033[0m  PID ${pid}")
      # Line 2: network info
      if [[ -n "$auto_route_flag" ]]; then
        status_lines+=("    ${interface} · ${ip_cidr} · SOCKS \033[36m:${socks_port}\033[0m · HTTP \033[36m:${http_port}\033[0m")
      else
        status_lines+=("    SOCKS \033[36m:${socks_port}\033[0m · HTTP \033[36m:${http_port}\033[0m")
      fi
      # Line 3: source + node
      if [[ -n "$node_display" ]]; then
        status_lines+=("    \033[${source_color}m${source_name} (${source_short})\033[0m · ${node_display} \033[2m[${node_index}/${total_nodes}]\033[0m · ${node_type} · ${node_server}:${node_port}")
      else
        status_lines+=("    \033[${source_color}m${source_name} (${source_short})\033[0m · 节点 ${node_index}/${total_nodes}")
      fi
      status_lines+=("")
    fi
  done
  
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "                      sing-run 实例状态"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  
  local extra_count=$(_sing_plugin_status_count)
  if [[ -n "$extra_count" && "$extra_count" -gt 0 ]] 2>/dev/null; then
    running_count=$((running_count + extra_count))
  fi
  
  if [[ $running_count -eq 0 ]]; then
    echo "  没有运行中的实例"
  else
    for line in "${status_lines[@]}"; do
      echo -e "$line"
    done
    _sing_plugin_status
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  $running_count 个实例运行中"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  fi
  echo ""
}
