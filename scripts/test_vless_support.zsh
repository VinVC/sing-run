#!/bin/zsh
set -uo pipefail

repo_dir="${0:A:h:h}"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

source "$repo_dir/sing-run.sh"

parser="$repo_dir/scripts/parse_uri_subscription.py"
[[ -f "$parser" ]] || { echo "missing $parser" >&2; exit 1; }

vless_uri='vless://11111111-1111-1111-1111-111111111111@japan.example.test:43001?type=tcp&encryption=none&security=reality&flow=xtls-rprx-vision&fp=chrome&sni=www.xbox.com&pbk=PUBLICKEYEXAMPLE&sid=abcd1234#1.0X%20%E6%97%A5%E6%9C%AC1%20VLESS'
raw_file="$tmp_dir/raw.txt"
yaml_file="$tmp_dir/proxies.yaml"
printf '%s' "$(printf '%s\n' "$vless_uri" | base64 | tr -d '\n')" > "$raw_file"

if ! PYTHONIOENCODING=utf-8 python3 "$parser" "$raw_file" "$yaml_file"; then
  echo "vless subscription parser failed" >&2
  exit 1
fi

proxy_type=$(yq e '.proxies[0].type' "$yaml_file")
proxy_flow=$(yq e '.proxies[0].flow' "$yaml_file")
proxy_sni=$(yq e '.proxies[0].servername' "$yaml_file")
proxy_pbk=$(yq e '.proxies[0].reality-opts.public-key' "$yaml_file")
[[ "$proxy_type" == "vless" ]] || { echo "expected type vless, got $proxy_type" >&2; exit 1; }
[[ "$proxy_flow" == "xtls-rprx-vision" ]] || { echo "expected vision flow" >&2; exit 1; }
[[ "$proxy_sni" == "www.xbox.com" ]] || { echo "expected SNI www.xbox.com" >&2; exit 1; }
[[ "$proxy_pbk" == "PUBLICKEYEXAMPLE" ]] || { echo "expected reality public key" >&2; exit 1; }

opts_json=$(python3 - <<'PY'
import json
print(json.dumps({
    "flow": "xtls-rprx-vision",
    "network": "tcp",
    "security": "reality",
    "sni": "www.xbox.com",
    "fp": "chrome",
    "pbk": "PUBLICKEYEXAMPLE",
    "sid": "abcd1234",
}, separators=(",", ":")))
PY
)
node_line="JP1 VLESS::::vless::::japan.example.test::::43001::::11111111-1111-1111-1111-111111111111::::-::::-::::0::::${opts_json}"

# Avoid network during outbound generation tests.
_sing_system_resolve_ipv4() { return 1; }

outbound=$(_sing_template_generate_outbound "$node_line")
if ! printf '%s' "$outbound" | jq -e '
  .type == "vless"
  and .server == "japan.example.test"
  and .server_port == 43001
  and .uuid == "11111111-1111-1111-1111-111111111111"
  and .flow == "xtls-rprx-vision"
  and .tls.enabled == true
  and .tls.server_name == "www.xbox.com"
  and .tls.utls.enabled == true
  and .tls.utls.fingerprint == "chrome"
  and .tls.reality.enabled == true
  and .tls.reality.public_key == "PUBLICKEYEXAMPLE"
  and .tls.reality.short_id == "abcd1234"
  and .domain_resolver == "direct-dns"
' >/dev/null; then
  echo "vless outbound generation failed:" >&2
  printf '%s\n' "$outbound" >&2
  exit 1
fi

echo "vless support regression test passed"

# Region loader must preserve Reality opts through "::::" node lines (base64 field 9).
SING_RUN_SOURCE_FILES[edn]="$yaml_file"
region_line=$(_sing_region_get_nodes jp edn | head -n 1)
[[ -n "$region_line" ]] || { echo "region loader returned no jp/edn vless nodes" >&2; exit 1; }
region_outbound=$(_sing_template_generate_outbound "$region_line")
if ! printf '%s' "$region_outbound" | jq -e '
  .type == "vless"
  and .flow == "xtls-rprx-vision"
  and .tls.reality.enabled == true
  and .tls.reality.public_key == "PUBLICKEYEXAMPLE"
  and .tls.server_name == "www.xbox.com"
' >/dev/null; then
  echo "region→outbound pipeline failed:" >&2
  printf 'line=%s\n' "$region_line" >&2
  printf '%s\n' "$region_outbound" >&2
  exit 1
fi

echo "vless region pipeline regression test passed"

# An all-digit short-id must stay a quoted string (sing-box rejects numbers).
numeric_uri='vless://22222222-2222-2222-2222-222222222222@usa.example.test:43002?type=tcp&encryption=none&security=reality&flow=xtls-rprx-vision&fp=chrome&sni=www.bing.com&pbk=PUBLICKEYEXAMPLE&sid=0117#0.1X%20%E7%BE%8E%E5%9B%BD2%20VLESS'
numeric_raw="$tmp_dir/raw-numeric.txt"
numeric_yaml="$tmp_dir/proxies-numeric.yaml"
printf '%s' "$(printf '%s\n' "$numeric_uri" | base64 | tr -d '\n')" > "$numeric_raw"
PYTHONIOENCODING=utf-8 python3 "$parser" "$numeric_raw" "$numeric_yaml" \
  || { echo "numeric short-id parser failed" >&2; exit 1; }

numeric_sid_kind=$(yq e -o=json '.proxies[0]."reality-opts"."short-id"' "$numeric_yaml" | jq -r 'type')
[[ "$numeric_sid_kind" == "string" ]] || { echo "short-id must stay a string, got $numeric_sid_kind" >&2; exit 1; }

SING_RUN_SOURCE_FILES[edn]="$numeric_yaml"
numeric_line=$(_sing_region_get_nodes usa edn | head -n 1)
[[ -n "$numeric_line" ]] || { echo "region loader returned no usa vless node" >&2; exit 1; }
numeric_outbound=$(_sing_template_generate_outbound "$numeric_line")
if ! printf '%s' "$numeric_outbound" | jq -e '
  (.tls.reality.short_id | type) == "string"
  and .tls.reality.short_id == "0117"
' >/dev/null; then
  echo "numeric short-id outbound failed:" >&2
  printf '%s\n' "$numeric_outbound" >&2
  exit 1
fi

echo "vless numeric short-id regression test passed"
