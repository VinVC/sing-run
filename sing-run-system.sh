#!/bin/zsh
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

_sing_system_is_private_ipv4() {
  local ip="$1"
  [[ "$ip" == *:* ]] && return 1
  [[ "$ip" =~ '^10\.([0-9]{1,3}\.){2}[0-9]{1,3}$' ]] && return 0
  [[ "$ip" =~ '^192\.168\.([0-9]{1,3}\.)[0-9]{1,3}$' ]] && return 0
  if [[ "$ip" =~ '^172\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$' ]]; then
    local second="${match[1]}"
    (( second >= 16 && second <= 31 )) && return 0
  fi
  return 1
}

# Return the private resolver supplied by the current corporate network.
_sing_system_tun_corp_dns() {
  if [[ -n "${SING_RUN_TUN_CORP_DNS:-}" ]]; then
    echo "${SING_RUN_TUN_CORP_DNS%% *}"
    return 0
  fi

  local server
  for server in $(_sing_system_get_all_dns); do
    if _sing_system_is_private_ipv4 "$server"; then
      echo "$server"
      return 0
    fi
  done
  return 1
}

# Avoid local-resolver recursion in TUN mode by making the corporate resolver
# explicit inside sing-box. The host's configured DNS servers remain untouched.
_sing_system_tun_apply_corp_dns() {
  local config="$1"
  local corp_dns
  corp_dns=$(_sing_system_tun_corp_dns) || true
  [[ -z "$corp_dns" ]] && { printf '%s' "$config"; return 0; }

  printf '%s' "$config" | jq --arg server "$corp_dns" '
    .dns.servers = [
      .dns.servers[] |
      if .tag == "internal-dns" then
        {type: "udp", tag: "internal-dns", server: $server}
      else . end
    ]
  '
}

# Resolve proxy bootstrap hostnames before sing-box starts. This avoids a
# circular dependency when the DNS answer contains a CNAME and proxy-dns
# itself depends on the proxy outbound.
_sing_system_resolve_ipv4() {
  local host="$1"

  # TUN may currently have a broken proxy bootstrap path, so query a direct
  # mainland resolver first. `+short` can contain CNAME lines; keep the A row.
  if command -v dig >/dev/null 2>&1; then
    local -a bootstrap_dns
    bootstrap_dns=(${=${SING_RUN_BOOTSTRAP_DNS:-"223.5.5.5 119.29.29.29"}})
    local dns answer
    for dns in "${bootstrap_dns[@]}"; do
      answer=$(dig "@$dns" +time=2 +tries=1 +short "$host" A 2>/dev/null | \
        awk '/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ { value=$0 } END { print value }')
      if [[ -n "$answer" ]]; then
        echo "$answer"
        return 0
      fi
    done
  fi

  # Portable fallback for systems without dig.
  python3 - "$host" <<'PY' 2>/dev/null
import signal
import socket
import sys


def timeout(_signum, _frame):
    raise TimeoutError


signal.signal(signal.SIGALRM, timeout)
signal.alarm(5)
try:
    addresses = socket.getaddrinfo(
        sys.argv[1],
        None,
        socket.AF_INET,
        socket.SOCK_STREAM,
    )
except (OSError, TimeoutError):
    raise SystemExit(1)
finally:
    signal.alarm(0)

for address in addresses:
    ip = address[4][0]
    if ip:
        print(ip)
        raise SystemExit(0)
raise SystemExit(1)
PY
}

# Flush stale resolver answers after TUN routing changes. This intentionally
# does not alter DNS servers configured by DHCP or the user.
_sing_system_flush_dns_cache() {
  [[ "$OSTYPE" == darwin* ]] || return 0

  dscacheutil -flushcache >/dev/null 2>&1 || \
    sudo -n dscacheutil -flushcache >/dev/null 2>&1 || true
  sudo -n killall -HUP mDNSResponder >/dev/null 2>&1 || \
    killall -HUP mDNSResponder >/dev/null 2>&1 || true
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
