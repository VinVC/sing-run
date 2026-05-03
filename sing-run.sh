#!/bin/bash
# sing-run: Independent sing-box TUN manager
# Native implementation without external dependencies

# =============================================================================
# Configuration
# =============================================================================

SING_RUN_DIR="$HOME/.sing-run"

# =============================================================================
# Load Modules
# =============================================================================

# Get the directory where this script is located
# Use %x to get sourced script path in zsh
SING_RUN_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load user source configuration (must be before other modules)
if [[ -f "$SING_RUN_SCRIPT_DIR/sources.sh" ]]; then
  source "$SING_RUN_SCRIPT_DIR/sources.sh"
else
  echo "警告: 未找到源配置文件 $SING_RUN_SCRIPT_DIR/sources.sh" >&2
  echo "请复制 sources.sh.example 为 sources.sh 并配置:" >&2
  echo "  cp $SING_RUN_SCRIPT_DIR/sources.sh.example $SING_RUN_SCRIPT_DIR/sources.sh" >&2
fi

# Source the system utilities module
if [[ -f "$SING_RUN_SCRIPT_DIR/sing-run-system.sh" ]]; then
  source "$SING_RUN_SCRIPT_DIR/sing-run-system.sh"
else
  echo "错误: 无法加载 sing-run-system.sh 模块" >&2
fi

# Source the rules management module
if [[ -f "$SING_RUN_SCRIPT_DIR/sing-run-rules.sh" ]]; then
  source "$SING_RUN_SCRIPT_DIR/sing-run-rules.sh"
else
  echo "错误: 无法加载 sing-run-rules.sh 模块" >&2
fi

# Source the template processing module
if [[ -f "$SING_RUN_SCRIPT_DIR/sing-run-template.sh" ]]; then
  source "$SING_RUN_SCRIPT_DIR/sing-run-template.sh"
else
  echo "错误: 无法加载 sing-run-template.sh 模块" >&2
fi

# Source the region management module
if [[ -f "$SING_RUN_SCRIPT_DIR/sing-run-region.sh" ]]; then
  source "$SING_RUN_SCRIPT_DIR/sing-run-region.sh"
else
  echo "错误: 无法加载 sing-run-region.sh 模块" >&2
fi

# Source the instance management module
if [[ -f "$SING_RUN_SCRIPT_DIR/sing-run-instance.sh" ]]; then
  source "$SING_RUN_SCRIPT_DIR/sing-run-instance.sh"
else
  echo "错误: 无法加载 sing-run-instance.sh 模块" >&2
fi

# Source the source management module (load after instance to access state dirs)
if [[ -f "$SING_RUN_SCRIPT_DIR/sing-run-source.sh" ]]; then
  source "$SING_RUN_SCRIPT_DIR/sing-run-source.sh"
else
  echo "错误: 无法加载 sing-run-source.sh 模块" >&2
fi

# Load plugin framework and discover plugins from SING_PLUGIN_PATH
if [[ -f "$SING_RUN_SCRIPT_DIR/sing-run-plugin.sh" ]]; then
  source "$SING_RUN_SCRIPT_DIR/sing-run-plugin.sh"
  _sing_plugin_load_all
else
  echo "错误: 无法加载 sing-run-plugin.sh 模块" >&2
fi

# =============================================================================
# Help
# =============================================================================

