#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# sing-run installer
# =============================================================================

SING_RUN_VERSION="1.0"
SING_RUN_REPO="https://github.com/VinVC/sing-run.git"
SING_RUN_REPO_ARCHIVE="https://github.com/VinVC/sing-run/archive/refs/heads/main.tar.gz"
SING_RUN_DEFAULT_INSTALL_DIR="$HOME/.sing-run-src"
SING_RUN_DATA_DIR="$HOME/.sing-run"
SING_RUN_SHELL_RC="$HOME/.zshrc"
SING_RUN_MARKER="# [sing-run] sing-box proxy manager"

# Colors (disabled if not a terminal)
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    DIM='\033[2m'
    RESET='\033[0m'
else
    RED='' GREEN='' YELLOW='' CYAN='' BOLD='' DIM='' RESET=''
fi

# =============================================================================
# Utility functions
# =============================================================================

info()  { echo -e "${CYAN}[info]${RESET}  $*"; }
ok()    { echo -e "${GREEN}[ok]${RESET}    $*"; }
warn()  { echo -e "${YELLOW}[warn]${RESET}  $*"; }
err()   { echo -e "${RED}[error]${RESET} $*" >&2; }
step()  { echo -e "${CYAN}[setup]${RESET} $*"; }

confirm() {
    local prompt="$1"
    if [ "${OPT_YES:-0}" = "1" ]; then
        return 0
    fi
    echo -en "$prompt "
    read -r answer
    [[ "$answer" == "y" || "$answer" == "Y" ]]
}

# =============================================================================
# Dependency checking
# =============================================================================

check_dep() {
    local name="$1"
    local required="${2:-true}"
    local version_flag="${3:---version}"
    local install_hint="${4:-}"

    if command -v "$name" &>/dev/null; then
        local ver
        ver=$("$name" $version_flag 2>&1 | head -1 | grep -oE '[0-9]+\.[0-9]+[0-9.]*' | head -1 || echo "")
        if [ -n "$ver" ]; then
            ok "$name ${DIM}($ver)${RESET}"
        else
            ok "$name"
        fi
        return 0
    else
        if [ "$required" = "true" ]; then
            warn "${name} -- ${BOLD}not found${RESET}"
        else
            warn "${name} -- not found ${DIM}(optional)${RESET}"
        fi
        if [ -n "$install_hint" ]; then
            echo -e "        ${DIM}Install: ${install_hint}${RESET}"
        fi
        return 1
    fi
}

check_all_deps() {
    local missing=0
    local os_type
    os_type="$(uname -s)"

    echo ""
    echo -e "${BOLD}Checking dependencies...${RESET}"
    echo ""

    # zsh (required -- sing-run is a zsh project)
    if ! check_dep "zsh" "true" "--version" ""; then
        if [ "$os_type" = "Linux" ]; then
            echo -e "        ${DIM}Install: sudo apt install zsh  ${DIM}# Debian/Ubuntu${RESET}"
        fi
        missing=1
    fi

    # sing-box (required for running proxies)
    local sb_hint=""
    if [ "$os_type" = "Darwin" ]; then
        sb_hint="brew install sing-box"
    elif [ "$os_type" = "Linux" ]; then
        sb_hint="https://sing-box.sagernet.org/installation/package-manager/"
    fi
    check_dep "sing-box" "true" "version" "$sb_hint" || missing=1

    # yq (required for YAML parsing)
    local yq_hint=""
    if [ "$os_type" = "Darwin" ]; then
        yq_hint="brew install yq"
    elif [ "$os_type" = "Linux" ]; then
        yq_hint="https://github.com/mikefarah/yq#install"
    fi
    check_dep "yq" "true" "--version" "$yq_hint" || missing=1

    # jq (required for JSON processing)
    local jq_hint=""
    if [ "$os_type" = "Darwin" ]; then
        jq_hint="brew install jq"
    elif [ "$os_type" = "Linux" ]; then
        jq_hint="sudo apt install jq"
    fi
    check_dep "jq" "true" "--version" "$jq_hint" || missing=1

    # curl (required for subscriptions and rule-set downloads)
    check_dep "curl" "true" "--version" "" || missing=1

    # python3 (required for vmess subscription parsing)
    local py_hint=""
    if [ "$os_type" = "Darwin" ]; then
        py_hint="brew install python3"
    elif [ "$os_type" = "Linux" ]; then
        py_hint="sudo apt install python3"
    fi
    check_dep "python3" "true" "--version" "$py_hint" || missing=1

    echo ""

    if [ "$missing" = "1" ]; then
        warn "Some dependencies are missing. sing-run will not work fully until they are installed."
        # Build a consolidated brew/apt command
        local brew_pkgs="" apt_pkgs=""
        command -v sing-box &>/dev/null || { brew_pkgs+=" sing-box"; }
        command -v yq &>/dev/null       || { brew_pkgs+=" yq"; }
        command -v jq &>/dev/null       || { brew_pkgs+=" jq"; apt_pkgs+=" jq"; }
        command -v python3 &>/dev/null  || { brew_pkgs+=" python3"; apt_pkgs+=" python3"; }
        command -v zsh &>/dev/null      || { apt_pkgs+=" zsh"; }

        if [ "$os_type" = "Darwin" ] && [ -n "$brew_pkgs" ]; then
            if command -v brew &>/dev/null; then
                echo -e "  ${BOLD}brew install${brew_pkgs}${RESET}"
            else
                echo -e "  Homebrew not found. Install from: ${BOLD}https://brew.sh${RESET}"
                echo -e "  Then run: ${BOLD}brew install${brew_pkgs}${RESET}"
            fi
        elif [ "$os_type" = "Linux" ] && [ -n "$apt_pkgs" ]; then
            echo -e "  ${BOLD}sudo apt install${apt_pkgs}${RESET}"
        fi
        echo ""
    else
        ok "All dependencies satisfied"
        echo ""
    fi

    return 0
}

