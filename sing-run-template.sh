#!/bin/zsh
# sing-run-template.sh: JSON template processing for sing-run
# Provides template-based configuration generation

# =============================================================================
# Template Configuration
# =============================================================================

# Template directory (SING_RUN_SCRIPT_DIR should be set by main script)
SING_RUN_TEMPLATES_DIR="${SING_RUN_SCRIPT_DIR:-${0:A:h}}/templates"

# =============================================================================
# Template Loading
# =============================================================================

# Load a template file
_sing_template_load() {
  local template_name="$1"
  local template_file="$SING_RUN_TEMPLATES_DIR/${template_name}.json"
  
  if [[ ! -f "$template_file" ]]; then
    echo "错误: 模板文件不存在: $template_file" >&2
    return 1
  fi
  
  cat "$template_file"
}

# =============================================================================
# Outbound Configuration Generation
# =============================================================================

# Generate outbound configuration JSON from node info
_sing_template_generate_outbound() {
  local node_line="$1"
  
  # Parse node information
  local node_parts=("${(@s[::::])node_line}")
  local node_name="${node_parts[1]}"
  local node_type="${node_parts[2]}"
  local node_server="${node_parts[3]}"
  local node_port="${node_parts[4]}"
  local node_uuid="${node_parts[5]}"
  local node_password="${node_parts[6]}"
  local node_cipher="${node_parts[7]}"
  local node_alter_id="${node_parts[8]}"
  
  # Generate JSON based on node type
  # Note: "domain_resolver": "direct-dns" is critical to avoid DNS loopback.
  # Without it, resolving the proxy server's domain goes through proxy-dns
  # which depends on the proxy itself, creating a circular dependency.
  if [[ "$node_type" == "ss" ]]; then
    # Shadowsocks
    cat <<EOF
{
            "type": "shadowsocks",
            "tag": "proxy",
            "server": "$node_server",
            "server_port": $node_port,
            "method": "${node_cipher:-aes-256-gcm}",
            "password": "$node_password",
            "domain_resolver": "direct-dns"
        }
EOF
  else
    # VMess (default)
    cat <<EOF
{
            "type": "vmess",
            "tag": "proxy",
            "server": "$node_server",
            "server_port": $node_port,
            "uuid": "$node_uuid",
            "security": "auto",
            "alter_id": ${node_alter_id:-0},
            "domain_resolver": "direct-dns"
        }
EOF
  fi
}

# =============================================================================
# Route Rules Generation
# =============================================================================

# Generate custom route rules JSON
_sing_template_generate_route_rules() {
  # Get custom rules from rules module
  local custom_rules=$(_sing_rules_generate_route_rules)
  
  # If no custom rules, return empty (template has default rules)
  if [[ -z "$custom_rules" ]]; then
    echo ""
    return
  fi
  
  # Return custom rules with proper indentation (as array elements)
  echo "$custom_rules"
}

# Generate custom DNS rules JSON
_sing_template_generate_dns_rules() {
  # Get DNS rules from rules module (internal domains → internal-dns)
  local dns_rules=$(_sing_rules_generate_dns_rules)
  
  if [[ -z "$dns_rules" ]]; then
    echo ""
    return
  fi
  
  echo "$dns_rules"
}

# =============================================================================
# Rule-set Management
# =============================================================================

SING_RUN_RULESET_DIR="$SING_RUN_DIR/rulesets"

# Rule-set URL definitions (tag -> filename)
typeset -A SING_RUN_RULESET_URLS
SING_RUN_RULESET_URLS[geosite-category-ads-all.srs]="https://fastly.jsdelivr.net/gh/SagerNet/sing-geosite@rule-set/geosite-category-ads-all.srs"
SING_RUN_RULESET_URLS[geosite-google.srs]="https://fastly.jsdelivr.net/gh/SagerNet/sing-geosite@rule-set/geosite-google.srs"
SING_RUN_RULESET_URLS[geosite-cn.srs]="https://fastly.jsdelivr.net/gh/SagerNet/sing-geosite@rule-set/geosite-cn.srs"
SING_RUN_RULESET_URLS[geoip-cn.srs]="https://fastly.jsdelivr.net/gh/SagerNet/sing-geoip@rule-set/geoip-cn.srs"

