#!/bin/bash
# Install system-level build dependencies required by OpenClacky tools.
#
# macOS  : Xcode Command Line Tools (provides python3, git, make, clang, etc.)
# Linux  : build-essential + python3 + git + curl (via apt on Ubuntu/Debian)
#
# This script is copied to ~/.clacky/scripts/ on first run and can be invoked
# by any skill or tool that requires system-level dependencies.

set -e

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

command_exists() { command -v "$1" >/dev/null 2>&1; }

# --------------------------------------------------------------------------
# OS detection
# --------------------------------------------------------------------------
detect_os() {
    case "$(uname -s)" in
        Darwin*) OS=macOS ;;
        Linux*)  OS=Linux ;;
        *)       OS=Unknown ;;
    esac

    if [ "$OS" = "Linux" ] && [ -f /etc/os-release ]; then
        # shellcheck source=/dev/null
        . /etc/os-release
        DISTRO=$ID
    else
        DISTRO=unknown
    fi
}

# --------------------------------------------------------------------------
# macOS: Xcode Command Line Tools
# --------------------------------------------------------------------------

# More reliable check: CLT git binary must actually exist
_clt_installed() {
    [ -e "/Library/Developer/CommandLineTools/usr/bin/git" ]
}

ensure_xcode_clt() {
    print_step "Checking Xcode Command Line Tools..."

    if _clt_installed; then
        print_success "Xcode CLT already installed"
        return 0
    fi

    print_info "Xcode CLT not found — attempting headless install via softwareupdate..."

    # The placeholder file prompts softwareupdate to list CLT packages
    local clt_placeholder="/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress"
    touch "$clt_placeholder"

    # Find the latest available CLT label
    local clt_label
    clt_label=$(softwareupdate -l 2>/dev/null \
        | grep -B 1 -E 'Command Line Tools' \
        | awk -F'*' '/^ *\*/ {print $2}' \
        | sed -e 's/^ *Label: //' -e 's/^ *//' \
        | sort -V \
        | tail -n1)

    local headless_ok=false
    if [ -n "$clt_label" ]; then
        print_info "Found package: $clt_label"
        print_info "Running softwareupdate (may show a system auth dialog)..."

        # Try without sudo first — macOS 14+ can prompt via system dialog
        if softwareupdate -i "$clt_label" --agree-to-license 2>/dev/null; then
            xcode-select --switch "/Library/Developer/CommandLineTools" 2>/dev/null || true
            headless_ok=true
        # Fallback: try with sudo -n (succeeds only if password is cached)
        elif sudo -n softwareupdate -i "$clt_label" --agree-to-license 2>/dev/null; then
            sudo xcode-select --switch "/Library/Developer/CommandLineTools" 2>/dev/null || true
            headless_ok=true
        fi
    else
        print_warning "softwareupdate could not find a CLT package"
    fi

    rm -f "$clt_placeholder"

    if _clt_installed; then
        print_success "Xcode CLT installed successfully"
        return 0
    fi

    # Both headless paths failed — tell user to run manually
    if [ "$headless_ok" = false ]; then
        print_warning "Headless install failed (sudo password required or package not found)"
    fi

    print_error "Could not install Xcode CLT automatically."
    echo ""
    echo "  Please run this command in your terminal and re-run this script:"
    echo ""
    echo "    sudo xcode-select --install"
    echo ""
    echo "  Or from System Settings → General → Software Update."
    return 1
}

# --------------------------------------------------------------------------
# Linux: build-essential + python3 + git + curl
# --------------------------------------------------------------------------

# Quick network probe — returns latency in ms or "timeout"
_probe_url() {
    local url="$1"
    local out
    out=$(curl -s -o /dev/null -w "%{http_code} %{time_total}" \
        --connect-timeout 5 --max-time 5 "$url" 2>/dev/null) || true
    local http_code="${out%% *}"
    local total_time="${out#* }"
    if [ -z "$http_code" ] || [ "$http_code" = "000" ] || [ "$http_code" = "$out" ]; then
        echo "timeout"; return
    fi
    awk -v s="$total_time" 'BEGIN { printf "%d", s * 1000 }'
}

