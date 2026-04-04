#!/bin/bash
# install_rails_deps.sh
# Installs Ruby 3.3+ and Node.js 22+ via mise for Rails development.
# Supports CN mirrors (Aliyun / oss.1024code.com) for users in China.
#
# Usage:
#   bash install_rails_deps.sh            # install ruby + node
#   bash install_rails_deps.sh ruby       # install ruby only
#   bash install_rails_deps.sh node       # install node only

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_info()    { echo -e "${BLUE}ℹ${NC} $1"; }
print_success() { echo -e "${GREEN}✓${NC} $1"; }
print_warning() { echo -e "${YELLOW}⚠${NC} $1"; }
print_error()   { echo -e "${RED}✗${NC} $1"; }
print_step()    { echo -e "\n${BLUE}==>${NC} $1"; }

# --------------------------------------------------------------------------
# What to install (controlled by first argument; default = both)
# --------------------------------------------------------------------------
INSTALL_TARGET="${1:-all}"  # all | ruby | node

# --------------------------------------------------------------------------
# Network / mirror configuration
# --------------------------------------------------------------------------
SLOW_THRESHOLD_MS=5000
USE_CN_MIRRORS=false

DEFAULT_MISE_INSTALL_URL="https://mise.run"
DEFAULT_NPM_REGISTRY="https://registry.npmjs.org"

CN_CDN_BASE_URL="https://oss.1024code.com"
CN_MISE_INSTALL_URL="${CN_CDN_BASE_URL}/mise.sh"
CN_RUBY_PRECOMPILED_URL="${CN_CDN_BASE_URL}/ruby/ruby-{version}.{platform}.tar.gz"
CN_RUBYGEMS_URL="https://mirrors.aliyun.com/rubygems/"
CN_NPM_REGISTRY="https://registry.npmmirror.com"
CN_NODE_MIRROR_URL="https://cdn.npmmirror.com/binaries/node/"

MISE_INSTALL_URL="$DEFAULT_MISE_INSTALL_URL"
NPM_REGISTRY_URL="$DEFAULT_NPM_REGISTRY"
NODE_MIRROR_URL=""
RUBY_VERSION_SPEC="ruby@3.3"
NODE_VERSION_SPEC="node@22"

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------
command_exists() { command -v "$1" >/dev/null 2>&1; }

version_ge() {
    printf '%s\n%s\n' "$2" "$1" | sort -V -C
}

_probe_url() {
    local url="$1" timeout_sec=5 curl_output http_code total_time elapsed_ms
    curl_output=$(curl -s -o /dev/null -w "%{http_code} %{time_total}" \
        --connect-timeout "$timeout_sec" --max-time "$timeout_sec" \
        "$url" 2>/dev/null) || true
    http_code="${curl_output%% *}"
    total_time="${curl_output#* }"
    if [ -z "$http_code" ] || [ "$http_code" = "000" ] || [ "$http_code" = "$curl_output" ]; then
        echo "timeout"
    else
        elapsed_ms=$(awk -v s="$total_time" 'BEGIN { printf "%d", s * 1000 }')
        echo "$elapsed_ms"
    fi
}

_is_slow_or_unreachable() {
    local r="$1"
    [ "$r" = "timeout" ] && return 0
    [ "$r" -ge "$SLOW_THRESHOLD_MS" ] 2>/dev/null
}

_probe_url_with_retry() {
    local url="$1" max="${2:-2}" result
    for _ in $(seq 1 "$max"); do
        result=$(_probe_url "$url")
        ! _is_slow_or_unreachable "$result" && { echo "$result"; return 0; }
    done
    echo "$result"
}

# Detect current shell and rc file
detect_shell() {
    local name
    name=$(basename "$SHELL")
    case "$name" in
        zsh)  CURRENT_SHELL="zsh";  SHELL_RC="$HOME/.zshrc" ;;
        fish) CURRENT_SHELL="fish"; SHELL_RC="$HOME/.config/fish/config.fish" ;;
        *)
            CURRENT_SHELL="bash"
            if [ "$(uname -s)" = "Darwin" ]; then
                SHELL_RC="$HOME/.bash_profile"
            else
                SHELL_RC="$HOME/.bashrc"
            fi
            ;;
    esac
    print_info "Shell: $CURRENT_SHELL  (rc: $SHELL_RC)"
}