# Download a single rule-set file
_sing_ruleset_download_one() {
  local filename="$1"
  local url="${SING_RUN_RULESET_URLS[$filename]}"
  local dest="$SING_RUN_RULESET_DIR/$filename"
  
  if [[ -z "$url" ]]; then
    echo "错误: 未知的规则集文件 '$filename'" >&2
    return 1
  fi
  
  curl -sL --connect-timeout 10 --max-time 30 -o "$dest" "$url"
  if [[ $? -eq 0 ]] && [[ -s "$dest" ]]; then
    return 0
  else
    rm -f "$dest"
    return 1
  fi
}

# Ensure all rule-set files exist locally (download if missing)
_sing_ruleset_ensure() {
  mkdir -p "$SING_RUN_RULESET_DIR"
  
  local missing=()
  for filename in "${(k)SING_RUN_RULESET_URLS[@]}"; do
    if [[ ! -f "$SING_RUN_RULESET_DIR/$filename" ]]; then
      missing+=("$filename")
    fi
  done
  
  if [[ ${#missing[@]} -eq 0 ]]; then
    return 0
  fi
  
  echo "📥 下载路由规则集 (首次使用，仅需一次)..."
  local failed=0
  for filename in "${missing[@]}"; do
    printf "  %-45s " "$filename"
    if _sing_ruleset_download_one "$filename"; then
      echo "✓"
    else
      echo "✗"
      ((failed++))
    fi
  done
  
  if [[ $failed -gt 0 ]]; then
    echo "⚠️  $failed 个规则集下载失败，启动可能受影响" >&2
    return 1
  fi
  
  echo "✓ 规则集就绪"
  return 0
}

# Force update all rule-set files
_sing_ruleset_update() {
  mkdir -p "$SING_RUN_RULESET_DIR"
  
  echo "📥 更新路由规则集..."
  local failed=0
  for filename in "${(k)SING_RUN_RULESET_URLS[@]}"; do
    printf "  %-45s " "$filename"
    if _sing_ruleset_download_one "$filename"; then
      echo "✓"
    else
      echo "✗"
      ((failed++))
    fi
  done
  
  if [[ $failed -gt 0 ]]; then
    echo "⚠️  $failed 个规则集更新失败"
    return 1
  fi
  
  echo "✓ 所有规则集已更新"
  return 0
}

# =============================================================================
# High-level Template Processing
# =============================================================================

# Generate config from template with all replacements
# Usage: _sing_template_generate_config <template_name> <tun_interface> <ip_cidr> <socks_port> <http_port> <node_line> <config_dir> <auto_route>
_sing_template_generate_config() {
  local template_name="$1"
  local tun_interface="$2"
  local ip_cidr="$3"
  local socks_port="$4"
  local http_port="$5"
  local node_line="$6"
  local config_dir="$7"
  local auto_route="${8:-false}"
  
  # Select template based on TUN mode
  if [[ "$auto_route" == "true" ]]; then
    template_name="tun-template"
  else
    template_name="proxy-template"
  fi
  
  # Ensure rule-set files are available locally (output to stderr to avoid contaminating JSON)
  _sing_ruleset_ensure >&2
  if [[ $? -ne 0 ]]; then
    echo "警告: 部分规则集不可用，继续启动..." >&2
  fi
  
  # Load template
  local template=$(_sing_template_load "$template_name")
  if [[ $? -ne 0 ]]; then
    return 1
  fi
  
  # Get current DNS (primary + extras)
  local current_dns=$(_sing_system_get_dns)
  local -a all_dns=($(_sing_system_get_all_dns))
  local -a extra_dns=()
  for _dns in "${all_dns[@]}"; do
    [[ "$_dns" != "$current_dns" ]] && extra_dns+=("$_dns")
  done
  
  # Generate outbound configuration
  local outbound_config=$(_sing_template_generate_outbound "$node_line")
  
  # Generate route rules
  local route_rules=$(_sing_template_generate_route_rules)
  
  # Generate DNS rules
  local dns_rules=$(_sing_template_generate_dns_rules)
  
  # Set file paths (align with _sing_instance_get_log_file in sing-run-instance.sh)
  local log_file="${config_dir}/logs/sing-box.log"
  local cache_file="${config_dir}/cache/cache.db"
  
  # Replace simple placeholders first
  local config="$template"
  # TUN-specific placeholders (only present in tun-template)
  if [[ "$auto_route" == "true" ]]; then
    config="${config//\{\{TUN_INTERFACE\}\}/$tun_interface}"
    config="${config//\{\{IP_CIDR\}\}/$ip_cidr}"
    config="${config//\"\{\{AUTO_ROUTE\}\}\"/$auto_route}"
  fi
  # Internal DNS (used by both TUN and proxy templates for internal domain resolution)
  config="${config//\{\{INTERNAL_DNS\}\}/$current_dns}"
  # Ports: Replace quoted placeholder with integer (remove quotes)
  config="${config//\"\{\{SOCKS_PORT\}\}\"/$socks_port}"
  config="${config//\"\{\{HTTP_PORT\}\}\"/$http_port}"
  config="${config//\{\{LOG_FILE\}\}/$log_file}"
  config="${config//\{\{CACHE_FILE\}\}/$cache_file}"
  # Rule-set directory (local rule-set files)
  config="${config//\{\{RULESET_DIR\}\}/$SING_RUN_RULESET_DIR}"
  
  # Create temp files for complex replacements
  local tmp_template=$(mktemp)
  local tmp_outbound=$(mktemp)
  local tmp_route_custom=$(mktemp)
  local tmp_dns_custom=$(mktemp)
  echo "$config" > "$tmp_template"
  echo "$outbound_config" > "$tmp_outbound"
  
  # Prepare custom route rules (empty array if none)
  if [[ -n "$route_rules" ]]; then
    echo "[$route_rules]" > "$tmp_route_custom"
  else
    echo "[]" > "$tmp_route_custom"
  fi
  
  # Prepare custom DNS rules (empty array if none)
  if [[ -n "$dns_rules" ]]; then
    echo "[$dns_rules]" > "$tmp_dns_custom"
  else
    echo "[]" > "$tmp_dns_custom"
  fi
  
  # Generate extra internal DNS servers JSON (for secondary system DNS servers)
  local tmp_extra_dns=$(mktemp)
  if [[ ${#extra_dns[@]} -gt 0 ]]; then
    local _idx=2
    local _entries=""
    for _dns in "${extra_dns[@]}"; do
      [[ -n "$_entries" ]] && _entries+=","
      _entries+='{"type":"udp","tag":"internal-dns-'"$_idx"'","server":"'"$_dns"'","server_port":53}'
      ((_idx++))
    done
    echo "[${_entries}]" > "$tmp_extra_dns"
  else
    echo "[]" > "$tmp_extra_dns"
  fi

  # Use jq to merge outbound, custom route rules, custom DNS rules, and extra DNS servers
  # - Extra internal DNS servers are appended to dns.servers
  # - Custom DNS rules replace the {{CUSTOM_DNS_RULES}} placeholder in-place
  # - Custom route rules replace the {{CUSTOM_ROUTE_RULES}} placeholder in-place
  #   (preserving template order so custom rules sit before geoip-cn)
  local result=$(jq \
    --slurpfile outbound "$tmp_outbound" \
    --slurpfile custom_route "$tmp_route_custom" \
    --slurpfile custom_dns "$tmp_dns_custom" \
    --slurpfile extra_dns "$tmp_extra_dns" \
    '.outbounds[0] = $outbound[0] | 
     .dns.servers = .dns.servers + $extra_dns[0] |
     .dns.rules = [.dns.rules[] | if type == "string" then $custom_dns[0][] else . end] |
     .route.rules = [.route.rules[] | if type == "string" then $custom_route[0][] else . end]' \
    "$tmp_template" 2>&1)
  
  rm -f "$tmp_template" "$tmp_outbound" "$tmp_route_custom" "$tmp_dns_custom" "$tmp_extra_dns"
  
  if [[ $? -eq 0 ]]; then
    echo "$result"
  else
    echo "错误: JSON 处理失败: $result" >&2
    return 1
  fi
}