_is_slow() {
    local r="$1"
    [ "$r" = "timeout" ] && return 0
    [ "${r:-9999}" -ge 5000 ] 2>/dev/null
}

# Optionally configure Aliyun apt mirror for CN users
setup_apt_mirror() {
    print_info "Detecting network region for apt mirror..."
    local google baidu
    google=$(_probe_url "https://www.google.com")
    baidu=$(_probe_url "https://www.baidu.com")

    if ! _is_slow "$google"; then
        print_info "Region: global — using default apt sources"
        return 0
    fi

    if ! _is_slow "$baidu"; then
        print_info "Region: China — configuring Aliyun apt mirror"
        local codename="${VERSION_CODENAME:-jammy}"
        local components="main restricted universe multiverse"
        local arch
        arch=$(dpkg --print-architecture 2>/dev/null || uname -m)
        # arm64 uses ubuntu-ports mirror; amd64/i386 uses standard ubuntu mirror
        if [ "$arch" = "arm64" ] || [ "$arch" = "aarch64" ]; then
            local mirror="https://mirrors.aliyun.com/ubuntu-ports/"
        else
            local mirror="https://mirrors.aliyun.com/ubuntu/"
        fi
        sudo tee /etc/apt/sources.list > /dev/null <<EOF
deb ${mirror} ${codename} ${components}
deb ${mirror} ${codename}-updates ${components}
deb ${mirror} ${codename}-backports ${components}
deb ${mirror} ${codename}-security ${components}
EOF
        print_success "Aliyun apt mirror configured"
    else
        print_warning "Network region unknown — using default apt sources"
    fi
}

ensure_linux_deps() {
    print_step "Checking Linux build dependencies..."

    local missing=()
    command_exists gcc     || missing+=("build-essential")
    command_exists python3 || missing+=("python3")
    command_exists git     || missing+=("git")
    command_exists curl    || missing+=("curl")

    if [ ${#missing[@]} -eq 0 ]; then
        print_success "All dependencies already installed"
        return 0
    fi

    print_info "Missing: ${missing[*]}"

    if [ "$DISTRO" = "ubuntu" ] || [ "$DISTRO" = "debian" ]; then
        setup_apt_mirror
        print_info "Running apt-get update..."
        sudo apt-get update -qq
        print_info "Installing: ${missing[*]}"
        sudo apt-get install -y "${missing[@]}"
        print_success "Dependencies installed"
    else
        print_error "Unsupported Linux distribution: $DISTRO"
        print_info "Please install manually: gcc python3 git curl (or equivalent for your distro)"
        return 1
    fi
}

# --------------------------------------------------------------------------
# Verify key tools are available after install
# --------------------------------------------------------------------------
verify_deps() {
    print_step "Verifying installed tools..."
    local failed=false

    for tool in python3 git curl make; do
        if command_exists "$tool"; then
            print_success "$tool  $(command -v "$tool")"
        else
            print_warning "$tool  not found"
            failed=true
        fi
    done

    if [ "$failed" = true ]; then
        print_warning "Some tools are still missing. You may need to restart your shell."
    fi
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------
main() {
    echo ""
    echo "System Dependencies Setup"
    echo "========================="

    detect_os
    print_info "OS: $OS"
    [ "$OS" = "Linux" ] && print_info "Distro: $DISTRO"
    echo ""

    case "$OS" in
        macOS)
            ensure_xcode_clt || exit 1
            ;;
        Linux)
            ensure_linux_deps || exit 1
            ;;
        *)
            print_error "Unsupported OS: $OS"
            exit 1
            ;;
    esac

    verify_deps

    echo ""
    print_success "Done. System dependencies are ready."
    echo ""
}

main "$@"
