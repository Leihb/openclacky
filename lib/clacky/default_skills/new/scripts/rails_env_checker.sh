#!/bin/bash
# Rails Environment Checker
# This script checks and installs required dependencies for Rails 7.x projects
# Run this BEFORE executing bin/setup in a Rails project

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Print colored messages
print_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

print_step() {
    echo -e "\n${BLUE}==>${NC} $1"
}

# Detect OS
detect_os() {
    case "$(uname -s)" in
        Linux*)     OS=Linux;;
        Darwin*)    OS=macOS;;
        CYGWIN*)    OS=Windows;;
        MINGW*)     OS=Windows;;
        *)          OS=Unknown;;
    esac
    print_info "Detected OS: $OS"

    # Detect Linux distribution
    if [ "$OS" = "Linux" ]; then
        if [ -f /etc/os-release ]; then
            . /etc/os-release
            DISTRO=$ID
            print_info "Detected Linux distribution: $DISTRO"
        else
            DISTRO=unknown
        fi
    fi
}

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Compare version strings
version_ge() {
    # Returns 0 (true) if $1 >= $2
    printf '%s\n%s\n' "$2" "$1" | sort -V -C
}

# Check Node.js version
check_nodejs() {
    if command_exists node; then
        NODE_VERSION=$(node -v | sed 's/v//')
        print_info "Found Node.js version: $NODE_VERSION"

        if version_ge "$NODE_VERSION" "22.0.0"; then
            print_success "Node.js version is compatible (>= 22.0.0)"
            return 0
        else
            print_warning "Node.js version $NODE_VERSION is too old (need >= 22.0.0)"
            return 1
        fi
    else
        print_warning "Node.js is not installed"
        return 1
    fi
}

# Check PostgreSQL
check_postgresql() {
    if command_exists psql; then
        PG_VERSION=$(psql --version | awk '{print $3}')
        print_info "Found PostgreSQL version: $PG_VERSION"
        print_success "PostgreSQL is installed"
        
        # Check if postgres user exists
        if command_exists createuser; then
            print_info "Checking PostgreSQL user 'postgres'..."
            if psql -U postgres -c '\q' 2>/dev/null; then
                print_success "PostgreSQL user 'postgres' exists"
            else
                print_warning "PostgreSQL user 'postgres' does not exist"
                print_info "You may need to create it with: createuser -s postgres"
            fi
        fi
        return 0
    else
        print_warning "PostgreSQL is not installed"
        return 1
    fi
}

# Check Ruby version
check_ruby() {
    if command_exists ruby; then
        RUBY_VERSION=$(ruby -e 'puts RUBY_VERSION' 2>/dev/null)
        print_info "Found Ruby version: $RUBY_VERSION"

        if version_ge "$RUBY_VERSION" "3.3.0"; then
            print_success "Ruby version is compatible (>= 3.3.0)"
            return 0
        else
            print_warning "Ruby version $RUBY_VERSION is too old (need >= 3.3.0)"
            return 1
        fi
    else
        print_warning "Ruby is not installed"
        return 1
    fi
}

# Install Node.js on macOS
install_nodejs_macos() {
    print_step "Installing Node.js on macOS..."
    
    if ! command_exists brew; then
        print_error "Homebrew is not installed. Please install Homebrew first:"
        echo "  /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
        return 1
    fi

    print_info "Installing Node.js via Homebrew..."
    if brew install node@22; then
        print_success "Node.js 22 installed successfully"
        # Add to PATH
        echo 'export PATH="/opt/homebrew/opt/node@22/bin:$PATH"' >> ~/.zshrc
        export PATH="/opt/homebrew/opt/node@22/bin:$PATH"
        return 0
    else
        print_error "Failed to install Node.js"
        return 1
    fi
}

# Install Node.js on Ubuntu/Debian
install_nodejs_ubuntu() {
    print_step "Installing Node.js on Ubuntu/Debian..."
    
    print_info "Setting up NodeSource repository for Node.js 22..."
    if curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -; then
        print_success "NodeSource repository added"
    else
        print_error "Failed to setup NodeSource repository"
        return 1
    fi

    print_info "Installing Node.js..."
    if sudo apt-get install -y nodejs; then
        print_success "Node.js installed successfully"
        return 0
    else
        print_error "Failed to install Node.js"
        return 1
    fi
}

# Install PostgreSQL on macOS
install_postgresql_macos() {
    print_step "Installing PostgreSQL on macOS..."
    
    if ! command_exists brew; then
        print_error "Homebrew is not installed. Please install Homebrew first:"
        echo "  /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
        return 1
    fi

    print_info "Installing PostgreSQL via Homebrew..."
    if brew install postgresql@16; then
        print_success "PostgreSQL installed successfully"
        
        # Start PostgreSQL service
        print_info "Starting PostgreSQL service..."
        brew services start postgresql@16
        
        # Wait for PostgreSQL to start
        sleep 2
        
        # Create postgres user if needed
        print_info "Creating PostgreSQL user 'postgres'..."
        if createuser -s postgres 2>/dev/null; then
            print_success "PostgreSQL user 'postgres' created"
        else
            print_info "PostgreSQL user 'postgres' may already exist"
        fi
        
        return 0
    else
        print_error "Failed to install PostgreSQL"
        return 1
    fi
}

# Install PostgreSQL on Ubuntu/Debian
install_postgresql_ubuntu() {
    print_step "Installing PostgreSQL on Ubuntu/Debian..."
    
    print_info "Installing PostgreSQL..."
    if sudo apt-get install -y postgresql postgresql-contrib libpq-dev; then
        print_success "PostgreSQL installed successfully"
        
        # Start PostgreSQL service
        print_info "Starting PostgreSQL service..."
        sudo systemctl start postgresql
        sudo systemctl enable postgresql
        
        # Create postgres superuser
        print_info "Setting up PostgreSQL user 'postgres'..."
        sudo -u postgres psql -c "ALTER USER postgres WITH PASSWORD 'postgres';" 2>/dev/null || true
        
        return 0
    else
        print_error "Failed to install PostgreSQL"
        return 1
    fi
}