# =============================================================================
# Install directory detection
# =============================================================================

detect_install_dir() {
    local script_dir
    # If running from a file (not piped), check if we're inside the repo
    if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
        script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        if [ -f "$script_dir/sing-run.sh" ]; then
            echo "$script_dir"
            return 0
        fi
    fi

    # Use configured or default directory
    echo "${SING_RUN_INSTALL_DIR:-$SING_RUN_DEFAULT_INSTALL_DIR}"
}

# =============================================================================
# Install
# =============================================================================

do_install() {
    local install_dir
    install_dir="$(detect_install_dir)"

    echo ""
    echo -e "${BOLD}sing-run installer${RESET} v${SING_RUN_VERSION}"
    echo ""

    # OS check
    local os_type arch
    os_type="$(uname -s)"
    arch="$(uname -m)"
    case "$os_type" in
        Darwin) info "macOS ($arch)" ;;
        Linux)  info "Linux ($arch)" ;;
        *)
            err "Unsupported OS: $os_type"
            exit 1
            ;;
    esac

    # Dependency check
    check_all_deps

    # Clone or detect existing repo
    if [ -f "$install_dir/sing-run.sh" ]; then
        step "Using existing installation at ${BOLD}${install_dir}${RESET}"
    else
        step "Installing to ${BOLD}${install_dir}${RESET} ..."
        if command -v git &>/dev/null; then
            git clone --depth 1 "$SING_RUN_REPO" "$install_dir"
        elif command -v curl &>/dev/null; then
            warn "git not found, downloading archive..."
            mkdir -p "$install_dir"
            curl -sL "$SING_RUN_REPO_ARCHIVE" | tar xz --strip-components=1 -C "$install_dir"
        else
            err "Neither git nor curl available. Cannot download sing-run."
            exit 1
        fi

        if [ ! -f "$install_dir/sing-run.sh" ]; then
            err "Installation failed: sing-run.sh not found in $install_dir"
            exit 1
        fi
        ok "Downloaded"
    fi

    # Create sources.sh from example
    if [ -f "$install_dir/sources.sh" ]; then
        step "sources.sh already exists ${DIM}(skipped)${RESET}"
    else
        if [ -f "$install_dir/sources.sh.example" ]; then
            cp "$install_dir/sources.sh.example" "$install_dir/sources.sh"
            step "Created ${BOLD}sources.sh${RESET} from template"
            echo -e "        ${DIM}Edit $install_dir/sources.sh to add your subscription URLs${RESET}"
        else
            warn "sources.sh.example not found, skipping"
        fi
    fi

    # Create data directory
    mkdir -p "$SING_RUN_DATA_DIR"

    # Shell integration
    setup_shell_rc "$install_dir"

    # Done
    echo ""
    echo -e "${GREEN}${BOLD}Installation complete!${RESET}"
    echo ""
    echo "Next steps:"
    local step_num=1

    # Check for missing deps to remind user
    local has_missing=0
    for dep in sing-box yq jq python3 zsh; do
        command -v "$dep" &>/dev/null || has_missing=1
    done
    if [ "$has_missing" = "1" ]; then
        echo "  ${step_num}. Install missing dependencies (see above)"
        step_num=$((step_num + 1))
    fi

    echo "  ${step_num}. source ~/.zshrc"
    step_num=$((step_num + 1))
    echo "  ${step_num}. Edit ${install_dir}/sources.sh (add subscription URLs)"
    step_num=$((step_num + 1))
    echo "  ${step_num}. sing-run update-nodes"
    step_num=$((step_num + 1))
    echo "  ${step_num}. sing-run --help"
    echo ""
}

