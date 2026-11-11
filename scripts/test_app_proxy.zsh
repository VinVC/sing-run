#!/bin/zsh
set -uo pipefail

repo_dir="${0:A:h:h}"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
source "$repo_dir/sing-run.sh"

fail() { echo "$1" >&2; exit 1; }

# Listening processes can be invisible to lsof (root-owned TUN on macOS).
# Check an actual TCP listener and then the same port after it closes.
python3 - "$tmp_dir/port" <<'PY' &
import socket, sys
from pathlib import Path
with socket.socket() as server:
    server.bind(("127.0.0.1", 0))
    server.listen()
    server.settimeout(10)
    Path(sys.argv[1]).write_text(str(server.getsockname()[1]))
    conn, _ = server.accept()
    conn.close()
PY
server_pid=$!
for i in {1..500}; do
  [[ -s "$tmp_dir/port" ]] && break
  sleep 0.02
done
[[ -s "$tmp_dir/port" ]] || fail "test listener did not start"
test_port="$(cat "$tmp_dir/port")"
lsof() { return 1; }
_sing_system_is_port_listening "$test_port" || fail "reachable listener was rejected when lsof could not see it"
wait "$server_pid" || fail "test listener failed"
if _sing_system_is_port_listening "$test_port"; then
  fail "closed TCP port was accepted"
fi

# Exercise the actual child environment without launching the real app.
cat > "$tmp_dir/mock app" <<'SH'
#!/bin/sh
printf '%s\n' \
  "HTTP_PROXY=${HTTP_PROXY-unset}" "HTTPS_PROXY=${HTTPS_PROXY-unset}" \
  "ALL_PROXY=${ALL_PROXY-unset}" "NO_PROXY=${NO_PROXY-unset}" \
  "http_proxy=${http_proxy-unset}" "https_proxy=${https_proxy-unset}" \
  "all_proxy=${all_proxy-unset}" "no_proxy=${no_proxy-unset}" \
  "ELECTRON_RUN_AS_NODE=${ELECTRON_RUN_AS_NODE-unset}" \
  "ARG_COUNT=$#" "ARG1=${1-}" > "$TEST_CAPTURE"
SH
chmod +x "$tmp_dir/mock app"
export TEST_CAPTURE="$tmp_dir/launch.json"
export HTTP_PROXY="http://old.example:1" HTTPS_PROXY="http://old.example:2"
export ALL_PROXY="socks5://old.example:3" NO_PROXY="chatgpt.com"
export http_proxy="http://old.example:4" https_proxy="http://old.example:5"
export all_proxy="socks5://old.example:6" no_proxy="*"
export ELECTRON_RUN_AS_NODE=1
_sing_run_proxy_app_launch "$tmp_dir/mock app" "http://127.0.0.1:7811"
for i in {1..500}; do
  [[ -s "$TEST_CAPTURE" ]] && break
  sleep 0.02
done
python3 - "$TEST_CAPTURE" <<'PY' || exit 1
import sys
d = dict(line.rstrip("\n").split("=", 1) for line in open(sys.argv[1]))
for key in ["HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy"]:
    assert d[key] == "http://127.0.0.1:7811", (key, d)
for key in ["ALL_PROXY", "all_proxy"]:
    assert d[key] == "unset", (key, d)
for key in ["NO_PROXY", "no_proxy"]:
    assert d[key] == "localhost,127.0.0.1,::1", (key, d)
assert d["ARG_COUNT"] == "1" and d["ARG1"] == "--proxy-server=http://127.0.0.1:7811", d
assert d["ELECTRON_RUN_AS_NODE"] == "unset", d
PY
[[ "$NO_PROXY" == "chatgpt.com" && "$no_proxy" == "*" ]] || fail "parent environment changed"

# A running app must be left alone, and neither path may change TUN.
_sing_run_proxy_app_binary() { print -r -- "$tmp_dir/mock app"; }
_sing_instance_is_running() { return 0; }
_sing_instance_get_config() {
  case "$1" in
    jp) echo '_ 172.19.4.1/30 7810 7811 /unused' ;;
    tw) echo '_ 172.19.12.1/30 7830 7831 /unused' ;;
  esac
}
_sing_system_is_port_listening() { return 0; }
pgrep() { echo 4242; }
osascript() { touch "$tmp_dir/forbidden"; }
_sing_instance_start() { touch "$tmp_dir/forbidden"; }
_sing_instance_stop() { touch "$tmp_dir/forbidden"; }
_sing_instance_restart() { touch "$tmp_dir/forbidden"; }
_sing_run_proxy_app_launch() { touch "$tmp_dir/forbidden"; }
if sing-run t3 jp > "$tmp_dir/t3-running.out"; then
  fail "running T3 must require a manual quit"
fi
[[ "$(cat "$tmp_dir/t3-running.out")" == *"T3 Code 正在运行"* ]] || fail "T3 manual quit guidance missing"
if sing-run chatgpt jp > "$tmp_dir/running.out"; then
  fail "running ChatGPT must require a manual quit"
fi
[[ "$(cat "$tmp_dir/running.out")" == *"请先手动退出"* ]] || fail "manual quit guidance missing"
[[ ! -e "$tmp_dir/forbidden" ]] || fail "app or TUN was changed"

# The command resolves jp by default and dispatches without changing instances.
pgrep() { return 1; }
_sing_run_proxy_app_launch() { printf '%s\n' "$2" > "$tmp_dir/selected-proxy"; }
sing-run chatgpt >/dev/null || fail "chatgpt dispatch failed"
[[ "$(cat "$tmp_dir/selected-proxy")" == "http://127.0.0.1:7811" ]] || fail "wrong default proxy"
sing-run t3 >/dev/null || fail "T3 dispatch failed"
[[ "$(cat "$tmp_dir/selected-proxy")" == "http://127.0.0.1:7811" ]] || fail "wrong T3 default proxy"
sing-run codex >/dev/null || fail "codex dispatch failed"
[[ "$(cat "$tmp_dir/selected-proxy")" == "http://127.0.0.1:7831" ]] || fail "Codex default region changed"
[[ ! -e "$tmp_dir/forbidden" ]] || fail "dispatch changed TUN"

_sing_system_is_port_listening() { return 1; }
if sing-run chatgpt jp > "$tmp_dir/closed.out"; then
  fail "unreachable HTTP proxy must prevent launch"
fi
[[ "$(cat "$tmp_dir/closed.out")" == *"无法连接"* ]] || fail "connection failure guidance missing"
echo "App proxy launch checks passed"
