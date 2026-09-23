#!/bin/zsh
set -uo pipefail

repo_dir="${0:A:h:h}"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

source "$repo_dir/sing-run.sh"

mkdir -p "$tmp_dir/state" "$tmp_dir/logs" "$tmp_dir/cache"

if ! (
  calls=()
  dscacheutil() { calls+=("dscacheutil $*"); }
  killall() { calls+=("killall $*"); }
  sudo() { calls+=("sudo $*"); }
  networksetup() { calls+=("networksetup $*"); return 1; }
  OSTYPE="darwin-test"

  _sing_system_flush_dns_cache
  joined="${(j:|:)calls}"
  [[ "$joined" == *"dscacheutil -flushcache"* ]]
  [[ "$joined" == *"sudo -n killall -HUP mDNSResponder"* ]]
  [[ "$joined" != *"networksetup"* ]]
); then
  echo "macOS DNS cache refresh must not change configured DNS servers" >&2
  exit 1
fi

printf 'fakeip' > "$tmp_dir/cache/cache.db"
if ! _sing_instance_clear_dns_cache "$tmp_dir" || [[ "$(cat "$tmp_dir/cache/cache.db")" != "fakeip" ]]; then
  echo "FakeIP cache must survive a TUN restart" >&2
  exit 1
fi

if ! (
  dig() {
    echo "bootstrap.example.test."
    echo "203.0.113.9"
  }
  python3() { return 1; }
  [[ "$(_sing_system_resolve_ipv4 node.example.test)" == "203.0.113.9" ]]
); then
  echo "bootstrap resolver did not follow a direct-DNS CNAME answer" >&2
  exit 1
fi

SING_RUN_RULES_DIR="$tmp_dir/rules"
SING_RUN_PROXY_RULES="$SING_RUN_RULES_DIR/proxy-domains.txt"
SING_RUN_DIRECT_RULES="$SING_RUN_RULES_DIR/direct-domains.txt"
mkdir -p "$SING_RUN_RULES_DIR"
_sing_rules_add_proxy "*.OpenAI.com" >/dev/null
_sing_rules_add_proxy "142.171.111.176/32" >/dev/null
_sing_rules_add_direct ".fuyoukache.com" >/dev/null
_sing_rules_add_direct "120.27.155.114" >/dev/null

node_line="test::::vmess::::shh.itea.la::::21870::::00000000-0000-0000-0000-000000000000::::password::::aes-256-gcm::::0"
config_file="$tmp_dir/config.json"
export SING_RUN_TUN_CORP_DNS="172.16.1.100"

if ! (
  _sing_system_resolve_ipv4() { echo "203.0.113.8"; }
  outbound=$(_sing_template_generate_outbound "$node_line")
  [[ "$(printf '%s' "$outbound" | jq -r '.server')" == "203.0.113.8" ]]
); then
  echo "proxy node hostname was not replaced by its bootstrap IPv4" >&2
  exit 1
fi

if ! (
  _sing_system_resolve_ipv4() { return 1; }
  outbound=$(_sing_template_generate_outbound "$node_line")
  [[ "$(printf '%s' "$outbound" | jq -r '.server')" == "shh.itea.la" ]]
); then
  echo "proxy node hostname was not preserved after bootstrap lookup failure" >&2
  exit 1
fi

if ! (
  called=false
  _sing_system_resolve_ipv4() { called=true; return 1; }
  ip_node_line="test::::vmess::::192.0.2.9::::21870::::00000000-0000-0000-0000-000000000000::::password::::aes-256-gcm::::0"
  outbound=$(_sing_template_generate_outbound "$ip_node_line")
  [[ "$(printf '%s' "$outbound" | jq -r '.server')" == "192.0.2.9" && "$called" == "false" ]]
); then
  echo "literal proxy node IPv4 must bypass bootstrap lookup" >&2
  exit 1
fi

if ! _sing_template_generate_config "" "utun99" "172.19.99.1/30" 7890 7891 "$node_line" "$tmp_dir" true > "$config_file"; then
  echo "failed to generate TUN config" >&2
  exit 1
fi

if ! python3 - "$config_file" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path) as f:
    config = json.load(f)

inbounds = config.get("inbounds", [])
routes = config.get("route", {}).get("rules", [])
tun_inbound = next((inbound for inbound in inbounds if inbound.get("type") == "tun"), None)

