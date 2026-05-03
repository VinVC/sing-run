#!/bin/bash
# sing-run-plugin: Registration-based plugin framework
#
# Plugin format:
#   Directory plugin:  <search-path>/<name>/init.zsh
#   Single-file plugin: <search-path>/<name>.zsh
#
# API for plugins:
#   sing_plugin <name> <description>     Register plugin
#   sing_hook <hook_name> <func_name>    Register hook handler
#
# Available hooks:
#   pre_command   First handler returning 0 consumes the command
#   post_config   Pipeline: each handler's output feeds the next
#   status        Broadcast: all handlers called
#   status_count  Sum: all returned counts are summed
#   stop_all      Broadcast: called on `sing-run stop` (no args)
#   help          Broadcast: all handlers called

# =============================================================================
# Registry
# =============================================================================

typeset -gA _sing_plugin_registry=()

typeset -ga _sing_hooks_pre_command=()
typeset -ga _sing_hooks_post_config=()
typeset -ga _sing_hooks_status=()
typeset -ga _sing_hooks_status_count=()
typeset -ga _sing_hooks_stop_all=()
typeset -ga _sing_hooks_help=()

# =============================================================================
# Plugin Search Paths
# =============================================================================

if [[ -z "${SING_PLUGIN_PATH+x}" ]]; then
  SING_PLUGIN_PATH=(
    "$SING_RUN_SCRIPT_DIR/plugins"
    "$SING_RUN_SCRIPT_DIR/custom"
    "$SING_RUN_DIR/plugins"
  )
fi

# =============================================================================
# Registration API
# =============================================================================

sing_plugin() {
  local name=$1 desc=$2
  _sing_plugin_registry[$name]="$desc"
}

sing_hook() {
  local hook_name=$1 func_name=$2
  local arr_name="_sing_hooks_${hook_name}"
  if (( ${(P)+arr_name} )); then
    eval "${arr_name}+=(\"\$func_name\")"
  else
    echo "sing_hook: unknown hook '${hook_name}'" >&2
  fi
}

# =============================================================================
# Hook Dispatchers
# =============================================================================

_sing_plugin_pre_command() {
  for handler in "${_sing_hooks_pre_command[@]}"; do
    "$handler" "$@"
    [[ $? -eq 0 ]] && return 0
  done
  return 1
}

_sing_plugin_post_config() {
  local config=$1; shift
  for handler in "${_sing_hooks_post_config[@]}"; do
    config=$("$handler" "$config" "$@")
  done
  printf "%s" "$config"
}

_sing_plugin_status() {
  for handler in "${_sing_hooks_status[@]}"; do
    "$handler"
  done
}

_sing_plugin_status_count() {
  local total=0
  for handler in "${_sing_hooks_status_count[@]}"; do
    local count=$("$handler")
    if [[ -n "$count" && "$count" -gt 0 ]] 2>/dev/null; then
      total=$((total + count))
    fi
  done
  echo $total
}

_sing_plugin_stop_all() {
  for handler in "${_sing_hooks_stop_all[@]}"; do
    "$handler"
  done
}

_sing_plugin_help() {
  for handler in "${_sing_hooks_help[@]}"; do
    "$handler"
  done
}

# =============================================================================
# Plugin Loader
# =============================================================================

_sing_plugin_load_all() {
  local dir plugin_path

  for dir in "${SING_PLUGIN_PATH[@]}"; do
    [[ -d "$dir" ]] || continue

    # Directory plugins: <dir>/<name>/init.zsh
    shopt -s nullglob
    for plugin_path in "$dir"/*/init.zsh; do
      SING_PLUGIN_DIR="${plugin_path:h}"
      source "$plugin_path"
    done

    # Single-file plugins: <dir>/<name>.zsh (skip init.zsh in subdirs)
    # Bash: remove zsh (N) glob qualifier; use nullglob + existence check
    shopt -s nullglob
    for plugin_path in "$dir"/*.zsh; do
      [[ -f "$plugin_path" ]] || continue
      SING_PLUGIN_DIR="$(dirname "$plugin_path")"
      source "$plugin_path"
    done
    shopt -u nullglob
  done

  unset SING_PLUGIN_DIR
}

# =============================================================================
# Plugin Management
# =============================================================================

_sing_plugin_list() {
  if [[ ${#_sing_plugin_registry} -eq 0 ]]; then
    echo "  没有已加载的插件"
    return
  fi

  for name in "${(@k)_sing_plugin_registry}"; do
    local desc="${_sing_plugin_registry[$name]}"
    printf "  \033[1m%-12s\033[0m %s\n" "$name" "$desc"
  done
}
