#!/bin/zsh
# sing-run-rules.sh: Domain rules management for sing-run
# Manages custom routing rules for proxy and direct connections

# =============================================================================
# Rules Configuration
# =============================================================================

SING_RUN_RULES_DIR="$SING_RUN_DIR/rules"
SING_RUN_PROXY_RULES="$SING_RUN_RULES_DIR/proxy-domains.txt"
SING_RUN_DIRECT_RULES="$SING_RUN_RULES_DIR/direct-domains.txt"

# =============================================================================
# Directory Management
# =============================================================================

_sing_rules_ensure_dirs() {
  mkdir -p "$SING_RUN_RULES_DIR"
  [[ ! -f "$SING_RUN_PROXY_RULES" ]] && touch "$SING_RUN_PROXY_RULES"
  [[ ! -f "$SING_RUN_DIRECT_RULES" ]] && touch "$SING_RUN_DIRECT_RULES"
}

# =============================================================================
# Domain Extraction
# =============================================================================

# Extract domain from URL
_sing_rules_extract_domain() {
  local input="$1"
  local domain=""
  
  # Remove protocol
  domain="${input#*://}"
  
  # Remove path, query and fragment
  domain="${domain%%/*}"
  domain="${domain%%\?*}"
  domain="${domain%%#*}"
  
  # Remove port
  domain="${domain%:*}"
  
  # Remove username:password@
  domain="${domain##*@}"
  
  echo "$domain"
}

# =============================================================================
# Rule Management
# =============================================================================

# Add domain to proxy rules
_sing_rules_add_proxy() {
  local input="$1"
  
  if [[ -z "$input" ]]; then
    echo "错误: 请指定域名或 URL"
    echo "用法: sing-run --add-proxy <domain>"
    echo "示例: sing-run --add-proxy google.com"
    echo "      sing-run --add-proxy '*.youtube.com'"
    return 1
  fi
  
  _sing_rules_ensure_dirs
  
  # Extract domain if URL provided
  local domain=$(_sing_rules_extract_domain "$input")
  
  # Check if already exists
  if grep -Fxq "$domain" "$SING_RUN_PROXY_RULES" 2>/dev/null; then
    echo "⚠️  域名 $domain 已在代理列表中"
    return 0
  fi
  
  # Add to proxy rules
  echo "$domain" >> "$SING_RUN_PROXY_RULES"
  echo "✓ 已添加到代理列表: $domain"
  
  return 0
}

# Add domain to direct rules
# Direct domains use domain_suffix matching (matches the domain and all subdomains)
# Direct domains also get DNS rules to use local DNS (router) for resolution
_sing_rules_add_direct() {
  local input="$1"
  
  if [[ -z "$input" ]]; then
    echo "错误: 请指定域名或 URL"
    echo "用法: sing-run --add-direct <domain>"
    echo "示例: sing-run --add-direct baidu.com"
    echo "      sing-run --add-direct mycompany.internal.net"
    echo ""
    echo "说明: 直连域名使用本地 DNS 解析 + 直连路由"
    echo "      匹配该域名及所有子域名"
    return 1
  fi
  
  _sing_rules_ensure_dirs
  
  # Extract domain if URL provided
  local domain=$(_sing_rules_extract_domain "$input")
  
  # Check if already exists
  if grep -Fxq "$domain" "$SING_RUN_DIRECT_RULES" 2>/dev/null; then
    echo "⚠️  域名 $domain 已在直连列表中"
    return 0
  fi
  
  # Add to direct rules
  echo "$domain" >> "$SING_RUN_DIRECT_RULES"
  echo "✓ 已添加到直连列表: $domain (及所有子域名)"
  echo "  DNS 解析: 本地 DNS (路由器)"
  echo "  路由方式: 直连"
  
  return 0
}