_sing_run_show_help() {
  cat << 'EOF'
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                    sing-run - sing-box TUN Manager                       
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

核心概念:
  每个实例 = (区域, 源, 节点索引)
  一个区域只能运行一个实例
  所有操作都基于区域

基础命令:
  sing-run                          # 交互式选择区域
  sing-run <区域>                   # 启动/重启指定区域
  sing-run <区域> [选项]            # 启动并设置源/节点
  sing-run stop [区域]              # 停止实例
  sing-run restart [区域]           # 重启实例（保持当前模式）
  sing-run status                   # 查看所有实例

启动实例:
  sing-run jp                       # 启动日本（使用保存的源和节点）
  sing-run jp --source <源>         # 日本使用指定源
  sing-run jp --node 2              # 日本使用节点 2
  sing-run jp --tun                 # 启用 TUN 透明代理（全局路由）
  sing-run jp --source <源> --node 2 # 完整指定

节点操作（必须指定区域）:
  sing-run jp --node next           # 日本切换下一个节点
  sing-run jp --node prev           # 日本切换上一个节点
  sing-run jp --node 5              # 日本切换到节点 5
  sing-run jp --nodes               # 列出日本的所有节点

源操作（必须指定区域）:
  sing-run jp --source <源>         # 日本切换指定源
  sing-run sources                  # 查看可用源

停止实例:
  sing-run stop jp                  # 停止日本实例
  sing-run stop                     # 停止所有实例
  sing-run -x                       # 停止所有实例（兼容 sing-tun）
  sing-run untun                    # 关闭 TUN 透明代理（自动重启）

重启实例:
  sing-run restart jp               # 重启日本实例（保持 TUN/代理模式）
  sing-run restart                  # 重启所有运行中的实例

查看信息:
  sing-run status                   # 查看所有运行的实例
                                    # 🌐 符号表示启用了透明代理
  sing-run regions                  # 列出所有可用区域
  sing-run sources                  # 列出所有可用源

维护:
  sing-run update-nodes              # 更新所有源的节点列表
  sing-run update-nodes <源>        # 更新指定源的节点列表
  sing-run update-nodes <源> --url <URL>  # 从指定 URL 更新
  sing-run update-nodes <源> --file <文件> # 从本地文件更新
  sing-run update-rules             # 更新路由规则集 (首次自动下载)

域名规则管理:
  sing-run --rules                  # 显示自定义域名规则
  sing-run --add-proxy <domain>     # 添加域名到代理列表
  sing-run --add-direct <domain>    # 添加域名到直连列表（本地 DNS + 直连）
  sing-run --del-rule <domain>      # 删除域名规则

插件:
  sing-run plugin                   # 查看已加载的插件
EOF
  local has_plugins=${#_sing_plugin_registry}
  if [[ $has_plugins -gt 0 ]]; then
    echo ""
    echo "  已加载的插件命令 (sing-run <命令> -h 查看详情):"
    _sing_plugin_help
  fi
  cat << 'EOF'

可用地区:
  tw    台湾      hk    香港      jp    日本
  sg    新加坡    usa   美国      in    印度
  kr    韩国      uk    英国      de    德国
  ca    加拿大    au    澳大利亚  fr    法国
  ru    俄罗斯    tr    土耳其    ar    阿根廷
  ua    乌克兰

示例工作流:
  1. sing-run                       # 交互式选择并启动
  2. sing-run jp                    # 启动日本实例
  3. sing-run usa                   # 同时启动美国实例
  4. sing-run jp --node next        # 日本切换节点
  5. sing-run status                # 查看所有实例状态
  6. sing-run stop usa              # 停止美国，保留日本

说明:
  • 每个区域有独立的 TUN 接口、IP 和端口
  • 每个区域可以配置不同的源
  • 域名规则对所有实例生效
  • 一个区域同时只能运行一个实例
  
重要提示:
  • 首次启动需等待 10-30 秒下载路由规则集
  • 使用 --tun 会自动重启实例
  • 查看日志: tail -f ~/.sing-run/instances/<region>/logs/sing-box.log

资源分配:
  • TUN 接口: 动态分配 (从 utun6 开始，自动查找可用接口)
  • IP 地址:   172.19.X.1/30 (X 根据区域编号计算)
  • 端口分配:
    usa → SOCKS: 7800, HTTP: 7801
    jp  → SOCKS: 7810, HTTP: 7811
    hk  → SOCKS: 7820, HTTP: 7821
    tw  → SOCKS: 7830, HTTP: 7831
    sg  → SOCKS: 7840, HTTP: 7841
    ... (其他区域以此类推，每区域间隔 10)

EOF
}

# =============================================================================
# Helper Functions
# =============================================================================

# Handle region-specific commands
_sing_run_handle_region() {
  local region="$1"
  shift
  
  # Parse region-specific arguments
  local source_arg=""
  local node_arg=""
  local auto_route_arg=""
  local action="start"
  
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --source)
        source_arg="$2"
        shift 2
        ;;
      --node)
        node_arg="$2"
        shift 2
        ;;
      --tun)
        auto_route_arg="true"
        shift
        ;;
      --nodes)
        action="list_nodes"
        shift
        ;;
      *)
        shift
        ;;
    esac
  done
  
  case "$action" in
    start)
      # Set source if specified
      if [[ -n "$source_arg" ]]; then
        _sing_source_set_instance "$region" "$source_arg"
        if [[ $? -ne 0 ]]; then
          return 1
        fi
      fi
      
      # Set node if specified
      if [[ -n "$node_arg" ]]; then
        _sing_instance_set_node "$region" "$node_arg"
        if [[ $? -ne 0 ]]; then
          return 1
        fi
      fi
      
      # If node or source changed on a running instance, restart it
      local need_restart=""
      if _sing_instance_is_running "$region"; then
        if [[ -n "$node_arg" || -n "$source_arg" ]]; then
          need_restart="true"
        fi
      fi
      
      if [[ -n "$need_restart" ]]; then
        # Preserve existing auto_route state if not explicitly set
        if [[ -z "$auto_route_arg" ]]; then
          local auto_route_file="$SING_RUN_INSTANCES_DIR/$region/state/auto_route.txt"
          if [[ -f "$auto_route_file" ]] && [[ "$(cat "$auto_route_file")" == "true" ]]; then
            auto_route_arg="true"
          fi
        fi
        
        echo "🔄 重启 $region 实例..."
        _sing_instance_stop "$region"
        # Wait for port to be fully released before restarting
        read _ _ socks_port _ _ <<< "$(_sing_instance_get_config "$region")"
        local wait_count=0
        while [[ $wait_count -lt 10 ]] && lsof -i ":$socks_port" &>/dev/null 2>&1; do
          sleep 1
          ((wait_count++))
        done
      fi
      
      # Start the instance
      _sing_instance_start "$region" "" "$auto_route_arg"
      ;;
    list_nodes)
      _sing_run_list_nodes "$region"
      ;;
  esac
}