# --------------------------------------------------------------------------
# Network region detection
# --------------------------------------------------------------------------
detect_network_region() {
    print_step "Detecting network region..."

    local google_result baidu_result
    google_result=$(_probe_url "https://www.google.com")
    baidu_result=$(_probe_url "https://www.baidu.com")

    local google_ok=false baidu_ok=false
    ! _is_slow_or_unreachable "$google_result" && google_ok=true
    ! _is_slow_or_unreachable "$baidu_result"  && baidu_ok=true

    if [ "$google_ok" = true ]; then
        print_success "Region: global"
    elif [ "$baidu_ok" = true ]; then
        print_success "Region: China — probing CN mirrors..."

        local cdn_result mirror_result
        cdn_result=$(_probe_url_with_retry "$CN_MISE_INSTALL_URL")
        mirror_result=$(_probe_url_with_retry "$CN_RUBYGEMS_URL")

        local cdn_ok=false mirror_ok=false
        ! _is_slow_or_unreachable "$cdn_result"    && cdn_ok=true
        ! _is_slow_or_unreachable "$mirror_result" && mirror_ok=true

        if [ "$cdn_ok" = true ] || [ "$mirror_ok" = true ]; then
            USE_CN_MIRRORS=true
            MISE_INSTALL_URL="$CN_MISE_INSTALL_URL"
            NPM_REGISTRY_URL="$CN_NPM_REGISTRY"
            NODE_MIRROR_URL="$CN_NODE_MIRROR_URL"
            RUBY_VERSION_SPEC="ruby@3.4.8"   # pinned precompiled build on CN CDN
            print_success "CN mirrors active"
        else
            print_warning "CN mirrors unreachable — falling back to global sources"
        fi
    else
        print_warning "Region unknown — using global sources"
    fi
}

# --------------------------------------------------------------------------
# mise installation
# --------------------------------------------------------------------------
ensure_mise() {
    local mise_bin
    # Prefer the user-local bin, fall back to PATH
    if [ -x "$HOME/.local/bin/mise" ]; then
        mise_bin="$HOME/.local/bin/mise"
    elif command_exists mise; then
        mise_bin="mise"
    fi

    if [ -n "$mise_bin" ]; then
        print_success "mise already installed: $($mise_bin --version 2>/dev/null || echo 'n/a')"
        MISE_BIN="$mise_bin"
        return 0
    fi

    print_step "Installing mise..."
    if curl -fsSL "$MISE_INSTALL_URL" | sh; then
        export PATH="$HOME/.local/bin:$PATH"
        eval "$(~/.local/bin/mise activate bash 2>/dev/null)" 2>/dev/null || true

        # Persist mise activation to shell rc
        detect_shell
        local init_line='eval "$(~/.local/bin/mise activate '"$CURRENT_SHELL"')"'
        if ! grep -q "mise activate" "$SHELL_RC" 2>/dev/null; then
            echo "$init_line" >> "$SHELL_RC"
            print_info "Added mise activation to $SHELL_RC"
        fi

        MISE_BIN="$HOME/.local/bin/mise"
        print_success "mise installed"
    else
        print_error "Failed to install mise"
        return 1
    fi
}

# Apply CN Node mirror to mise settings (must be called after MISE_BIN is set)
apply_cn_node_mirror() {
    [ "$USE_CN_MIRRORS" = true ] && [ -n "$NODE_MIRROR_URL" ] || return 0
    "$MISE_BIN" settings node.mirror_url="$NODE_MIRROR_URL" 2>/dev/null || true
    print_info "mise Node mirror → ${NODE_MIRROR_URL}"
}

