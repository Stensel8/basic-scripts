#!/usr/bin/env bash
#########################################################################
# OpenSSL 3.5.0 + OpenSSH 10.0p2 Custom Build Installer
# Optimized for Ubuntu/Debian and Fedora/RHEL systems
# Replaces system OpenSSL/OpenSSH with custom compiled versions
#########################################################################

set -euo pipefail

# Version configuration
readonly OPENSSL_VERSION="${OPENSSL_VERSION:-3.5.0}"
readonly OPENSSH_VERSION="${OPENSSH_VERSION:-10.0p2}"
BUILD_DIR=$(mktemp -d)
trap 'rm -rf "$BUILD_DIR"' EXIT
readonly OPENSSL_PREFIX="/usr/local/openssl-${OPENSSL_VERSION}"
readonly OPENSSH_PREFIX="/usr/local/openssh-${OPENSSH_VERSION}"
readonly BACKUP_DIR="/root/ssh-ssl-backup-$(date +%Y%m%d-%H%M%S)"

# Color codes for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'


# Print colored messages
info() { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[✓]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1" >&2; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }

# Exit with error message
die() {
    error "$1"
    exit "${2:-1}"
}

# Check if running as root
check_root() {
    [[ $EUID -eq 0 ]] || die "This script must be run as root. Use: sudo $0"
}

# Detect package manager and install packages
pkg_install() {
    local packages=("$@")
    
    if command -v apt-get &>/dev/null; then
        # Debian/Ubuntu system
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq || die "Failed to update package cache"
        apt-get install -y "${packages[@]}" || die "Failed to install packages"
    elif command -v dnf &>/dev/null; then
        # Fedora/RHEL 8+ system
        dnf install -y "${packages[@]}" || die "Failed to install packages"
    elif command -v yum &>/dev/null; then
        # RHEL/CentOS 7 system
        yum install -y "${packages[@]}" || die "Failed to install packages"
    else
        die "No supported package manager found (apt-get, dnf, or yum)"
    fi
}

# Install build dependencies based on distribution
install_dependencies() {
    info "Installing build dependencies..."
    
    if command -v apt-get &>/dev/null; then
        # Debian/Ubuntu packages
        pkg_install build-essential wget tar perl zlib1g-dev libpam0g-dev \
                   libselinux1-dev libedit-dev
    else
        # Fedora/RHEL packages
        pkg_install gcc make wget tar perl zlib-devel pam-devel libselinux-devel libedit-devel
    fi
    
    success "Dependencies installed"
}

# Create backups of existing SSH/SSL files
backup_existing() {
    info "Creating backups in ${BACKUP_DIR}..."
    mkdir -p "$BACKUP_DIR"
    
    # Backup important files and directories
    for item in /etc/ssh /etc/ssl /usr/bin/ssh /usr/sbin/sshd /usr/bin/openssl; do
        [[ -e "$item" ]] && cp -a "$item" "$BACKUP_DIR/" 2>/dev/null || true
    done
    
    # Save current versions
    {
        echo "Backup created: $(date)"
        openssl version 2>&1 || echo "OpenSSL: not found"
        ssh -V 2>&1 || echo "OpenSSH: not found"
    } > "$BACKUP_DIR/versions.txt"
    
    success "Backups created"
}

# Download and extract source code
download_sources() {
    info "Downloading OpenSSL ${OPENSSL_VERSION} and OpenSSH ${OPENSSH_VERSION}..."
    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR"
    
    # Download with error checking
    wget -q "https://www.openssl.org/source/openssl-${OPENSSL_VERSION}.tar.gz" \
        || die "Failed to download OpenSSL"
    wget -q "https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/openssh-${OPENSSH_VERSION}.tar.gz" \
        || die "Failed to download OpenSSH"
    
    # Extract archives
    tar xzf "openssl-${OPENSSL_VERSION}.tar.gz" || die "Failed to extract OpenSSL"
    tar xzf "openssh-${OPENSSH_VERSION}.tar.gz" || die "Failed to extract OpenSSH"
    
    success "Sources downloaded and extracted"
}

# Build and install OpenSSL
build_openssl() {
    info "Building OpenSSL ${OPENSSL_VERSION}..."
    cd "$BUILD_DIR/openssl-${OPENSSL_VERSION}"
    
    # Configure with secure options
    ./config \
        --prefix="$OPENSSL_PREFIX" \
        --openssldir="$OPENSSL_PREFIX" \
        --libdir="$OPENSSL_PREFIX/lib" \
        shared enable-ec_nistp_64_gcc_128 \
        -Wl,-rpath,"$OPENSSL_PREFIX/lib" \
        || die "OpenSSL configure failed"
    
    # Build and install
    make -j"$(nproc)" || die "OpenSSL build failed"
    make install || die "OpenSSL install failed"
    
    success "OpenSSL installed to $OPENSSL_PREFIX"
}

# Build and install OpenSSH
build_openssh() {
    info "Building OpenSSH ${OPENSSH_VERSION}..."
    
    # Find the extracted OpenSSH directory (handle different naming patterns)
    local ssh_dir=$(find "$BUILD_DIR" -maxdepth 1 -type d -name "openssh-*" | head -1)
    [[ -z "$ssh_dir" ]] && die "OpenSSH source directory not found in $BUILD_DIR"
    
    cd "$ssh_dir" || die "Cannot enter OpenSSH directory: $ssh_dir"
    
    # Set environment to use our custom OpenSSL
    export PKG_CONFIG_PATH="$OPENSSL_PREFIX/lib/pkgconfig:$OPENSSL_PREFIX/lib64/pkgconfig"
    export LDFLAGS="-L$OPENSSL_PREFIX/lib -L$OPENSSL_PREFIX/lib64 -Wl,-rpath,$OPENSSL_PREFIX/lib -Wl,-rpath,$OPENSSL_PREFIX/lib64"
    export CPPFLAGS="-I$OPENSSL_PREFIX/include"
    
    # Configure with PAM support and custom OpenSSL
    ./configure \
        --prefix="$OPENSSH_PREFIX" \
        --sysconfdir=/etc/ssh \
        --with-ssl-dir="$OPENSSL_PREFIX" \
        --with-pam \
        --with-privsep-path=/var/lib/sshd \
        --without-openssl-header-check \
        || die "OpenSSH configure failed"
    
    # Build and install
    make -j"$(nproc)" || die "OpenSSH build failed"
    make install || die "OpenSSH install failed"
    
    # Create privilege separation directory and user
    mkdir -p /var/lib/sshd
    chmod 700 /var/lib/sshd
    
    # Create sshd user if missing (required for privilege separation)
    if ! id -u sshd &>/dev/null; then
        info "Creating sshd user for privilege separation..."
        if command -v useradd &>/dev/null; then
            useradd -r -U -d /var/lib/sshd -s /sbin/nologin -c "Privilege-separated SSH" sshd
        else
            adduser --system --group --home /var/lib/sshd --shell /sbin/nologin --comment "Privilege-separated SSH" sshd
        fi
    fi
    
    success "OpenSSH installed to $OPENSSH_PREFIX"
}

# Create symlinks for system binaries
create_symlinks() {
    info "Setting up alternatives for OpenSSL/OpenSSH..."
    # OpenSSL
    update-alternatives --install /usr/bin/openssl openssl "$OPENSSL_PREFIX/bin/openssl" 200
    update-alternatives --set openssl "$OPENSSL_PREFIX/bin/openssl"

    # OpenSSH-tools
    for bin in ssh scp sftp ssh-add ssh-agent ssh-keygen ssh-keyscan; do
        update-alternatives --install /usr/bin/$bin $bin "$OPENSSH_PREFIX/bin/$bin" 200
        update-alternatives --set $bin "$OPENSSH_PREFIX/bin/$bin"
    done

    ldconfig
    success "Alternatives configured"
}

# Configure secure SSH settings
configure_ssh() {
    info "Configuring secure SSH settings..."
    
    # Backup existing config
    [[ -f /etc/ssh/sshd_config ]] && cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.backup"
    
    # Find sftp-server path
    local sftp_path=$(find /usr -name sftp-server -type f 2>/dev/null | head -1)
    [[ -z "$sftp_path" ]] && sftp_path="/usr/libexec/openssh/sftp-server"
    
    # Create secure configuration (Windows 11 compatible, testssl.sh A+ rated)
    cat > /etc/ssh/sshd_config << EOF
# Secure OpenSSH Configuration
# Compatible with Windows 11 and testssl.sh A+ rating

# Network settings
Port 22
AddressFamily any
ListenAddress 0.0.0.0
ListenAddress ::

# Host keys (only strong algorithms)
HostKey /etc/ssh/ssh_host_ed25519_key
HostKey /etc/ssh/ssh_host_rsa_key

# Authentication
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication yes
ChallengeResponseAuthentication no
UsePAM yes

# Connection limits
MaxAuthTries 3
MaxSessions 2
ClientAliveInterval 300
ClientAliveCountMax 2

# Strong cryptography settings
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com
MACs hmac-sha2-256-etm@openssh.com,hmac-sha2-512-etm@openssh.com,umac-128-etm@openssh.com
HostKeyAlgorithms ssh-ed25519,rsa-sha2-512,rsa-sha2-256

# Security hardening
StrictModes yes
PermitEmptyPasswords no
AllowAgentForwarding no
AllowTcpForwarding no
PermitTunnel no
X11Forwarding no
Compression no

# SFTP subsystem
Subsystem sftp $sftp_path
EOF

    # Generate new host keys if missing
    [[ ! -f /etc/ssh/ssh_host_ed25519_key ]] && ssh-keygen -t ed25519 -f /etc/ssh/ssh_host_ed25519_key -N ''
    [[ ! -f /etc/ssh/ssh_host_rsa_key ]] && ssh-keygen -t rsa -b 3072 -f /etc/ssh/ssh_host_rsa_key -N ''
    
    # Remove weak keys
    rm -f /etc/ssh/ssh_host_dsa_key* /etc/ssh/ssh_host_ecdsa_key* 2>/dev/null || true
    
    # Fix permissions
    chmod 600 /etc/ssh/ssh_host_*_key
    chmod 644 /etc/ssh/ssh_host_*_key.pub /etc/ssh/sshd_config
    
    success "SSH configured securely"
}

# Exclude system packages from updates to prevent overwriting custom installation
exclude_packages() {
    info "Excluding system OpenSSL/OpenSSH packages from updates..."
    
    if command -v apt-mark &>/dev/null; then
        # Debian/Ubuntu: Hold packages
        apt-mark hold openssl openssh-server openssh-client 2>/dev/null || true
        warn "System packages held. To revert: apt-mark unhold openssl openssh-server openssh-client"
        
    elif command -v dnf &>/dev/null; then
        # Fedora/RHEL 8+: Use versionlock plugin
        dnf install -y python3-dnf-plugin-versionlock 2>/dev/null || true
        dnf versionlock add openssl openssh openssh-server openssh-clients 2>/dev/null || true
        warn "Packages locked. To revert: dnf versionlock delete openssl openssh openssh-server openssh-clients"
        
    elif command -v yum &>/dev/null; then
        # RHEL/CentOS 7: Add to yum.conf exclude
        if grep -q "^exclude=" /etc/yum.conf; then
            sed -i 's/^exclude=.*/& openssl openssh*/' /etc/yum.conf
        else
            echo "exclude=openssl openssh*" >> /etc/yum.conf
        fi
        warn "Packages excluded in /etc/yum.conf. To revert: Remove 'openssl openssh*' from exclude= line"
    fi
}

# Test the installation
test_installation() {
    info "Testing installation..."
    local failed=0

    # OpenSSL
    if ! "$OPENSSL_PREFIX/bin/openssl" version >/dev/null 2>&1; then
        error "OpenSSL test failed:"
        "$OPENSSL_PREFIX/bin/openssl" version || true
        ldd "$OPENSSL_PREFIX/bin/openssl" | grep "not found" || true
        ((failed++))
    else
        success "OpenSSL OK: $("$OPENSSL_PREFIX/bin/openssl" version | awk '{print $2}')"
    fi

    # SSH-client
    if ! "$OPENSSH_PREFIX/bin/ssh" -V >/dev/null 2>&1; then
        error "SSH client test failed"
        ((failed++))
    else
        success "SSH client OK: $("$OPENSSH_PREFIX/bin/ssh" -V 2>&1)"
    fi

    # SSH-daemon config
    if ! "$OPENSSH_PREFIX/sbin/sshd" -t -f /etc/ssh/sshd_config >/dev/null 2>&1; then
        error "SSH daemon config test failed"
        "$OPENSSH_PREFIX/sbin/sshd" -t -f /etc/ssh/sshd_config || true
        ((failed++))
    else
        success "SSH daemon config OK"
    fi

    return $failed
}

# Main installation function
install() {
    info "Starting installation of OpenSSL ${OPENSSL_VERSION} + OpenSSH ${OPENSSH_VERSION}"
    
    # Safety check for SSH sessions
    if [[ -n "${SSH_CONNECTION:-}" ]] && [[ "${FORCE_SSH_INSTALL:-}" != "1" ]]; then
        error "Running in SSH session! This will disconnect you."
        warn "If you have console access, run: FORCE_SSH_INSTALL=1 $0 install"
        exit 1
    fi
    
    # Confirm installation
    if [[ "${CONFIRM:-}" != "yes" ]]; then
        if [[ -t 0 ]]; then
            # Interactive mode
            read -rp "Proceed with installation? This will reboot the system. [y/N] " answer
            [[ "${answer,,}" != "y" ]] && die "Installation cancelled" 0
        else
            # Non-interactive mode (piped)
            die "Non-interactive mode detected. Use: curl ... | CONFIRM=yes sudo bash -s install" 0
        fi
    fi
    
    # Run installation steps
    backup_existing
    install_dependencies
    download_sources
    build_openssl
    build_openssh
    create_symlinks
    configure_ssh
    exclude_packages
    
    # Test installation
    if test_installation; then
        success "All tests passed!"
    else
        warn "Some tests failed - check configuration"
    fi
    
    # Show summary
    echo
    success "Installation complete!"
    info "OpenSSL: $OPENSSL_PREFIX"
    info "OpenSSH: $OPENSSH_PREFIX"
    info "Backups: $BACKUP_DIR"
    echo
    warn "System will restart in a few seconds to apply changes."
    
    # Schedule reboot
    shutdown -r +1 "OpenSSL/OpenSSH installation complete - system restarting" &>/dev/null || warn "Automatic restart failed - please reboot manually"
}

# Remove custom installation
remove() {
    info "Removing custom OpenSSL/OpenSSH installation..."
    
    # Remove installation directories
    rm -rf "$OPENSSL_PREFIX" "$OPENSSH_PREFIX"
    
    # Remove symlinks
    rm -f /usr/bin/{openssl,ssh,scp,sftp,ssh-*} /usr/sbin/sshd
    rm -f /etc/ld.so.conf.d/openssl-*.conf
    ldconfig
    
    # Restore system packages
    if command -v apt-get &>/dev/null; then
        apt-mark unhold openssl openssh-server openssh-client 2>/dev/null || true
        apt-get install --reinstall -y openssl openssh-server openssh-client
    elif command -v dnf &>/dev/null; then
        dnf versionlock delete openssl openssh openssh-server openssh-clients 2>/dev/null || true
        dnf reinstall -y openssl openssh openssh-server openssh-clients
    elif command -v yum &>/dev/null; then
        sed -i 's/openssl openssh\*//g' /etc/yum.conf
        yum reinstall -y openssl openssh openssh-server openssh-clients
    fi
    
    success "Custom installation removed"
    warn "Please reboot to ensure all changes take effect"
}

# Verify installation status
verify() {
    info "Verifying installation..."
    
    # Check OpenSSL
    if [[ -L /usr/bin/openssl ]] && [[ -d $OPENSSL_PREFIX ]]; then
        local ssl_ver=$(/usr/bin/openssl version 2>/dev/null | awk '{print $2}')
        success "OpenSSL: $ssl_ver (Custom)"
    else
        warn "OpenSSL: System default"
    fi
    
    # Check OpenSSH
    if [[ -L /usr/bin/ssh ]] && [[ -d $OPENSSH_PREFIX ]]; then
        local ssh_ver=$(ssh -V 2>&1 | grep -oE '[0-9]+\.[0-9]+p[0-9]+' | head -1)
        success "OpenSSH: $ssh_ver (Custom)"
    else
        warn "OpenSSH: System default"
    fi
}

# Main script logic
main() {
    check_root
    
    case "${1:-help}" in
        install)
            install
            ;;
        remove)
            remove
            ;;
        verify)
            verify
            ;;
        *)
            echo "Usage: $0 {install|remove|verify}"
            echo
            echo "  install - Build and install custom OpenSSL + OpenSSH"
            echo "  remove  - Remove custom installation and restore system packages"
            echo "  verify  - Check current installation status"
            echo
            echo "Environment variables:"
            echo "  CONFIRM=yes         - Skip installation confirmation"
            echo "  FORCE_SSH_INSTALL=1 - Allow installation over SSH (risky!)"
            echo "  OPENSSL_VERSION     - OpenSSL version (default: $OPENSSL_VERSION)"
            echo "  OPENSSH_VERSION     - OpenSSH version (default: $OPENSSH_VERSION)"
            ;;
    esac
}

main "$@"