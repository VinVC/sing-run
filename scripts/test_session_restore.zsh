#!/bin/zsh
set -uo pipefail

repo_dir="${0:A:h:h}"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

source "$repo_dir/sing-run.sh"

SING_RUN_DIR="$tmp_dir"
SING_RUN_INSTANCES_DIR="$tmp_dir/instances"
SING_RUN_SESSION_FILE="$tmp_dir/state/last-session.json"

fail() {
  echo "$1" >&2
  exit 1
}

mkdir -p "$tmp_dir/instances/jp/state" "$tmp_dir/instances/tw/state"
echo mp > "$tmp_dir/instances/jp/state/source.txt"
echo 0 > "$tmp_dir/instances/jp/state/node.txt"
echo true > "$tmp_dir/instances/jp/state/auto_route.txt"
echo mp > "$tmp_dir/instances/tw/state/source.txt"
echo 1 > "$tmp_dir/instances/tw/state/node.txt"
echo false > "$tmp_dir/instances/tw/state/auto_route.txt"

_sing_source_get_instance() {
  if [[ -f "$SING_RUN_INSTANCES_DIR/$1/state/source.txt" ]]; then
    cat "$SING_RUN_INSTANCES_DIR/$1/state/source.txt"
  else
    echo mp
  fi
}
_sing_source_get_name() { echo "源$1"; }
_sing_region_get_nodes() {
  case "$1" in
    jp) printf '%s\n' '日本 "A"::::vmess::::a::::1' ;;
    tw) printf '%s\n' '台湾-00::::ss::::b::::1' '台湾-01::::ss::::c::::2' ;;
  esac
}
_sing_instance_is_running() {
  [[ "$1" == "jp" || "$1" == "tw" ]]
}

entry=$(_sing_session_entry_for_region jp) || fail "entry build failed"
[[ "$(jq -r '.node_name' <<< "$entry")" == '日本 "A"' ]] || fail "node name with quotes was not kept"
[[ "$(jq -r '.tun' <<< "$entry")" == "true" ]] || fail "tun flag was not recorded"
_sing_session_upsert_entry "$entry" || fail "upsert failed"
tw_entry=$(_sing_session_entry_for_region tw) || fail "tw entry failed"
_sing_session_upsert_entry "$tw_entry" || fail "tw upsert failed"
[[ "$(jq -r '.instances | length' "$SING_RUN_SESSION_FILE")" == "2" ]] || fail "session should contain two regions"
[[ "$(jq -r '.instances[1].node_index' "$SING_RUN_SESSION_FILE")" == "1" ]] || fail "tw node index was not saved"

_sing_session_remove jp || fail "remove failed"
[[ "$(jq -r '.instances[0].region' "$SING_RUN_SESSION_FILE")" == "tw" ]] || fail "remove should leave tw"
[[ "$(jq -r '.instances | length' "$SING_RUN_SESSION_FILE")" == "1" ]] || fail "remove should leave one region"

kept="$(cat "$SING_RUN_SESSION_FILE")"
_sing_instance_is_running() { return 1; }
_sing_session_snapshot_running || fail "empty snapshot should succeed"
[[ "$(cat "$SING_RUN_SESSION_FILE")" == "$kept" ]] || fail "empty snapshot must not wipe the last session"

_sing_instance_is_running() { [[ "$1" == "jp" || "$1" == "tw" ]]; }
_sing_session_snapshot_running || fail "snapshot failed"
[[ "$(jq -r '[.instances[].region] | join(",")' "$SING_RUN_SESSION_FILE")" == "tw,jp" ]] || fail "snapshot order should follow region order"

resolved=""
note=""
note=$(_sing_session_resolve_node jp mp 0 '日本 "A"' 2>&1 >/dev/null) || fail "resolve exact name failed"
resolved=$(_sing_session_resolve_node jp mp 0 '日本 "A"' 2>/dev/null) || fail "resolve exact name failed"
[[ "$resolved" == "0" ]] || fail "exact name should stay at index 0"
[[ -z "$note" ]] || fail "exact match should be silent"