# Delete domain rule
_sing_rules_delete() {
  local domain="$1"
  
  if [[ -z "$domain" ]]; then
    echo "错误: 请指定要删除的域名"
    echo "用法: sing-run --del-rule <domain>"
    return 1
  fi
  
  _sing_rules_ensure_dirs
  
  local found=0
  
  # Remove from proxy rules
  if grep -Fxq "$domain" "$SING_RUN_PROXY_RULES" 2>/dev/null; then
    grep -Fxv "$domain" "$SING_RUN_PROXY_RULES" > "${SING_RUN_PROXY_RULES}.tmp"
    mv "${SING_RUN_PROXY_RULES}.tmp" "$SING_RUN_PROXY_RULES"
    echo "✓ 已从代理列表删除: $domain"
    found=1
  fi
  
  # Remove from direct rules
  if grep -Fxq "$domain" "$SING_RUN_DIRECT_RULES" 2>/dev/null; then
    grep -Fxv "$domain" "$SING_RUN_DIRECT_RULES" > "${SING_RUN_DIRECT_RULES}.tmp"
    mv "${SING_RUN_DIRECT_RULES}.tmp" "$SING_RUN_DIRECT_RULES"
    echo "✓ 已从直连列表删除: $domain"
    found=1
  fi
  
  if [[ $found -eq 0 ]]; then
    echo "⚠️  域名 $domain 不在规则列表中"
    return 1
  fi
  
  return 0
}