# Suggest installation for Node.js
suggest_nodejs_installation() {
    print_step "Node.js Installation Required - Installing automatically..."
    echo ""
    
    if [ "$OS" = "macOS" ]; then
        install_nodejs_macos
        return $?
    elif [ "$OS" = "Linux" ]; then
        if [ "$DISTRO" = "ubuntu" ] || [ "$DISTRO" = "debian" ]; then
            install_nodejs_ubuntu
            return $?
        else
            print_error "Automatic installation not supported for this Linux distribution"
            print_info "Manual Installation:"
            echo "  Please visit: https://nodejs.org/"
            return 1
        fi
    else
        print_error "Automatic installation not supported for this OS"
        print_info "Please install Node.js 22 from: https://nodejs.org/"
        return 1
    fi
}

# Suggest installation for PostgreSQL
suggest_postgresql_installation() {
    print_step "PostgreSQL Installation Required - Installing automatically..."
    echo ""
    
    if [ "$OS" = "macOS" ]; then
        install_postgresql_macos
        return $?
    elif [ "$OS" = "Linux" ]; then
        if [ "$DISTRO" = "ubuntu" ] || [ "$DISTRO" = "debian" ]; then
            install_postgresql_ubuntu
            return $?
        else
            print_error "Automatic installation not supported for this Linux distribution"
            print_info "Manual Installation:"
            echo "  Please install PostgreSQL for your distribution"
            return 1
        fi
    else
        print_error "Automatic installation not supported for this OS"
        print_info "Please install PostgreSQL from: https://www.postgresql.org/"
        return 1
    fi
}

# Placeholder for future extensions
# This script only checks dependencies, not running bin/setup

# Main setup logic
main() {
    echo ""
    echo "╔═══════════════════════════════════════════════════════════╗"
    echo "║                                                           ║"
    echo "║   🚀 Rails 7.x Project Setup                             ║"
    echo "║                                                           ║"
    echo "║   Checking dependencies and setting up project...        ║"
    echo "║                                                           ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo ""

    detect_os

    NODEJS_OK=false
    POSTGRESQL_OK=false
    RUBY_OK=false

    # Check Ruby — auto-install via mise if version is too old or missing
    print_step "Checking Ruby..."
    if check_ruby; then
        RUBY_OK=true
    else
        print_warning "Ruby 3.0+ is required — attempting automatic installation..."
        local installer="$HOME/.clacky/scripts/install_rails_deps.sh"
        if [ ! -f "$installer" ]; then
            print_error "install_rails_deps.sh not found at: $installer"
            print_info "Please install Ruby 3.3+ manually:"
            echo "  curl https://mise.run | sh"
            echo "  mise use -g ruby@3"
            exit 1
        fi

        if bash "$installer" ruby; then
            # Re-check after installation (mise may have updated PATH)
            # Source mise activation in case it wasn't active yet
            if [ -x "$HOME/.local/bin/mise" ]; then
                eval "$("$HOME/.local/bin/mise" activate bash 2>/dev/null)" 2>/dev/null || true
                export PATH="$HOME/.local/bin:$PATH"
            fi

            if check_ruby; then
                RUBY_OK=true
                print_success "Ruby installed and verified"
            else
                print_error "Ruby installation succeeded but version check still fails"
                print_info "Try opening a new terminal and re-running the setup"
                exit 1
            fi
        else
            print_error "Automatic Ruby installation failed"
            print_info "Please install Ruby 3.3+ manually and run this script again"
            exit 1
        fi
    fi

    # Check Node.js
    print_step "Checking Node.js..."
    if check_nodejs; then
        NODEJS_OK=true
    else
        if ! suggest_nodejs_installation; then
            print_warning "Node.js 22+ is required but not installed"
            print_info "Please install Node.js 22 and run this script again"
            exit 1
        else
            # Verify installation
            if check_nodejs; then
                NODEJS_OK=true
            else
                print_error "Node.js installation verification failed"
                exit 1
            fi
        fi
    fi

    # Check PostgreSQL
    print_step "Checking PostgreSQL..."
    if check_postgresql; then
        POSTGRESQL_OK=true
    else
        if ! suggest_postgresql_installation; then
            print_warning "PostgreSQL is required but not installed"
            print_info "Please install PostgreSQL and run this script again"
            exit 1
        else
            # Verify installation
            if check_postgresql; then
                POSTGRESQL_OK=true
            else
                print_error "PostgreSQL installation verification failed"
                exit 1
            fi
        fi
    fi

    # All dependencies are ready
    if [ "$RUBY_OK" = true ] && [ "$NODEJS_OK" = true ] && [ "$POSTGRESQL_OK" = true ]; then
        echo ""
        echo "╔═══════════════════════════════════════════════════════════╗"
        echo "║                                                           ║"
        echo "║   ✨ Environment Check Complete!                         ║"
        echo "║                                                           ║"
        echo "╚═══════════════════════════════════════════════════════════╝"
        echo ""
        print_success "All required dependencies are installed:"
        echo "  ✓ Ruby $RUBY_VERSION"
        echo "  ✓ Node.js $NODE_VERSION"
        echo "  ✓ PostgreSQL $PG_VERSION"
        echo ""
        print_info "You can now run: ./bin/setup"
        echo ""
        exit 0
    else
        print_error "Some dependencies are missing. Please install them and run this script again."
        exit 1
    fi
}

# Run main setup
main