# =============================================================================
# Shell RC integration
# =============================================================================

setup_shell_rc() {
    local install_dir="$1"
    local source_line="source \"${install_dir}/sing-run.sh\""

    # Create ~/.zshrc if it doesn't exist
    if [ ! -f "$SING_RUN_SHELL_RC" ]; then
        touch "$SING_RUN_SHELL_RC"
    fi

    # Check if already configured (marker comment or existing source line)
    if grep -qF "[sing-run]" "$SING_RUN_SHELL_RC" 2>/dev/null; then
        step "~/.zshrc already configured ${DIM}(skipped)${RESET}"
        return 0
    fi
    if grep -qE 'source.*sing-run\.sh' "$SING_RUN_SHELL_RC" 2>/dev/null; then
        step "~/.zshrc already has sing-run source line ${DIM}(skipped)${RESET}"
        return 0
    fi

    # Append marker + source line
    {
        echo ""
        echo "$SING_RUN_MARKER"
        echo "$source_line"
    } >> "$SING_RUN_SHELL_RC"

    step "Added to ${BOLD}~/.zshrc${RESET}"
}

remove_shell_rc() {
    if [ ! -f "$SING_RUN_SHELL_RC" ]; then
        return 0
    fi

    if ! grep -qE '\[sing-run\]|source.*sing-run\.sh' "$SING_RUN_SHELL_RC" 2>/dev/null; then
        info "sing-run not found in ~/.zshrc"
        return 0
    fi

    # Remove marker lines, source lines referencing sing-run.sh,
    # and comment lines directly above source lines (e.g. "# Source sing-run functions")
    local tmp="${SING_RUN_SHELL_RC}.sing-run-tmp"
    awk '
        /\[sing-run\]/ { next }
        /^#.*sing-run/ {
            hold = $0
            next
        }
        hold && /source.*sing-run\.sh/ {
            hold = ""
            next
        }
        hold {
            print hold
            hold = ""
        }
        /source.*sing-run\.sh/ { next }
        { print }
        END { if (hold) print hold }
    ' "$SING_RUN_SHELL_RC" > "$tmp"
    mv "$tmp" "$SING_RUN_SHELL_RC"

    step "Removed sing-run from ${BOLD}~/.zshrc${RESET}"
}

# =============================================================================
# Update
# =============================================================================

do_update() {
    echo ""
    echo -e "${BOLD}sing-run updater${RESET}"
    echo ""

    # Find install directory
    local install_dir=""

    # Try from --dir flag
    if [ -n "${OPT_DIR:-}" ]; then
        install_dir="$OPT_DIR"
    fi

    # Try to detect from ~/.zshrc
    if [ -z "$install_dir" ] && [ -f "$SING_RUN_SHELL_RC" ]; then
        install_dir=$(grep -A1 '\[sing-run\]' "$SING_RUN_SHELL_RC" 2>/dev/null \
            | grep '^source' \
            | sed 's/^source "\{0,1\}\(.*\)\/sing-run\.sh"\{0,1\}$/\1/' \
            | head -1)
    fi

    # Try default location
    if [ -z "$install_dir" ] || [ ! -d "$install_dir" ]; then
        install_dir="$(detect_install_dir)"
    fi

    if [ ! -f "$install_dir/sing-run.sh" ]; then
        err "Cannot find sing-run installation."
        err "Use --dir to specify the install directory, or run install first."
        exit 1
    fi

    step "Updating ${BOLD}${install_dir}${RESET} ..."

    if [ -d "$install_dir/.git" ]; then
        (cd "$install_dir" && git pull)
        ok "Updated via git"
    else
        warn "Not a git repository. Re-downloading..."
        local tmp_dir
        tmp_dir="$(mktemp -d)"
        curl -sL "$SING_RUN_REPO_ARCHIVE" | tar xz --strip-components=1 -C "$tmp_dir"
        # Preserve user config
        if [ -f "$install_dir/sources.sh" ]; then
            cp "$install_dir/sources.sh" "$tmp_dir/sources.sh"
        fi
        rsync -a --exclude='sources.sh' "$tmp_dir/" "$install_dir/"
        rm -rf "$tmp_dir"
        ok "Updated via archive download"
    fi

    echo ""
    check_all_deps

    echo -e "${GREEN}${BOLD}Update complete!${RESET}"
    echo ""
    echo "If you have running instances, restart them to use the new version:"
    echo "  sing-run restart"
    echo ""
}

