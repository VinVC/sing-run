#!/bin/zsh
set -uo pipefail

repo_dir="${0:A:h:h}"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

source "$repo_dir/sing-run.sh"

mkdir -p "$tmp_dir/state" "$tmp_dir/logs" "$tmp_dir/cache"

node_line="test::::vmess::::shh.itea.la::::21870::::00000000-0000-0000-0000-000000000000::::password::::aes-256-gcm::::0"
config_file="$tmp_dir/config.json"

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

assert not any(inbound.get("tag") == "dns-in" for inbound in inbounds), "TUN config must not depend on /etc/resolver -> dns-in"
assert not any(rule.get("inbound") == "dns-in" for rule in routes), "dns-in route rule must not be present"
assert config.get("route", {}).get("auto_detect_interface") is True, "direct/bootstrap traffic must keep auto_detect_interface"

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
PY
then
  exit 1
fi

if ! sing-box check -c "$config_file" >/dev/null; then
  echo "sing-box check failed" >&2
  exit 1
fi
echo "tun config regression test passed"