# --------------------------------------------------------------------------
# Ruby installation via mise
# --------------------------------------------------------------------------
install_ruby() {
    print_step "Installing Ruby via mise..."

    # Check if a compatible Ruby already exists under mise
    if command_exists ruby; then
        local current
        current=$(ruby -e 'puts RUBY_VERSION' 2>/dev/null)
        if version_ge "$current" "3.3.0"; then
            print_success "Ruby $current already satisfies >= 3.3.0 — skipping"
            return 0
        fi
        print_info "Current Ruby $current is too old — installing $RUBY_VERSION_SPEC"
    fi

    # Configure precompiled Ruby for CN mirrors
    if [ "$USE_CN_MIRRORS" = true ]; then
        "$MISE_BIN" settings ruby.compile=false 2>/dev/null || true
        "$MISE_BIN" settings ruby.precompiled_url="$CN_RUBY_PRECOMPILED_URL" 2>/dev/null || true
    else
        "$MISE_BIN" settings unset ruby.compile          2>/dev/null || true
        "$MISE_BIN" settings unset ruby.precompiled_url  2>/dev/null || true
    fi

    if "$MISE_BIN" use -g "$RUBY_VERSION_SPEC"; then
        # Re-activate so the new ruby is on PATH in this session
        eval "$("$MISE_BIN" activate bash 2>/dev/null)" 2>/dev/null || true
        export PATH="$HOME/.local/bin:$PATH"

        local installed_ver
        installed_ver=$(ruby -e 'puts RUBY_VERSION' 2>/dev/null || echo "unknown")
        print_success "Ruby $installed_ver installed"

        # Configure gem source for CN users
        if [ "$USE_CN_MIRRORS" = true ]; then
            local gemrc="$HOME/.gemrc"
            if ! grep -q "$CN_RUBYGEMS_URL" "$gemrc" 2>/dev/null; then
                cat > "$gemrc" <<GEMRC
:sources:
  - ${CN_RUBYGEMS_URL}
GEMRC
                print_info "gem source → ${CN_RUBYGEMS_URL}"
            fi
        fi

        # Reinstall openclacky in the new Ruby (gemrc already configured above)
        "$MISE_BIN" exec -- gem install openclacky --no-document \
            && print_success "openclacky reinstalled" \
            || print_warning "Could not reinstall openclacky — run manually: gem install openclacky --no-document"
    else
        print_error "Failed to install Ruby via mise"
        return 1
    fi
}

# --------------------------------------------------------------------------
# Node.js installation via mise
# --------------------------------------------------------------------------
install_node() {
    print_step "Installing Node.js via mise..."

    if command_exists node; then
        local current
        current=$(node -v 2>/dev/null | sed 's/v//')
        if version_ge "$current" "22.0.0"; then
            print_success "Node.js $current already satisfies >= 22.0.0 — skipping"
            return 0
        fi
        print_info "Current Node.js $current is too old — installing $NODE_VERSION_SPEC"
    fi

    apply_cn_node_mirror

    if "$MISE_BIN" use -g "$NODE_VERSION_SPEC"; then
        eval "$("$MISE_BIN" activate bash 2>/dev/null)" 2>/dev/null || true
        local installed_ver
        installed_ver=$(node -v 2>/dev/null || echo "unknown")
        print_success "Node.js $installed_ver installed"

        # Configure npm registry for CN users
        if [ "$USE_CN_MIRRORS" = true ] && command_exists npm; then
            npm config set registry "$NPM_REGISTRY_URL" 2>/dev/null || true
            print_info "npm registry → ${NPM_REGISTRY_URL}"
        fi
    else
        print_error "Failed to install Node.js via mise"
        return 1
    fi
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------
main() {
    echo ""
    echo "╔═══════════════════════════════════════════════════════════╗"
    echo "║                                                           ║"
    echo "║   🔧 Rails Dependencies Installer                        ║"
    echo "║                                                           ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo ""

    detect_network_region

    # Ensure system-level build tools are present (Xcode CLT / build-essential)
    local sys_deps="$HOME/.clacky/scripts/install_system_deps.sh"
    if [ -f "$sys_deps" ]; then
        bash "$sys_deps" || print_warning "System deps install had warnings — continuing"
    fi

    ensure_mise || exit 1

    case "$INSTALL_TARGET" in
        ruby) install_ruby || exit 1 ;;
        node) install_node || exit 1 ;;
        *)
            install_ruby || exit 1
            install_node || exit 1
            ;;
    esac

    echo ""
    print_success "Done. Please re-source your shell or open a new terminal if paths changed."
    echo ""
}

main "$@"