# =============================================================================
# Uninstall
# =============================================================================

do_uninstall() {
    echo ""
    echo -e "${BOLD}sing-run uninstaller${RESET}"
    echo ""

    # --yes does NOT auto-approve destructive deletions in uninstall
    local saved_yes="${OPT_YES:-0}"
    OPT_YES=0

    # Remove shell integration
    remove_shell_rc

    # Ask about data directory
    if [ -d "$SING_RUN_DATA_DIR" ]; then
        echo ""
        if confirm "${YELLOW}[ask]${RESET}  Remove data directory ${BOLD}${SING_RUN_DATA_DIR}${RESET}? (configs, logs, rules) [y/N]"; then
            rm -rf "$SING_RUN_DATA_DIR"
            step "Removed ${BOLD}${SING_RUN_DATA_DIR}${RESET}"
        else
            info "Kept ${SING_RUN_DATA_DIR}"
        fi
    fi

    # Find and ask about source directory
    local install_dir=""
    if [ -n "${OPT_DIR:-}" ]; then
        install_dir="$OPT_DIR"
    else
        install_dir="$(detect_install_dir)"
    fi

    if [ -d "$install_dir" ] && [ -f "$install_dir/sing-run.sh" ]; then
        echo ""
        if confirm "${YELLOW}[ask]${RESET}  Remove source directory ${BOLD}${install_dir}${RESET}? [y/N]"; then
            rm -rf "$install_dir"
            step "Removed ${BOLD}${install_dir}${RESET}"
        else
            info "Kept ${install_dir}"
        fi
    fi

    # Restore OPT_YES
    OPT_YES="$saved_yes"

    echo ""
    echo -e "${GREEN}${BOLD}Uninstall complete.${RESET}"
    echo ""
    echo -e "${DIM}Note: sing-box, yq, jq were NOT removed (may be used by other tools).${RESET}"
    echo ""
}

# =============================================================================
# Argument parsing
# =============================================================================

show_help() {
    cat <<'EOF'
sing-run installer

Usage:
  install.sh [command] [options]

Commands:
  install     Install sing-run (default)
  update      Update to latest version
  uninstall   Remove sing-run

Options:
  -y, --yes   Skip confirmation prompts (install/update only)
  --dir PATH  Override install directory
  -h, --help  Show this help

Examples:
  ./install.sh                  # Install
  ./install.sh update           # Update
  ./install.sh uninstall        # Uninstall
  ./install.sh install --yes    # Non-interactive install

One-liner remote install:
  curl -fsSL https://raw.githubusercontent.com/VinVC/sing-run/main/install.sh | bash
EOF
}

main() {
    local command="install"
    OPT_YES=0
    OPT_DIR=""

    while [ $# -gt 0 ]; do
        case "$1" in
            install|update|uninstall)
                command="$1"
                shift
                ;;
            -y|--yes)
                OPT_YES=1
                shift
                ;;
            --dir)
                OPT_DIR="$2"
                SING_RUN_INSTALL_DIR="$2"
                shift 2
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                err "Unknown argument: $1"
                echo ""
                show_help
                exit 1
                ;;
        esac
    done

    case "$command" in
        install)   do_install ;;
        update)    do_update ;;
        uninstall) do_uninstall ;;
    esac
}

main "$@"