assert not any(inbound.get("tag") == "dns-in" for inbound in inbounds), "TUN config must not depend on /etc/resolver -> dns-in"
assert not any(rule.get("inbound") == "dns-in" for rule in routes), "dns-in route rule must not be present"
assert config.get("route", {}).get("auto_detect_interface") is True, "direct/bootstrap traffic must keep auto_detect_interface"
cache_file = config.get("experimental", {}).get("cache_file", {})
assert cache_file.get("store_fakeip") is True, "FakeIP mappings must persist across TUN restarts"
assert not cache_file.get("store_dns"), "real DNS answers must not persist across home and corp networks"
assert tun_inbound is not None, "TUN inbound must exist"
assert "sniff" not in tun_inbound, "legacy inbound sniff was removed in sing-box 1.13"
assert "sniff_override_destination" not in tun_inbound, "legacy inbound sniff_override_destination was removed in sing-box 1.13"
assert any(rule.get("action") == "sniff" for rule in routes), "protocol sniff must be a route action"
assert "geoip-cn" in tun_inbound.get("route_exclude_address_set", []), "CN IPs must bypass TUN routes at system routing layer"

internal = next((s for s in config.get("dns", {}).get("servers", []) if s.get("tag") == "internal-dns"), None)
assert internal is not None, "internal-dns server must exist"
assert internal.get("type") == "udp", "TUN corp DNS must replace local internal-dns with udp"
assert internal.get("server") == "172.16.1.100", "TUN corp DNS must use the discovered corp resolver"

direct = next((o for o in config.get("outbounds", []) if o.get("tag") == "direct"), None)
assert direct is not None, "direct outbound must exist"
assert direct.get("domain_resolver") == "internal-dns", "direct domains must preserve corp split-DNS answers"

fakeip_proxy_idx = next(
    (i for i, rule in enumerate(routes) if "198.18.0.0/15" in rule.get("ip_cidr", []) and rule.get("outbound") == "proxy"),
    None,
)
private_direct_idx = next(
    (i for i, rule in enumerate(routes) if rule.get("ip_is_private") is True and rule.get("outbound") == "direct"),
    None,
)
assert fakeip_proxy_idx is not None, "fakeip range must route to proxy"
assert private_direct_idx is not None, "private IP direct rule must remain"
assert fakeip_proxy_idx < private_direct_idx, "fakeip proxy rule must precede private direct rule"

dns_rules = config.get("dns", {}).get("rules", [])
assert any(rule.get("rule_set") == "openai" and rule.get("server") == "proxy-fakeip" for rule in dns_rules), "OpenAI DNS must use fakeip"
assert any(rule.get("rule_set") == "openai" and rule.get("outbound") == "proxy" for rule in routes), "OpenAI routes must use proxy"
assert any(rule.get("rule_set") == "claude" and rule.get("server") == "proxy-fakeip" for rule in dns_rules), "Claude DNS must use fakeip"
assert any(rule.get("rule_set") == "claude" and rule.get("outbound") == "proxy" for rule in routes), "Claude routes must use proxy"

custom_proxy_route = next(
    (rule for rule in routes if rule.get("outbound") == "proxy" and "openai.com" in rule.get("domain", [])),
    None,
)
assert custom_proxy_route is not None, "custom proxy domain must produce an exact domain matcher"
assert ".openai.com" in custom_proxy_route.get("domain_suffix", []), "custom proxy domain must match subdomains"
assert not any("openai.com" == suffix for suffix in custom_proxy_route.get("domain_suffix", [])), "custom suffix matcher must be explicit"

custom_direct_route = next(
    (rule for rule in routes if rule.get("outbound") == "direct" and "fuyoukache.com" in rule.get("domain", [])),
    None,
)
assert custom_direct_route is not None, "custom direct domain must produce an exact domain matcher"
assert ".fuyoukache.com" in custom_direct_route.get("domain_suffix", []), "custom direct domain must match subdomains"

assert any(
    rule.get("outbound") == "proxy" and "142.171.111.176/32" in rule.get("ip_cidr", [])
    for rule in routes
), "custom proxy CIDR must remain an IP route"
assert any(
    rule.get("outbound") == "direct" and "120.27.155.114/32" in rule.get("ip_cidr", [])
    for rule in routes
), "custom direct bare IP must be normalized to /32"

assert any(
    rule.get("server") == "proxy-fakeip" and "openai.com" in rule.get("domain", []) and ".openai.com" in rule.get("domain_suffix", [])
    for rule in dns_rules
), "custom proxy DNS must use fakeip with exact and subdomain matchers"
assert any(
    rule.get("server") == "internal-dns" and "fuyoukache.com" in rule.get("domain", []) and ".fuyoukache.com" in rule.get("domain_suffix", [])
    for rule in dns_rules
), "custom direct DNS must use internal DNS with exact and subdomain matchers"
PY
then
  exit 1
fi

if ! sing-box check -c "$config_file" >/dev/null; then
  echo "sing-box check failed" >&2
  exit 1
fi
echo "tun config regression test passed"