# Disable auto-route on whichever instance has it, restart without
_sing_run_disable_auto_route() {
  local found=0
  
  for region in "${!SING_RUN_REGIONS[@]}"; do
    local auto_route_file="$SING_RUN_INSTANCES_DIR/$region/state/auto_route.txt"
    if [[ -f "$auto_route_file" ]] && [[ "$(cat "$auto_route_file")" == "true" ]] && _sing_instance_is_running "$region"; then
      found=1
      echo "🔄 关闭 $region 的 TUN 代理，重启中..."
      _sing_instance_stop "$region"
      echo "false" > "$auto_route_file"
      # Wait for port to be fully released (TUN/sudo instances need extra time)
      read _ _ socks_port _ _ <<< "$(_sing_instance_get_config "$region")"
      local wait_count=0
      while [[ $wait_count -lt 10 ]] && lsof -i ":$socks_port" &>/dev/null 2>&1; do
        sleep 1
        ((wait_count++))
      done
      _sing_instance_start "$region" "" ""
    fi
  done
  
  if [[ $found -eq 0 ]]; then
    echo "当前没有实例启用 TUN 代理"
  fi
}

# Prompt user to restart running instances after rule changes
_sing_run_prompt_restart() {
  # Check if any instances are running
  local running_regions=()
  for region in "${!SING_RUN_REGIONS[@]}"; do
    if _sing_instance_is_running "$region"; then
      running_regions+=("$region")
    fi
  done
  
  if [[ ${#running_regions[@]} -eq 0 ]]; then
    return 0
  fi
  
  echo ""
  echo "当前有 ${#running_regions[@]} 个运行中的实例: ${running_regions[*]}"
  echo -n "是否重启使规则生效? [y/N] "
  
  local answer
  read -r answer
  
  if [[ "$answer" == "y" || "$answer" == "Y" ]]; then
    echo ""
    _sing_instance_restart_all
  fi
}

# Handle domain rule commands
_sing_run_handle_rules() {
  local cmd="$1"
  shift
  
  local result=0
  case "$cmd" in
    --rules)
      _sing_rules_list
      return
      ;;
    --add-proxy)
      _sing_rules_add_proxy "$1"
      result=$?
      ;;
    --add-direct)
      _sing_rules_add_direct "$1"
      result=$?
      ;;
    --del-rule)
      _sing_rules_delete "$1"
      result=$?
      ;;
    *)
      echo "错误: 未知的规则命令 '$cmd'"
      return 1
      ;;
  esac
  
  # If rule change succeeded, offer to restart running instances
  if [[ $result -eq 0 ]]; then
    _sing_run_prompt_restart
  fi
  
  return $result
}