_sing_region_get_nodes() {
  printf '%s\n' '日本-B::::vmess::::a::::1' '日本 "A"::::vmess::::b::::2'
}
note=$(_sing_session_resolve_node jp mp 0 '日本 "A"' 2>&1 >/dev/null) || fail "resolve moved name failed"
resolved=$(_sing_session_resolve_node jp mp 0 '日本 "A"' 2>/dev/null) || fail "resolve moved name failed"
[[ "$resolved" == "1" ]] || fail "moved node should resolve to index 1, got $resolved"
[[ "$note" == *'索引 0 → 1'* ]] || fail "moved node should report the index change"

_sing_region_get_nodes() { printf '%s\n' '其他节点::::vmess::::a::::1'; }
note=$(_sing_session_resolve_node jp mp 0 '日本 "A"' 2>&1 >/dev/null) || fail "index fallback failed"
resolved=$(_sing_session_resolve_node jp mp 0 '日本 "A"' 2>/dev/null) || fail "index fallback failed"
[[ "$resolved" == "0" ]] || fail "missing name should fall back to the old index"
[[ "$note" == *'未找到节点'* ]] || fail "missing name should warn"

if _sing_session_resolve_node jp mp 3 '日本 "A"' >/dev/null 2>&1; then
  fail "missing name and index should fail"
fi

cat > "$SING_RUN_SESSION_FILE" << 'EOF'
{
  "version": 1,
  "instances": [
    {"region":"tw","source":"mp","node_index":0,"node_name":"台湾-01","tun":true},
    {"region":"jp","source":"mp","node_index":0,"node_name":"日本-A","tun":false},
    {"region":"hk","source":"mp","node_index":0,"node_name":"香港-01","tun":false},
    {"region":"sg","source":"gone","node_index":0,"node_name":"新加坡","tun":false}
  ]
}
EOF

typeset -a started
started=()
_sing_instance_is_running() { [[ "$1" == "hk" ]]; }
_sing_instance_start() { started+=("$1|$2|$3"); return 0; }
_sing_source_set_instance() { return 0; }
_sing_source_is_valid() { [[ "$1" != "gone" ]]; }
_sing_source_file_exists() { return 0; }
_sing_region_get_nodes() {
  case "$1" in
    jp) printf '%s\n' '日本-B::::vmess::::a::::1' '日本-A::::vmess::::b::::2' ;;
    tw) printf '%s\n' '台湾-01::::ss::::c::::3' ;;
    hk) printf '%s\n' '香港-01::::ss::::d::::4' ;;
  esac
}

restore_output="$tmp_dir/restore.out"
_sing_session_restore > "$restore_output" 2>&1
restore_rc=$?
[[ "$restore_rc" -eq 1 ]] || fail "restore should fail when one region cannot be resolved, rc=$restore_rc"
[[ "${started[1]}" == "jp|1|" ]] || fail "proxy region should start first with the renamed index, got ${started[1]:-none}"
[[ "${started[2]}" == "tw|0|true" ]] || fail "tun region should start last, got ${started[2]:-none}"
[[ ${#started[@]} -eq 2 ]] || fail "running and invalid regions must not be started, count=${#started[@]}"
grep -q "已恢复 2 个，跳过 1 个，失败 1 个" "$restore_output" || fail "restore summary mismatch"
grep -q "已在运行" "$restore_output" || fail "running region should be skipped"
grep -q "源 gone 不可用" "$restore_output" || fail "invalid source should be reported"

_sing_instance_is_running() { return 1; }
idle="$(_sing_instance_status)"
[[ "$idle" == *"没有运行中的实例"* ]] || fail "status should report no running region"
[[ "$idle" == *"上次运行"* ]] || fail "idle status should show the saved session"
[[ "$idle" == *"sing-run restore 可恢复"* ]] || fail "idle status should mention restore"

rm -f "$SING_RUN_SESSION_FILE"
if _sing_session_restore >/dev/null 2>&1; then
  fail "missing session should not restore"
fi

echo "session restore ok"
