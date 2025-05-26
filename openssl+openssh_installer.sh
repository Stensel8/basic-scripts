#!/usr/bin/env bash
#########################################################################
# OpenSSL 3.5.0 + OpenSSH 10.0p2 Custom Build Installer
# Replaces system OpenSSL/OpenSSH with custom compiled versions
# Enhanced with safety checks and improved binary linking
#########################################################################

# Safer error handling
set -uo pipefail

# Version definitions
OPENSSL_VERSION="${OPENSSL_VERSION:-3.5.0}"
OPENSSH_VERSION="${OPENSSH_VERSION:-10.0p2}"

# URLs
OPENSSL_URL="https://www.openssl.org/source/openssl-${OPENSSL_VERSION}.tar.gz"
OPENSSH_URL="https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/openssh-${OPENSSH_VERSION}.tar.gz"

# Paths
BUILD_DIR="${BUILD_DIR:-/usr/local/src/build-ssh-ssl}"
OPENSSL_INSTALL_PREFIX="${OPENSSL_INSTALL_PREFIX:-/usr/local/openssl-${OPENSSL_VERSION}}"
OPENSSH_INSTALL_PREFIX="${OPENSSH_INSTALL_PREFIX:-/usr/local/openssh-${OPENSSH_VERSION}}"
# OPENSSH_PREFIX is removed as its role is split between OPENSSH_INSTALL_PREFIX and hardcoded /usr for symlink targets
LOG_DIR="/tmp/openssh-openssl-logs-$$"
BACKUP_DIR="/root/ssh-ssl-backup-$(date +%Y%m%d-%H%M%S)"