# List all rules
_sing_rules_list() {
  _sing_rules_ensure_dirs
  
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "                 自定义域名规则                              "
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  
  # Proxy rules
  echo "【代理域名】"
  if [[ -f "$SING_RUN_PROXY_RULES" ]] && [[ -s "$SING_RUN_PROXY_RULES" ]]; then
    local count=0
    while IFS= read -r domain; do
      [[ -z "$domain" || "$domain" =~ ^# ]] && continue
      echo "  → $domain"
      ((count++))
    done < "$SING_RUN_PROXY_RULES"
    echo "  总计: $count 条规则"
  else
    echo "  (无)"
  fi
  
  echo ""
  
  # Direct rules
  echo "【直连域名】(本地 DNS 解析 + 直连路由)"
  if [[ -f "$SING_RUN_DIRECT_RULES" ]] && [[ -s "$SING_RUN_DIRECT_RULES" ]]; then
    local count=0
    while IFS= read -r domain; do
      [[ -z "$domain" || "$domain" =~ ^# ]] && continue
      echo "  → $domain (及所有子域名)"
      ((count++))
    done < "$SING_RUN_DIRECT_RULES"
    echo "  总计: $count 条规则"
  else
    echo "  (无)"
  fi
  
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "规则文件:"
  echo "  代理: $SING_RUN_PROXY_RULES"
  echo "  直连: $SING_RUN_DIRECT_RULES"
  echo ""
  echo "说明: 直连域名使用 domain_suffix 匹配 (包含所有子域名)"
  echo "      直连域名的 DNS 由本地路由器解析 (适用于内网域名)"
  echo "      规则对所有实例生效，修改后需重启实例"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# =============================================================================
# Route Rules Generation
# =============================================================================

# Generate sing-box route rules from custom rules
# Returns: JSON array of route rules (ready to merge into config)
_sing_rules_generate_route_rules() {
  _sing_rules_ensure_dirs
  
  local rules_json=""
  local has_rules=0
  
  # Generate proxy domain rules
  if [[ -f "$SING_RUN_PROXY_RULES" ]] && [[ -s "$SING_RUN_PROXY_RULES" ]]; then
    local proxy_domains=()
    while IFS= read -r domain; do
      [[ -z "$domain" || "$domain" =~ ^# ]] && continue
      proxy_domains+=("$domain")
    done < "$SING_RUN_PROXY_RULES"
    
    if [[ ${#proxy_domains[@]} -gt 0 ]]; then
      # Build domain array for JSON
      local domain_array=""
      for domain in "${proxy_domains[@]}"; do
        if [[ -n "$domain_array" ]]; then
          domain_array+=",\n"
        fi
        domain_array+="        \"$domain\""
      done
      
      # Add proxy rule
      if [[ $has_rules -eq 1 ]]; then
        rules_json+=",\n"
      fi
      rules_json+="      {\n"
      rules_json+="        \"domain\": [\n$domain_array\n        ],\n"
      rules_json+="        \"outbound\": \"proxy\"\n"
      rules_json+="      }"
      has_rules=1
    fi
  fi
  
  # Generate direct domain rules (using domain_suffix to match all subdomains)
  if [[ -f "$SING_RUN_DIRECT_RULES" ]] && [[ -s "$SING_RUN_DIRECT_RULES" ]]; then
    local direct_domains=()
    while IFS= read -r domain; do
      [[ -z "$domain" || "$domain" =~ ^# ]] && continue
      direct_domains+=("$domain")
    done < "$SING_RUN_DIRECT_RULES"
    
    if [[ ${#direct_domains[@]} -gt 0 ]]; then
      # Build domain_suffix array for JSON
      local domain_array=""
      for domain in "${direct_domains[@]}"; do
        if [[ -n "$domain_array" ]]; then
          domain_array+=",\n"
        fi
        domain_array+="        \"$domain\""
      done
      
      # Add direct rule (domain_suffix matches domain + all subdomains)
      if [[ $has_rules -eq 1 ]]; then
        rules_json+=",\n"
      fi
      rules_json+="      {\n"
      rules_json+="        \"domain_suffix\": [\n$domain_array\n        ],\n"
      rules_json+="        \"outbound\": \"direct\"\n"
      rules_json+="      }"
      has_rules=1
    fi
  fi
  
  # Return rules (or empty string if no rules)
  if [[ $has_rules -eq 1 ]]; then
    echo -e "$rules_json"
  fi
}

# =============================================================================
# DNS Rules Generation
# =============================================================================

# Generate DNS rules for direct domains
# Direct domains use local DNS (router) for resolution so that
# internal/private domains that are only resolvable by the router work correctly
# Returns: JSON rules for sing-box DNS config (direct domains → internal-dns)
_sing_rules_generate_dns_rules() {
  _sing_rules_ensure_dirs
  
  if [[ ! -f "$SING_RUN_DIRECT_RULES" ]] || [[ ! -s "$SING_RUN_DIRECT_RULES" ]]; then
    echo ""
    return
  fi
  
  local direct_domains=()
  while IFS= read -r domain; do
    [[ -z "$domain" || "$domain" =~ ^# ]] && continue
    direct_domains+=("$domain")
  done < "$SING_RUN_DIRECT_RULES"
  
  if [[ ${#direct_domains[@]} -eq 0 ]]; then
    echo ""
    return
  fi
  
  # Build domain_suffix array for JSON
  local domain_array=""
  for domain in "${direct_domains[@]}"; do
    if [[ -n "$domain_array" ]]; then
      domain_array+=",\n"
    fi
    domain_array+="        \"$domain\""
  done
  
  # Generate DNS rule: direct domains → internal-dns (router/local DNS)
  local rules_json=""
  rules_json+="      {\n"
  rules_json+="        \"domain_suffix\": [\n$domain_array\n        ],\n"
  rules_json+="        \"server\": \"internal-dns\"\n"
  rules_json+="      }"
  
  echo -e "$rules_json"
}

# Check if custom rules exist
_sing_rules_has_rules() {
  _sing_rules_ensure_dirs
  
  local proxy_count=0
  local direct_count=0
  
  if [[ -f "$SING_RUN_PROXY_RULES" ]]; then
    proxy_count=$(grep -v '^#' "$SING_RUN_PROXY_RULES" 2>/dev/null | grep -v '^$' | wc -l | tr -d ' ')
  fi
  
  if [[ -f "$SING_RUN_DIRECT_RULES" ]]; then
    direct_count=$(grep -v '^#' "$SING_RUN_DIRECT_RULES" 2>/dev/null | grep -v '^$' | wc -l | tr -d ' ')
  fi
  
  [[ $proxy_count -gt 0 || $direct_count -gt 0 ]]
}
