#!/bin/bash
# sing-run-system.sh: System utilities for sing-run
# Provides system integration functions (DNS, network interfaces, etc.)

# =============================================================================
# DNS Detection
# =============================================================================

# Get primary system DNS server
_sing_system_get_dns() {
  local servers=($(_sing_system_get_all_dns))
  if [[ ${#servers[@]} -gt 0 ]]; then
    echo "${servers[1]}"
  else
    echo "223.5.5.5"
  fi
}

# Get all unique system DNS servers (one per line)
_sing_system_get_all_dns() {
  local -a servers=()

  if [[ "$OSTYPE" == "darwin"* ]]; then
    servers=($(scutil --dns 2>/dev/null | grep "nameserver" | awk '{print $3}' | sort -u))
  elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    servers=($(grep "^nameserver" /etc/resolv.conf 2>/dev/null | awk '{print $2}' | sort -u))
  fi

  if [[ ${#servers[@]} -eq 0 ]]; then
    echo "223.5.5.5"
    return
  fi

  for s in "${servers[@]}"; do
    echo "$s"
  done
}

# =============================================================================
# System Information
# =============================================================================

# Get OS type in human-readable format
_sing_system_get_os_type() {
  case "$OSTYPE" in
    darwin*)
      echo "macOS"
      ;;
    linux-gnu*)
      if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        echo "$NAME"
      else
        echo "Linux"
      fi
      ;;
    *)
      echo "$OSTYPE"
      ;;
  esac
}

# Check if running with root privileges
_sing_system_is_root() {
  [[ $(id -u) -eq 0 ]]
}

# Check if sudo is available and configured
_sing_system_check_sudo() {
  if ! command -v sudo &> /dev/null; then
    return 1
  fi
  
  # Test if sudo is configured (without actually running as root)
  sudo -n true 2>/dev/null
  return $?
}

# =============================================================================
# Dependency Check
# =============================================================================

# Check if sing-box is installed
_sing_system_check_sing_box() {
  if ! command -v sing-box &> /dev/null; then
    echo "错误: sing-box 未安装" >&2
    echo "" >&2
    echo "安装方法:" >&2
    
    if [[ "$OSTYPE" == "darwin"* ]]; then
      echo "  macOS (Homebrew):" >&2
      echo "    brew install sing-box" >&2
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
      echo "  Debian/Ubuntu:" >&2
      echo "    curl -fsSL https://sing-box.app/gpg.key | sudo gpg --dearmor -o /usr/share/keyrings/sagernet.gpg" >&2
      echo "    echo 'deb [signed-by=/usr/share/keyrings/sagernet.gpg] https://deb.sagernet.org/ * *' | sudo tee /etc/apt/sources.list.d/sagernet.list" >&2
      echo "    sudo apt update && sudo apt install sing-box" >&2
    fi
    
    echo "" >&2
    echo "  或访问: https://github.com/SagerNet/sing-box/releases" >&2
    return 1
  fi
  
  return 0
}

# Check if required tools are installed
_sing_system_check_dependencies() {
  local missing_tools=()
  
  # Check sing-box
  if ! command -v sing-box &> /dev/null; then
    missing_tools+=("sing-box")
  fi
  
  # Check yq (for YAML parsing)
  if ! command -v yq &> /dev/null; then
    missing_tools+=("yq")
  fi
  
  # Check jq (for JSON processing)
  if ! command -v jq &> /dev/null; then
    missing_tools+=("jq")
  fi
  
  if [[ ${#missing_tools[@]} -gt 0 ]]; then
    echo "错误: 缺少必要的工具" >&2
    echo "" >&2
    for tool in "${missing_tools[@]}"; do
      echo "  - $tool" >&2
    done
    echo "" >&2
    return 1
  fi
  
  return 0
}

# =============================================================================
# Network Testing
# =============================================================================

# Test if a port is listening
_sing_system_is_port_listening() {
  local port="$1"
  
  if command -v lsof &> /dev/null; then
    lsof -i ":$port" -sTCP:LISTEN &>/dev/null
  elif command -v netstat &> /dev/null; then
    netstat -an | grep -q "LISTEN.*:$port"
  else
    # Fallback: try to connect
    (echo > /dev/tcp/127.0.0.1/$port) 2>/dev/null
  fi
}

# =============================================================================
# Utility Functions
# =============================================================================

# Cleanup function for interrupted operations
_sing_system_cleanup() {
  # Cleanup logic if needed
  # Silent cleanup - don't print messages
}

# Register cleanup on script exit (only for INT and TERM, not EXIT)
trap _sing_system_cleanup INT TERM