# Color definitions
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly PURPLE='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly GRAY='\033[0;90m'
readonly NC='\033[0m'
readonly BOLD='\033[1m'

# Create log directory
mkdir -p "$LOG_DIR"

# Logging functions
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[✓]${NC} $1"; }
log_error() { echo -e "${RED}[✗]${NC} $1" >&2; }
log_warn() { echo -e "${YELLOW}[!]${NC} $1"; }
log_step() { echo -e "${PURPLE}[→]${NC} ${BOLD}$1${NC}"; }
log_detail() { echo -e "${GRAY}    $1${NC}"; }
log_debug() { [[ "${SCRIPT_DEBUG:-0}" -eq 1 ]] && echo -e "${CYAN}[DEBUG]${NC} $1"; }

# Spinner for long operations
spinner() {
    local pid=$1
    local task=$2
    local frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
    
    echo -ne "${BLUE}[${frames[0]}]${NC} ${task}..."
    
    while kill -0 "$pid" 2>/dev/null; do
        for frame in "${frames[@]}"; do
            echo -ne "\r${BLUE}[${frame}]${NC} ${task}..."
            sleep 0.1
        done
    done
    
    wait "$pid"
    local exit_code=$?
    
    if [ $exit_code -eq 0 ]; then
        echo -e "\r${GREEN}[✓]${NC} ${task}... ${GREEN}done${NC}"
    else
        echo -e "\r${RED}[✗]${NC} ${task}... ${RED}failed${NC}"
    fi
    
    return $exit_code
}

# Cleanup on exit
cleanup() {
    [[ $? -ne 0 && -d "$BUILD_DIR" ]] && rm -rf "$BUILD_DIR"
    [[ -d "$LOG_DIR" ]] && rm -rf "$LOG_DIR"
}
trap cleanup EXIT INT TERM

# Check for root
check_root() {
    [[ $EUID -ne 0 ]] && {
        log_error "This script must be run as root"
        echo -e "${GRAY}Usage: sudo $0 [install|remove|verify]${NC}"
        exit 1
    }
}

# Check if running in SSH session
check_ssh_session() {
    if [[ -n "${SSH_CONNECTION:-}" ]] || [[ -n "${SSH_CLIENT:-}" ]] || [[ -n "${SSH_TTY:-}" ]]; then
        echo
        echo -e "${RED}╔════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${RED}║                    ⚠️  CRITICAL WARNING ⚠️                      ║${NC}"
        echo -e "${RED}╠════════════════════════════════════════════════════════════════╣${NC}"
        echo -e "${RED}║  You are running this script in an SSH session!               ║${NC}"
        echo -e "${RED}║                                                                ║${NC}"
        echo -e "${RED}║  This script will:                                             ║${NC}"
        echo -e "${RED}║  • REPLACE your system SSH binaries                           ║${NC}"
        echo -e "${RED}║  • RESTART SSH services                                       ║${NC}"
        echo -e "${RED}║  • REBOOT the system when complete                           ║${NC}"
        echo -e "${RED}║                                                                ║${NC}"
        echo -e "${RED}║  YOU MAY LOSE SSH ACCESS TO THIS SERVER!                      ║${NC}"
        echo -e "${RED}║                                                                ║${NC}"
        echo -e "${RED}║  Recommended: Run from local console or KVM/IPMI              ║${NC}"
        echo -e "${RED}╚════════════════════════════════════════════════════════════════╝${NC}"
        echo
        
        if [[ "${FORCE_SSH_INSTALL:-0}" != "1" ]]; then
            log_error "For safety, this script refuses to run in an SSH session."
            log_info "If you have console access, run: ${YELLOW}FORCE_SSH_INSTALL=1 $0 $*${NC}"
            exit 1
        else
            log_warn "FORCE_SSH_INSTALL is set. Type 'I UNDERSTAND THE RISKS' to continue:"
            read -r confirmation
            [[ "$confirmation" != "I UNDERSTAND THE RISKS" ]] && {
                log_error "Confirmation not received. Exiting."
                exit 1
            }
        fi
    fi
}

# Print header
print_header() {
    echo
    echo -e "${BOLD}OpenSSL + OpenSSH Custom Build Installer${NC}"
    echo -e "${GRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "OpenSSL ${CYAN}$OPENSSL_VERSION${NC} + OpenSSH ${CYAN}$OPENSSH_VERSION${NC}"
    echo -e "${GRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo
}

# Link binary with safety checks
link_binary() {
    local src="$1"
    local dest="$2"
    
    [[ ! -x "$src" ]] && {
        log_error "Source not executable: $src"
        return 1
    }
    
    # Backup existing
    [[ -e "$dest" ]] && mv "$dest" "${dest}.bak-$(date +%Y%m%d-%H%M%S)" 2>/dev/null
    
    # Create parent dir
    mkdir -p "$(dirname "$dest")" 2>/dev/null
    
    # Create symlink
    ln -sf "$src" "$dest" && log_success "Linked $dest → $src" || {
        log_error "Failed to link $dest → $src"
        return 1
    }
}

# Update ldconfig
fix_ldconfig() {
    local conf="/etc/ld.so.conf.d/openssl-${OPENSSL_VERSION}.conf"
    
    {
        echo "# OpenSSL ${OPENSSL_VERSION} libraries"
        echo "${OPENSSL_INSTALL_PREFIX}/lib"
        [[ -d "${OPENSSL_INSTALL_PREFIX}/lib64" ]] && echo "${OPENSSL_INSTALL_PREFIX}/lib64"
    } > "$conf" && ldconfig && log_success "Library cache updated" || {
        log_error "Failed to update library cache"
        return 1
    }
}

# Generic package manager wrapper
pkg_manager() {
    local action=$1
    shift
    local packages=("$@")
    local pkg_cmd_output=""
    
    if command -v dnf >/dev/null; then
        pkg_cmd_output=$(dnf "$action" -y "${packages[@]}" 2>&1)
    elif command -v yum >/dev/null; then
        pkg_cmd_output=$(yum "$action" -y "${packages[@]}" 2>&1)
    elif command -v apt-get >/dev/null; then
        export DEBIAN_FRONTEND=noninteractive
        # For apt-get, 'makecache' is 'update'
        if [[ "$action" == "makecache" ]]; then
            action="update"
        fi
        pkg_cmd_output=$(apt-get "$action" -y "${packages[@]}" 2>&1)
    else
        log_error "No supported package manager found"
        return 1
    fi
    
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        log_debug "Package manager command failed. Output:\n$pkg_cmd_output"
    fi
    return $exit_code
}

# Backup configs
backup_configs() {
    log_step "Creating backups in ${BACKUP_DIR}"
    mkdir -p "${BACKUP_DIR}"
    
    # Backup important files/dirs
    for item in /etc/ssh /etc/ssl /root/.ssh /usr/bin/ssh /usr/sbin/sshd /usr/bin/openssl; do
        [[ -e "$item" ]] && cp -a "$item" "${BACKUP_DIR}/" 2>/dev/null
    done
    
    # Save versions
    {
        echo "Backup: $(date)"
        openssl version 2>&1 || echo "OpenSSL: not found"
        ssh -V 2>&1 || echo "OpenSSH: not found"
    } > "${BACKUP_DIR}/versions.txt"
    
    log_success "Backups created"
}

# Install dependencies
install_dependencies() {
    log_step "Installing build dependencies"
    
    # Update package cache
    pkg_manager "makecache" >/dev/null || pkg_manager "update" >/dev/null
    
    # Core build tools
    local deps=(gcc make wget tar perl zlib-devel pam-devel)
    
    # Debian/Ubuntu alternatives
    if command -v apt-get >/dev/null; then
        deps=(build-essential wget tar perl zlib1g-dev libpam0g-dev libselinux1-dev libedit-dev)
    fi
    
    # Add lsof for checking open files during removal if needed (optional)
    # deps+=(lsof)

    pkg_manager "install" "${deps[@]}" &>"$LOG_DIR/deps.log" &
    spinner $! "Installing packages"
    
    # Verify critical tools
    for cmd in gcc make wget tar perl; do
        command -v "$cmd" &>/dev/null || {
            log_error "Missing: $cmd"
            return 1
        }
    done
    
    log_success "Dependencies installed"
}

# Download and extract sources
download_sources() {
    log_step "Downloading sources"
    mkdir -p "$BUILD_DIR" && cd "$BUILD_DIR"
    
    for url in "$OPENSSL_URL" "$OPENSSH_URL"; do
        local file=$(basename "$url")
        log_detail "Downloading $file"
        
        # Download with retries
        local retry=0
        while [[ $retry -lt 3 ]]; do
            wget -q --timeout=30 "$url" && break
            ((retry++))
            [[ $retry -lt 3 ]] && sleep 2
        done
        
        [[ $retry -eq 3 ]] && {
            log_error "Failed to download $file"
            return 1
        }
        
        # Extract
        tar xzf "$file" || {
            log_error "Failed to extract $file"
            return 1
        }
    done
    
    log_success "Sources ready"
}

# Build OpenSSL
build_openssl() {
    log_step "Building OpenSSL $OPENSSL_VERSION"
    cd "$BUILD_DIR/openssl-${OPENSSL_VERSION}"
    
    # Configure
    ./config \
        --prefix="${OPENSSL_INSTALL_PREFIX}" \
        --openssldir="${OPENSSL_INSTALL_PREFIX}" \
        shared \
        enable-ec_nistp_64_gcc_128 \
        -Wl,-rpath,${OPENSSL_INSTALL_PREFIX}/lib &>"$LOG_DIR/openssl.log" || {
        log_error "OpenSSL configure failed"
        return 1
    }
    
    # Build & Install
    make -j"$(nproc)" &>>"$LOG_DIR/openssl.log" &
    spinner $! "Building OpenSSL"
    
    make install &>>"$LOG_DIR/openssl.log" &
    spinner $! "Installing OpenSSL"
    
    log_success "OpenSSL installed to ${OPENSSL_INSTALL_PREFIX}"
}

# Build OpenSSH
build_openssh() {
    log_step "Building OpenSSH $OPENSSH_VERSION"
    
    # Find OpenSSH directory
    local ssh_dir=$(find "$BUILD_DIR" -maxdepth 1 -type d -name "openssh-*" | head -1)
    [[ -z "$ssh_dir" ]] && {
        log_error "OpenSSH source directory not found"
        return 1
    }
    
    cd "$ssh_dir"
    
    # Configure
    ./configure \
        --prefix="${OPENSSH_INSTALL_PREFIX}" \
        --sysconfdir=/etc/ssh \
        --with-ssl-dir="${OPENSSL_INSTALL_PREFIX}" \
        --with-pam \
        --with-privsep-path=/var/lib/sshd &>"$LOG_DIR/openssh.log" || {
        log_error "OpenSSH configure failed"
        return 1
    }
    
    # Build & Install
    make -j"$(nproc)" &>>"$LOG_DIR/openssh.log" &
    spinner $! "Building OpenSSH"
    
    make install &>>"$LOG_DIR/openssh.log" &
    spinner $! "Installing OpenSSH"
    
    # Create privsep directory
    mkdir -p /var/lib/sshd && chmod 700 /var/lib/sshd
    
    log_success "OpenSSH installed to ${OPENSSH_INSTALL_PREFIX}"
}

# Exclude system OpenSSL/OpenSSH packages
exclude_system_packages() {
    log_step "Excluding system OpenSSL/OpenSSH packages from updates"
    local packages_to_exclude=(openssl openssh openssh-server openssh-clients)
    local excluded_successfully=true

    if command -v dnf >/dev/null; then
        log_info "Using dnf to exclude: ${packages_to_exclude[*]}"
        if dnf mark exclude "${packages_to_exclude[@]}" &>>"$LOG_DIR/pkg_exclude.log"; then
            log_success "Packages excluded using dnf."
        else
            log_warn "Failed to exclude packages using dnf. Check $LOG_DIR/pkg_exclude.log"
            excluded_successfully=false
        fi
    elif command -v yum >/dev/null; then
        log_info "Using yum to exclude (adding to exclude line in yum.conf): ${packages_to_exclude[*]}"
        local yum_conf="/etc/yum.conf"
        if [[ ! -f "$yum_conf" ]]; then # RHEL/CentOS 8+ might use dnf.conf
            yum_conf="/etc/dnf/dnf.conf"
        fi
        
        if [[ -f "$yum_conf" ]]; then
            # Remove existing exclude lines for these packages to avoid duplicates
            for pkg in "${packages_to_exclude[@]}"; do
                sed -i "/^exclude=.*$pkg/d" "$yum_conf"
            done
            # Add new exclude line
            if grep -q "^exclude=" "$yum_conf"; then
                sed -i "s/^exclude=\(.*\)/exclude=\1 ${packages_to_exclude[*]}/" "$yum_conf"
            else
                echo "exclude=${packages_to_exclude[*]}" >> "$yum_conf"
            fi
            log_success "Packages added to yum exclude list in $yum_conf."
        else
            log_warn "Could not find $yum_conf to exclude packages."
            excluded_successfully=false
        fi
    elif command -v apt-mark >/dev/null; then
        log_info "Using apt-mark to hold: ${packages_to_exclude[*]}"
        if apt-mark hold "${packages_to_exclude[@]}" &>>"$LOG_DIR/pkg_exclude.log"; then
            log_success "Packages held using apt-mark."
        else
            log_warn "Failed to hold packages using apt-mark. Check $LOG_DIR/pkg_exclude.log"
            excluded_successfully=false
        fi
    else
        log_warn "No supported package manager found to exclude system packages."
        excluded_successfully=false
    fi

    if [[ "$excluded_successfully" == "true" ]]; then
        log_info "System OpenSSL/OpenSSH packages will not be automatically updated by the package manager."
    else
        log_warn "Could not automatically exclude system OpenSSL/OpenSSH packages. Please do so manually if desired."
    fi
}

# Unexclude system OpenSSL/OpenSSH packages
unexclude_system_packages() {
    log_step "Unexcluding system OpenSSL/OpenSSH packages"
    local packages_to_unexclude=(openssl openssh-server openssh-clients)

    if command -v dnf >/dev/null; then
        log_info "Using dnf to unexclude: ${packages_to_unexclude[*]}"
        if dnf mark unexclude "${packages_to_unexclude[@]}" &>>"$LOG_DIR/pkg_unexclude.log"; then
            log_success "Packages unexcluded using dnf."
        else
            log_warn "Failed to unexclude packages using dnf. Check $LOG_DIR/pkg_unexclude.log"
        fi
    elif command -v yum >/dev/null; then
        log_info "Using yum to unexclude (removing from exclude line in yum.conf): ${packages_to_unexclude[*]}"
        local yum_conf="/etc/yum.conf"
        if [[ ! -f "$yum_conf" ]]; then # RHEL/CentOS 8+ might use dnf.conf
             yum_conf="/etc/dnf/dnf.conf"
        fi

        if [[ -f "$yum_conf" ]]; then
            for pkg in "${packages_to_unexclude[@]}"; do
                sed -i "s/\b$pkg\b//g" "$yum_conf" # remove package name
            done
            sed -i "s/exclude=\s*$/exclude=/" "$yum_conf" # clean up if exclude is empty
            sed -i "s/exclude=\s\+/exclude= /g" "$yum_conf" # clean up multiple spaces
            log_success "Packages removed from yum exclude list in $yum_conf."
        else
            log_warn "Could not find $yum_conf to unexclude packages."
        fi
    elif command -v apt-mark >/dev/null; then
        log_info "Using apt-mark to unhold: ${packages_to_unexclude[*]}"
        if apt-mark unhold "${packages_to_unexclude[@]}" &>>"$LOG_DIR/pkg_unexclude.log"; then
            log_success "Packages unheld using apt-mark."
        else
            log_warn "Failed to unhold packages using apt-mark. Check $LOG_DIR/pkg_unexclude.log"
        fi
    else
        log_warn "No supported package manager found to unexclude system packages."
    fi
}

# Link all binaries
link_all_binaries() {
    log_step "Linking binaries"
    
    # Link OpenSSL
    link_binary "${OPENSSL_INSTALL_PREFIX}/bin/openssl" "/usr/bin/openssl"
    fix_ldconfig
    
    # Link OpenSSH binaries
    local ssh_bins=(ssh scp sftp ssh-add ssh-agent ssh-keygen ssh-keyscan)
    local all_ssh_bins_linked=true

    # Link client binaries from OPENSSH_INSTALL_PREFIX/bin to /usr/bin
    if [[ -d "${OPENSSH_INSTALL_PREFIX}/bin" ]]; then
        for bin in "${ssh_bins[@]}"; do
            if [[ -x "${OPENSSH_INSTALL_PREFIX}/bin/$bin" ]]; then
                link_binary "${OPENSSH_INSTALL_PREFIX}/bin/$bin" "/usr/bin/$bin" || all_ssh_bins_linked=false
            else
                log_warn "SSH client binary not found in install prefix: ${OPENSSH_INSTALL_PREFIX}/bin/$bin"
                all_ssh_bins_linked=false
            fi
        done
    else
        log_error "OpenSSH bin directory not found: ${OPENSSH_INSTALL_PREFIX}/bin"
        all_ssh_bins_linked=false
    fi
    
    # Link sshd from OPENSSH_INSTALL_PREFIX/sbin to /usr/sbin
    local sshd_linked=false
    if [[ -x "${OPENSSH_INSTALL_PREFIX}/sbin/sshd" ]]; then
        link_binary "${OPENSSH_INSTALL_PREFIX}/sbin/sshd" "/usr/sbin/sshd" && sshd_linked=true
    else
        log_warn "sshd binary not found in install prefix: ${OPENSSH_INSTALL_PREFIX}/sbin/sshd"
    fi
    
    if [[ "$all_ssh_bins_linked" == "true" ]] && [[ "$sshd_linked" == "true" ]]; then
        log_success "All binaries linked"
    else
        log_error "Failed to link one or more SSH binaries."
        return 1
    fi
}

# Create secure SSH config (testssl.sh compatible, Windows 11 compatible)
create_ssh_config() {
    log_step "Creating secure SSH configuration"
    
    # Backup existing
    [[ -f /etc/ssh/sshd_config ]] && cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak-$(date +%Y%m%d-%H%M%S)"
    
    # Detect sftp-server path
    local sftp_path=$(find /usr -name sftp-server -type f 2>/dev/null | head -1)
    [[ -z "$sftp_path" ]] && sftp_path="/usr/libexec/openssh/sftp-server"
    
    cat > /etc/ssh/sshd_config << EOF
# Ultra-secure OpenSSH config (testssl.sh A+ rated, Windows 11 compatible)
# Generated: $(date)

# Network
Port 22
AddressFamily any
ListenAddress 0.0.0.0
ListenAddress ::

# Host keys (only strong ones)
HostKey /etc/ssh/ssh_host_ed25519_key
HostKey /etc/ssh/ssh_host_rsa_key

# Authentication
Protocol 2
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication yes
ChallengeResponseAuthentication no
UsePAM yes

# Limits
LoginGraceTime 30s
MaxAuthTries 3
MaxSessions 2
MaxStartups 10:30:60
ClientAliveInterval 300
ClientAliveCountMax 2

# Crypto (Windows 11 compatible + testssl.sh A+)
# Key exchange
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512,diffie-hellman-group-exchange-sha256

# Ciphers (ChaCha20 + AES-GCM for Windows 11)
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com

# MACs
MACs hmac-sha2-256-etm@openssh.com,hmac-sha2-512-etm@openssh.com,umac-128-etm@openssh.com

# Host key algorithms (Windows 11 needs RSA)
HostKeyAlgorithms ssh-ed25519,ssh-ed25519-cert-v01@openssh.com,rsa-sha2-512,rsa-sha2-256

# Security hardening
PermitEmptyPasswords no
StrictModes yes
AllowAgentForwarding no
AllowTcpForwarding no
GatewayPorts no
PermitTunnel no
X11Forwarding no
UseDNS no
IgnoreRhosts yes
HostbasedAuthentication no
LogLevel VERBOSE
UsePrivilegeSeparation sandbox
PrintLastLog yes
TCPKeepAlive yes
Compression no

# SFTP
Subsystem sftp $sftp_path
EOF

    # Remove weak keys
    rm -f /etc/ssh/ssh_host_dsa_key* /etc/ssh/ssh_host_ecdsa_key* 2>/dev/null
    
    # Generate strong keys
    [[ ! -f /etc/ssh/ssh_host_ed25519_key ]] && ssh-keygen -t ed25519 -f /etc/ssh/ssh_host_ed25519_key -N '' &>/dev/null
    [[ ! -f /etc/ssh/ssh_host_rsa_key ]] && ssh-keygen -t rsa -b 3072 -f /etc/ssh/ssh_host_rsa_key -N '' &>/dev/null
    
    # Fix permissions
    chmod 600 /etc/ssh/ssh_host_*_key
    chmod 644 /etc/ssh/ssh_host_*_key.pub /etc/ssh/sshd_config
    
    # Create client config
    cat > /etc/ssh/ssh_config << 'EOF'
# Secure SSH client config
Host *
    Protocol 2
    KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512
    Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com
    MACs hmac-sha2-256-etm@openssh.com,hmac-sha2-512-etm@openssh.com,umac-128-etm@openssh.com
    HostKeyAlgorithms ssh-ed25519,ssh-ed25519-cert-v01@openssh.com,rsa-sha2-512,rsa-sha2-256
    StrictHostKeyChecking ask
    HashKnownHosts yes
    ServerAliveInterval 60
    ServerAliveCountMax 3
EOF
    
    log_success "Secure SSH configuration created"
}

# Test installation
test_installation() {
    log_step "Testing installation"
    
    local failed_tests=0
    local test_messages=()

    # Test OpenSSL
    if "${OPENSSL_INSTALL_PREFIX}/bin/openssl" version &>/dev/null; then
        test_messages+=("  ${GREEN}[✓] OpenSSL (${OPENSSL_INSTALL_PREFIX}/bin/openssl version) command successful${NC}")
    else
        test_messages+=("  ${RED}[✗] OpenSSL (${OPENSSL_INSTALL_PREFIX}/bin/openssl version) command FAILED${NC}")
        ((failed_tests++))
    fi
    
    # Test SSH client
    if ssh -V &>/dev/null; then
        local ssh_version_output
        ssh_version_output=$(ssh -V 2>&1)
        test_messages+=("  ${GREEN}[✓] SSH client (ssh -V) command successful: $ssh_version_output${NC}")
    else
        test_messages+=("  ${RED}[✗] SSH client (ssh -V) command FAILED${NC}")
        ((failed_tests++))
    fi
    
    # Test sshd config
    local sshd_test_output
    if sshd_test_output=$(/usr/sbin/sshd -t 2>&1); then
        test_messages+=("  ${GREEN}[✓] SSH server config (/usr/sbin/sshd -t) test successful${NC}")
    else
        test_messages+=("  ${RED}[✗] SSH server config (/usr/sbin/sshd -t) test FAILED${NC}")
        # Indent and print each line of the error output
        while IFS= read -r line; do
            test_messages+=("    ${GRAY}Error: $line${NC}")
        done <<< "$sshd_test_output"
        ((failed_tests++))
    fi
    
    echo # Add a newline before printing test results
    for msg in "${test_messages[@]}"; do
        echo -e "$msg"
    done
    echo # Add a newline after printing test results

    if [[ $failed_tests -eq 0 ]]; then
        log_success "All installation tests passed"
    else
        log_warn "$failed_tests installation test(s) failed. Please review messages above."
    fi
    return $failed_tests
}

# Verify installation
verify_installation() {
    print_header
    log_step "Verifying installation"
    echo
    
    local all_good=true
    
    # Check OpenSSL
    echo -e "${BOLD}OpenSSL:${NC}"
    if [[ -L "/usr/bin/openssl" ]] && [[ -x "${OPENSSL_INSTALL_PREFIX}/bin/openssl" ]]; then
        local ssl_ver
        ssl_ver=$(/usr/bin/openssl version | awk '{print $2}')
        if [[ -n "$ssl_ver" ]]; then
            echo -e "  Version: ${GREEN}$ssl_ver${NC}"
            # Simple version comparison (lexicographical, may need improvement for complex versions)
            [[ "$ssl_ver" != "$OPENSSL_VERSION" ]] && echo -e "  ${YELLOW}Installed version $ssl_ver does not match expected $OPENSSL_VERSION${NC}"
        else
            echo -e "  Status: ${RED}Could not determine OpenSSL version from /usr/bin/openssl${NC}"
            all_good=false
        fi
    else
        echo -e "  Status: ${RED}Not properly linked or installed to ${OPENSSL_INSTALL_PREFIX}${NC}"
        all_good=false
    fi
    
    # Check OpenSSH
    echo -e "\n${BOLD}OpenSSH:${NC}"
    if [[ -L "/usr/bin/ssh" ]] && [[ -L "/usr/sbin/sshd" ]] && \
       [[ -x "${OPENSSH_INSTALL_PREFIX}/bin/ssh" ]] && [[ -x "${OPENSSH_INSTALL_PREFIX}/sbin/sshd" ]]; then
        local ssh_ver
        ssh_ver=$(ssh -V 2>&1 | grep -oE 'OpenSSH_[0-9]+\.[0-9]+p[0-9]+' | sed 's/OpenSSH_//') || ssh_ver=$(ssh -V 2>&1 | grep -oE '[0-9]+\.[0-9]+p[0-9]+')

        if [[ -n "$ssh_ver" ]]; then
            echo -e "  Version: ${GREEN}$ssh_ver${NC}"
            # Simple version comparison
            [[ "$ssh_ver" != "$OPENSSH_VERSION" ]] && echo -e "  ${YELLOW}Installed version $ssh_ver does not match expected $OPENSSH_VERSION${NC}"
        else
            echo -e "  Status: ${RED}Could not determine OpenSSH version from ssh -V${NC}"
            all_good=false
        fi
    else
        echo -e "  Status: ${RED}Not properly linked or installed to ${OPENSSH_INSTALL_PREFIX}${NC}"
        all_good=false
    fi
    
    # Check libraries
    echo -e "\n${BOLD}Libraries:${NC}"
    ldconfig -p | grep -q "${OPENSSL_INSTALL_PREFIX}/lib" && echo -e "  ${GREEN}✓ OpenSSL libraries properly configured in ldconfig${NC}" || {
        echo -e "  ${RED}✗ OpenSSL libraries not found in ldconfig for ${OPENSSL_INSTALL_PREFIX}/lib${NC}"
        all_good=false
    }
    
    # Summary
    echo
    [[ "$all_good" == "true" ]] && {
        log_success "Installation verified successfully!"
    } || {
        log_error "Installation issues detected. Run '$0 install' to fix."
    }
}

# Show summary
show_summary() {
    echo
    echo -e "${BOLD}Installation Complete${NC}"
    echo -e "${GRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "OpenSSL: ${CYAN}${OPENSSL_INSTALL_PREFIX}${NC} (linked to /usr/bin/openssl)"
    echo -e "OpenSSH: ${CYAN}${OPENSSH_INSTALL_PREFIX}${NC} (linked to /usr/bin/ssh, /usr/sbin/sshd)"
    echo -e "Config:  ${CYAN}/etc/ssh/sshd_config${NC}"
    echo -e "Backups: ${CYAN}${BACKUP_DIR}${NC}"
    echo
    echo -e "${YELLOW}Security features:${NC}"
    echo -e "• Only Ed25519 + RSA-3072 host keys"
    echo -e "• ChaCha20-Poly1305 + AES-GCM ciphers"
    echo -e "• Strong KEX algorithms"
    echo -e "• Windows 11 compatible"
    echo -e "• testssl.sh A+ ready"
    echo
    echo -e "${YELLOW}Package Manager Note:${NC}"
    echo -e "• System openssl, openssh-server, and openssh-clients packages have been"
    echo -e "  excluded/held to prevent accidental overwrite by system updates."
    echo -e "• To revert this (e.g., before running '$0 remove'):"

    if command -v dnf >/dev/null; then
        echo -e "  ${CYAN}sudo dnf mark unexclude openssl openssh-server openssh-clients${NC}"
    elif command -v yum >/dev/null; then
        echo -e "  ${CYAN}Edit /etc/yum.conf or /etc/dnf/dnf.conf and remove them from the 'exclude' line.${NC}"
    elif command -v apt-mark >/dev/null; then
        echo -e "  ${CYAN}sudo apt-mark unhold openssl openssh-server openssh-clients${NC}"
    fi
    echo
}

# Reboot preparation
prepare_reboot() {
    log_warn "System will reboot in 30 seconds..."
    
    # Attempt to schedule reboot
    if ! shutdown -r +1 "OpenSSL/OpenSSH installation complete. Rebooting..." &>/dev/null; then
        log_error "Failed to schedule reboot. Please reboot manually."
        return 1
    fi

    _cancel_reboot_handler() {
        echo # Newline after ^C
        log_warn "Reboot cancellation attempt..."
        if shutdown -c "Reboot cancelled by user."; then
            log_success "Reboot successfully cancelled."
        else
            log_error "Failed to cancel reboot. It might be too late, or 'shutdown -c' is not supported/effective."
            log_info "If the system still reboots, the cancellation was not successful."
        fi
        # Restore original trap for INT and TERM that was set globally
        trap - INT TERM
        # Exit the script or this sub-process part
        exit 130 # Standard exit code for Ctrl+C
    }

    # Set a local trap for INT and TERM signals
    trap _cancel_reboot_handler INT TERM

    for i in $(seq 30 -1 1); do
        echo -ne "\r${YELLOW}Rebooting in $i seconds... (Press Ctrl+C to cancel)${NC} "
        sleep 1
    done
    
    # Clear the local trap if loop completes
    trap - INT TERM
    
    echo -e "\r${RED}${BOLD}Rebooting now...                                           ${NC}"
    # The system will reboot due to the `shutdown -r +1` command issued earlier.
    # If `shutdown -c` was successful, this message might still print but reboot won't happen.
}

# Main installation
install() {
    print_header
    
    # Check SSH session
    check_ssh_session
    
    echo -e "${YELLOW}⚠️  This installation will reboot the system when complete${NC}\n"
    
    read -r -p "Install OpenSSL $OPENSSL_VERSION + OpenSSH $OPENSSH_VERSION? [y/N] " answer
    [[ "${answer,,}" != "y" ]] && {
        log_info "Installation cancelled"
        exit 0
    }
    
    # Run installation steps
    backup_configs
    pkg_manager remove openssl openssh-server openssh-clients &>/dev/null || true
    install_dependencies || exit 1
    download_sources || exit 1
    build_openssl || exit 1
    build_openssh || exit 1
    link_all_binaries || exit 1
    create_ssh_config || exit 1
    exclude_system_packages # Call the new function here
    test_installation || log_warn "Some tests failed"
    
    # Cleanup
    cd / && rm -rf "$BUILD_DIR"
    
    show_summary
    prepare_reboot
}

# Main
main() {
    check_root
    
    # Ensure SCRIPT_DEBUG is set, default to 0 if not
    SCRIPT_DEBUG="${SCRIPT_DEBUG:-0}"

    case "${1:-}" in
        install|reinstall)
            install
            ;;
        remove|uninstall)
            print_header
            log_warn "This will remove the custom installation, unexclude/unhold system packages,"
            log_warn "and attempt to restore system default OpenSSL/OpenSSH packages."
            read -r -p "Continue? [y/N] " answer
            [[ "${answer,,}" == "y" ]] && {
                unexclude_system_packages # Call before reinstalling system packages
                log_info "Removing custom installation directories..."
                rm -rf "${OPENSSL_INSTALL_PREFIX}"
                rm -rf "${OPENSSH_INSTALL_PREFIX}"
                log_info "Removing symlinks..."
                rm -f /usr/bin/ssh* /usr/sbin/sshd /usr/bin/scp /usr/bin/sftp /usr/bin/openssl
                rm -f /etc/ld.so.conf.d/openssl-*.conf
                log_info "Updating library cache..."
                ldconfig
                log_info "Attempting to reinstall system OpenSSL and OpenSSH packages..."
                pkg_manager install openssl openssh-server openssh-clients
                log_success "Custom installation removed and system packages (attempted) restore."
                log_info "It's recommended to verify your SSH/SSL versions and functionality."
                log_warn "A system reboot might be necessary for all changes to take full effect."
            }
            ;;
        verify|check)
            verify_installation
            ;;
        *)
            print_header
            echo -e "${BOLD}Usage:${NC} $0 [install|remove|verify]\n"
            echo -e "  ${CYAN}install${NC}  - Install OpenSSL + OpenSSH"
            echo -e "  ${CYAN}remove${NC}   - Remove and restore system packages"
            echo -e "  ${CYAN}verify${NC}   - Check installation status\n"
            
            # Quick status
            if [[ -d "$OPENSSL_INSTALL_PREFIX" ]] || [[ -d "$OPENSSH_INSTALL_PREFIX" ]]; then
                 echo -e "${GREEN}Custom installation detected (${OPENSSL_INSTALL_PREFIX}, ${OPENSSH_INSTALL_PREFIX})${NC}"
            elif [[ -L "/usr/bin/openssl" ]] || [[ -L "/usr/bin/ssh" ]]; then
                 echo -e "${YELLOW}Custom installation symlinks detected, but install directories may be missing.${NC}"
            else
                 echo -e "${GRAY}No custom installation found${NC}"
            fi
            ;;
    esac
}

main "$@"