# List nodes for a specific region
_sing_run_list_nodes() {
  local region="$1"
  local region_name="${SING_RUN_REGIONS[$region]}"
  
  if [[ -z "$region_name" ]]; then
    echo "错误: 未知的地区代码 '$region'"
    return 1
  fi
  
  # Get active source and node for this region
  local active_source active_node_idx
  active_source=$(_sing_source_get_instance "$region")
  active_node_idx=$(_sing_instance_get_node "$region")
  local is_running=0
  _sing_instance_is_running "$region" && is_running=1
  
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "                    $region_name ($region) 节点列表"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  
  local total_nodes=0
  local source name type server port uuid password cipher alterId
  local node_data idx marker color
  
  for source in "${SING_RUN_SOURCE_ORDER[@]}"; do
    local source_name=$(_sing_source_get_name "$source")
    local source_color=$(_sing_source_get_color "$source")
    local source_file=$(_sing_source_get_file "$source")
    
    [[ ! -f "$source_file" ]] && continue
    
    # Get nodes for this region from this source
    node_data=$(_sing_region_get_nodes "$region" "$source" 2>/dev/null)
    [[ -z "$node_data" ]] && continue
    
    # Count nodes
    local count=0
    while IFS= read -r _line; do
      [[ -n "$_line" ]] && ((count++))
    done <<< "$node_data"
    
    total_nodes=$((total_nodes + count))
    
    # Source header
    local active_tag=""
    if [[ $is_running -eq 1 ]] && [[ "$source" == "$active_source" ]]; then
      active_tag=" \033[32m[当前]\033[0m"
    fi
    echo ""
    echo -e "  \033[${source_color}m${source_name} (${source})\033[0m · ${count} 个节点${active_tag}"
    echo ""
    
    # Table header
    printf "    \033[2m%-4s  %-40s  %s\033[0m\n" "#" "名称" "类型"
    printf "    \033[2m%-4s  %-40s  %s\033[0m\n" "──" "────────────────────────────────────────" "────"
    
    # Parse and display each node
    idx=0
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      
      # Parse ::::  delimited fields
      name="${line%%::::*}"
      local rest="${line#*::::}"
      type="${rest%%::::*}"
      
      # Determine marker for active node
      marker="  "
      if [[ $is_running -eq 1 ]] && [[ "$source" == "$active_source" ]] && [[ $idx -eq $active_node_idx ]]; then
        marker="\033[32m→\033[0m "
      fi
      
      printf "  ${marker}\033[2m%2d\033[0m  %-40s  \033[2m%s\033[0m\n" $idx "$name" "$type"
      ((idx++))
    done <<< "$node_data"
  done
  
  if [[ $total_nodes -eq 0 ]]; then
    echo ""
    echo "  未找到 $region_name 节点"
  fi
  
  echo ""
}

# =============================================================================
# Main Entry Point
# =============================================================================

sing-run() {
  local first_arg="$1"
  
  # No arguments: interactive region selection
  if [[ -z "$first_arg" ]]; then
    _sing_region_select_interactive
    return
  fi
  
  # Plugin pre-command hook: let plugins intercept commands
  _sing_plugin_pre_command "$@" && return 0
  
  # Parse first argument
  case "$first_arg" in
    # Global commands
    stop|-x)
      if [[ -n "$2" ]]; then
        _sing_instance_stop "$2"
      else
        _sing_plugin_stop_all
        _sing_instance_stop_all
      fi
      ;;
    plugin)
      echo ""
      echo "已加载的插件:"
      _sing_plugin_list
      echo ""
      ;;
    status)
      # Show all running instances
      _sing_instance_status
      ;;
    restart)
      # Restart instances
      if [[ -n "$2" ]]; then
        # Restart specific region
        _sing_instance_restart "$2"
      else
        # Restart all running instances
        _sing_instance_restart_all
      fi
      ;;
    regions)
      # List all available regions
      _sing_region_list
      ;;
    sources)
      # List all available sources
      _sing_source_list
      ;;
    untun)
      # Disable TUN transparent proxy on whichever instance has it
      _sing_run_disable_auto_route
      ;;
    update-rules)
      # Force update rule-set files
      _sing_ruleset_update
      ;;
    update-nodes)
      # Update source node subscription
      shift
      # Check for help flag first
      if [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
        _sing_source_update_help
      elif [[ -z "$1" ]]; then
        # No source specified: update all (single source = just update it)
        for s in "${SING_RUN_SOURCE_ORDER[@]}"; do
          _sing_source_update "$s"
          echo ""
        done
      elif [[ "$1" == "all" ]]; then
        shift
        for s in "${SING_RUN_SOURCE_ORDER[@]}"; do
          _sing_source_update "$s" "$@"
          echo ""
        done
      else
        _sing_source_update "$@"
      fi
      ;;
    --help|-h)
      # Show help
      _sing_run_show_help
      ;;
    --rules|--add-proxy|--add-direct|--del-rule)
      # Domain rule management
      _sing_run_handle_rules "$@"
      ;;
    
    # Region-specific commands
    *)
      # Check if it's a valid region code
      if [[ -n "${SING_RUN_REGIONS[$first_arg]}" ]]; then
        local region="$first_arg"
        shift
        _sing_run_handle_region "$region" "$@"
      else
        echo "错误: 未知命令或区域 '$first_arg'"
        echo "使用 'sing-run --help' 查看帮助"
        echo ""
        echo "提示:"
        echo "  sing-run regions     # 查看所有可用区域"
        echo "  sing-run --help      # 查看完整帮助"
        return 1
      fi
      ;;
  esac
}

if [ -n "${BASH_SOURCE[0]:-}" ] && [ "${BASH_SOURCE[0]}" = "$0" ]; then
  sing-run "$@"
fi
