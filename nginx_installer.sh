#!/usr/bin/env bash
#########################################################################
# NGINX Installer Script - Based on Official Documentation
#########################################################################

# Enable strict error handling
set -euo pipefail

#########################################################################
# CONFIGURATION VARIABLES
#########################################################################

# Default to stable release channel
CHANNEL="stable"

# Official nginx GPG key fingerprint for verification
NGINX_GPG_FINGERPRINT="573BFD6B3D8FBC641079A6ABABF5BD827BD9BF62"

# Base URLs
NGINX_KEY_URL="https://nginx.org/keys/nginx_signing.key"
NGINX_DOWNLOAD_URL="https://nginx.org/download"

# Current versions (update these when new versions are released)
STABLE_VERSION="1.28.0"
MAINLINE_VERSION="1.28.0"

# Log formatting
LOG_INFO="[INFO]"
LOG_WARN="[WARN]"
LOG_ERROR="[ERROR]"
LOG_SUCCESS="[SUCCESS]"

#########################################################################
# HELPER FUNCTIONS
#########################################################################

usage() { 
    echo "Usage: $0 [-c stable|mainline]" >&2
    echo "  -c channel: Choose 'stable' or 'mainline' (default: stable)" >&2
    exit 1
}

log_info() { echo "${LOG_INFO} $1"; }
log_warn() { echo "${LOG_WARN} $1"; }
log_error() { echo "${LOG_ERROR} $1"; }
log_success() { echo "${LOG_SUCCESS} $1"; }

# Detect Linux distribution with better support
detect_distro() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case "$ID" in
            ubuntu) echo "ubuntu" ;;
            debian) echo "debian" ;;
            centos|rhel|rocky|alma|ol) echo "rhel" ;;
            fedora) echo "fedora" ;;
            opensuse*|sles) echo "suse" ;;
            alpine) echo "alpine" ;;
            amzn) echo "amazon" ;;
            *) echo "unknown" ;;
        esac
    else
        echo "unknown"
    fi
}

# Check if distribution/version is officially supported
check_official_support() {
    local distro="$1"
    local version="$2"
    
    case "$distro" in
        rhel)
            if [[ "$version" =~ ^[89]\..*$ ]]; then
                return 0
            fi
            ;;
        debian)
            if [[ "$version" =~ ^1[12]\..*$ ]]; then
                return 0
            fi
            ;;
        ubuntu)
            case "$version" in
                20.04|22.04|24.04|24.10|25.04) return 0 ;;
            esac
            ;;
        suse)
            if [[ "$version" =~ ^15\..*$ ]]; then
                return 0
            fi
            ;;
        alpine)
            if [[ "$version" =~ ^3\.(18|19|20|21)$ ]]; then
                return 0
            fi
            ;;
        amazon)
            case "$version" in
                2|2023) return 0 ;;
            esac
            ;;
        fedora)
            # Fedora is not officially supported by nginx.org
            return 1
            ;;
    esac
    return 1
}

# Verify nginx installation
verify_nginx() {
    if ! command -v nginx >/dev/null; then
        log_error "nginx command not found after installation"
        return 1
    fi
    
    local nginx_ver
    nginx_ver=$(nginx -v 2>&1)
    log_info "Installed NGINX version: $nginx_ver"
    
    # Check if HTTP/3 is supported
    if nginx -V 2>&1 | grep -q "http_v3_module\|with-http_v3_module"; then
        log_success "HTTP/3 support: ✓ Available"
    else
        log_warn "HTTP/3 support: ✗ Not available"
    fi
    
    return 0
}

#########################################################################
# DISTRIBUTION-SPECIFIC INSTALLATION FUNCTIONS
#########################################################################

install_rhel_centos() {
    log_info "Installing for RHEL/CentOS"
    
    # Install prerequisites
    if command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y yum-utils
    else
        sudo yum install -y yum-utils
    fi
    
    # Create repository file
    sudo tee /etc/yum.repos.d/nginx.repo > /dev/null <<EOF
[nginx-stable]
name=nginx stable repo
baseurl=http://nginx.org/packages/centos/\$releasever/\$basearch/
gpgcheck=1
enabled=1
gpgkey=${NGINX_KEY_URL}
module_hotfixes=true

[nginx-mainline]
name=nginx mainline repo
baseurl=http://nginx.org/packages/mainline/centos/\$releasever/\$basearch/
gpgcheck=1
enabled=0
gpgkey=${NGINX_KEY_URL}
module_hotfixes=true
EOF

    # Enable mainline if requested
    if [ "$CHANNEL" = "mainline" ]; then
        sudo yum-config-manager --enable nginx-mainline --disable nginx-stable
    fi
    
    # Install nginx
    if command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y nginx
    else
        sudo yum install -y nginx
    fi
}

install_fedora() {
    log_warn "Fedora is not officially supported by nginx.org"
    log_info "Attempting to use RHEL packages as fallback"
    
    # Try to use RHEL 9 packages for newer Fedora
    local fedora_ver
    fedora_ver=$(rpm -E %fedora)
    local rhel_ver="9"
    
    if [ "$fedora_ver" -lt 38 ]; then
        rhel_ver="8"
    fi
    
    log_info "Using RHEL $rhel_ver packages for Fedora $fedora_ver"
    
    # Install prerequisites
    sudo dnf install -y yum-utils
    
    # Create repository file with RHEL compatibility
    sudo tee /etc/yum.repos.d/nginx.repo > /dev/null <<EOF
[nginx-stable]
name=nginx stable repo
baseurl=http://nginx.org/packages/centos/${rhel_ver}/\$basearch/
gpgcheck=1
enabled=1
gpgkey=${NGINX_KEY_URL}
module_hotfixes=true

[nginx-mainline]
name=nginx mainline repo
baseurl=http://nginx.org/packages/mainline/centos/${rhel_ver}/\$basearch/
gpgcheck=1
enabled=0
gpgkey=${NGINX_KEY_URL}
module_hotfixes=true
EOF

    # Enable mainline if requested
    if [ "$CHANNEL" = "mainline" ]; then
        sudo dnf config-manager --set-enabled nginx-mainline --set-disabled nginx-stable
    fi
    
    # Install nginx
    if ! sudo dnf install -y nginx; then
        log_error "Failed to install from nginx.org repository"
        log_info "Falling back to Fedora's own nginx package"
        sudo dnf remove -y nginx 2>/dev/null || true
        sudo rm -f /etc/yum.repos.d/nginx.repo
        sudo dnf install -y nginx
        log_warn "Using Fedora's nginx package (may be older version)"
    fi
}

install_debian_ubuntu() {
    local distro="$1"
    log_info "Installing for $distro"
    
    # Install prerequisites
    if [ "$distro" = "ubuntu" ]; then
        sudo apt install -y curl gnupg2 ca-certificates lsb-release ubuntu-keyring
    else
        sudo apt install -y curl gnupg2 ca-certificates lsb-release debian-archive-keyring
    fi
    
    # Import nginx signing key
    curl -fsSL ${NGINX_KEY_URL} | gpg --dearmor \
        | sudo tee /usr/share/keyrings/nginx-archive-keyring.gpg >/dev/null
    
    # Verify key fingerprint
    if ! gpg --dry-run --quiet --no-keyring --import --import-options import-show \
        /usr/share/keyrings/nginx-archive-keyring.gpg 2>/dev/null | grep -q "$NGINX_GPG_FINGERPRINT"; then
        log_error "GPG key verification failed!"
        return 1
    fi
    
    # Set up repository
    local repo_url
    if [ "$CHANNEL" = "mainline" ]; then
        repo_url="http://nginx.org/packages/mainline/$distro"
    else
        repo_url="http://nginx.org/packages/$distro"
    fi
    
    echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] $repo_url $(lsb_release -cs) nginx" \
        | sudo tee /etc/apt/sources.list.d/nginx.list
    
    # Set up repository pinning
    echo -e "Package: *\nPin: origin nginx.org\nPin: release o=nginx\nPin-Priority: 900\n" \
        | sudo tee /etc/apt/preferences.d/99nginx
    
    # Install nginx
    sudo apt update
    sudo apt install -y nginx
}

install_alpine() {
    log_info "Installing for Alpine Linux"
    
    # Install prerequisites
    sudo apk add openssl curl ca-certificates
    
    # Set up repository
    local repo_url
    local alpine_ver
    alpine_ver=$(grep -o '^[0-9]\+\.[0-9]\+' /etc/alpine-release)
    
    if [ "$CHANNEL" = "mainline" ]; then
        repo_url="http://nginx.org/packages/mainline/alpine/v${alpine_ver}/main"
    else
        repo_url="http://nginx.org/packages/alpine/v${alpine_ver}/main"
    fi
    
    echo "@nginx $repo_url" | sudo tee -a /etc/apk/repositories
    
    # Import signing key
    curl -fsSL https://nginx.org/keys/nginx_signing.rsa.pub -o /tmp/nginx_signing.rsa.pub
    sudo mv /tmp/nginx_signing.rsa.pub /etc/apk/keys/
    
    # Install nginx
    sudo apk add nginx@nginx
}

install_amazon() {
    log_info "Installing for Amazon Linux"
    
    # Install prerequisites
    sudo yum install -y yum-utils
    
    # Detect Amazon Linux version
    local amzn_ver
    if grep -q "Amazon Linux 2023" /etc/os-release; then
        amzn_ver="2023"
    else
        amzn_ver="2"
    fi
    
    # Create repository file
    if [ "$amzn_ver" = "2023" ]; then
        sudo tee /etc/yum.repos.d/nginx.repo > /dev/null <<EOF
[nginx-stable]
name=nginx stable repo
baseurl=http://nginx.org/packages/amzn/2023/\$basearch/
gpgcheck=1
enabled=1
gpgkey=${NGINX_KEY_URL}
module_hotfixes=true
priority=9

[nginx-mainline]
name=nginx mainline repo
baseurl=http://nginx.org/packages/mainline/amzn/2023/\$basearch/
gpgcheck=1
enabled=0
gpgkey=${NGINX_KEY_URL}
module_hotfixes=true
priority=9
EOF
    else
        sudo tee /etc/yum.repos.d/nginx.repo > /dev/null <<EOF
[nginx-stable]
name=nginx stable repo
baseurl=http://nginx.org/packages/amzn2/\$releasever/\$basearch/
gpgcheck=1
enabled=1
gpgkey=${NGINX_KEY_URL}
module_hotfixes=true
priority=9

[nginx-mainline]
name=nginx mainline repo
baseurl=http://nginx.org/packages/mainline/amzn2/\$releasever/\$basearch/
gpgcheck=1
enabled=0
gpgkey=${NGINX_KEY_URL}
module_hotfixes=true
priority=9
EOF
    fi
    
    # Enable mainline if requested
    if [ "$CHANNEL" = "mainline" ]; then
        sudo yum-config-manager --enable nginx-mainline --disable nginx-stable
    fi
    
    # Install nginx
    sudo yum install -y nginx
}

#########################################################################
# SOURCE INSTALLATION (FALLBACK)
#########################################################################

install_from_source() {
    log_info "Installing NGINX from source as fallback"
    
    # Set version based on channel
    local version
    if [ "$CHANNEL" = "stable" ]; then
        version="$STABLE_VERSION"
    else
        version="$MAINLINE_VERSION"
    fi
    
    # Create build directory
    local build_dir="/tmp/nginx-build-$$"
    mkdir -p "$build_dir" && cd "$build_dir"
    
    # Install build dependencies based on distribution
    case "$DISTRO" in
        debian|ubuntu)
            sudo apt update
            sudo apt install -y build-essential libpcre3-dev zlib1g-dev libssl-dev
            ;;
        rhel|fedora)
            if command -v dnf >/dev/null; then
                sudo dnf groupinstall -y "Development Tools"
                sudo dnf install -y pcre-devel zlib-devel openssl-devel
            else
                sudo yum groupinstall -y "Development Tools"
                sudo yum install -y pcre-devel zlib-devel openssl-devel
            fi
            ;;
        alpine)
            sudo apk add build-base pcre-dev zlib-dev openssl-dev
            ;;
        *)
            log_error "Cannot install build dependencies for $DISTRO"
            return 1
            ;;
    esac
    
    # Download and verify source
    log_info "Downloading NGINX $version source"
    curl -fsSL "${NGINX_DOWNLOAD_URL}/nginx-${version}.tar.gz" -o nginx.tar.gz
    curl -fsSL "${NGINX_DOWNLOAD_URL}/nginx-${version}.tar.gz.asc" -o nginx.tar.gz.asc
    
    # Import key and verify (if possible)
    if command -v gpg >/dev/null; then
        curl -fsSL "$NGINX_KEY_URL" | gpg --import 2>/dev/null || true
        gpg --verify nginx.tar.gz.asc nginx.tar.gz 2>/dev/null || log_warn "GPG verification failed or not possible"
    fi
    
    # Extract and build
    tar xf nginx.tar.gz
    cd "nginx-${version}"
    
    # Configure with modules including HTTP/3
    log_info "Configuring build with HTTP/3 support"
    ./configure \
        --prefix=/usr/local/nginx \
        --sbin-path=/usr/local/sbin/nginx \
        --conf-path=/etc/nginx/nginx.conf \
        --error-log-path=/var/log/nginx/error.log \
        --http-log-path=/var/log/nginx/access.log \
        --pid-path=/var/run/nginx.pid \
        --lock-path=/var/run/nginx.lock \
        --with-http_ssl_module \
        --with-http_v2_module \
        --with-http_v3_module \
        --with-http_realip_module \
        --with-http_stub_status_module \
        --with-http_gzip_static_module \
        --with-stream \
        --with-stream_ssl_module
    
    # Build and install
    log_info "Building NGINX (this may take several minutes)"
    make -j"$(nproc 2>/dev/null || echo 2)"
    sudo make install
    
    # Create systemd service
    sudo tee /etc/systemd/system/nginx.service > /dev/null <<EOF
[Unit]
Description=The NGINX HTTP and reverse proxy server
After=network.target remote-fs.target nss-lookup.target

[Service]
Type=forking
PIDFile=/var/run/nginx.pid
ExecStartPre=/usr/local/sbin/nginx -t
ExecStart=/usr/local/sbin/nginx
ExecReload=/usr/local/sbin/nginx -s reload
ExecStop=/bin/kill -s QUIT \$MAINPID
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
    
    # Create symlink
    sudo ln -sf /usr/local/sbin/nginx /usr/bin/nginx
    
    # Reload systemd
    sudo systemctl daemon-reload
    
    # Cleanup
    cd / && rm -rf "$build_dir"
    
    log_success "NGINX $version compiled and installed from source"
}

#########################################################################
# MAIN INSTALLATION LOGIC
#########################################################################

main() {
    # Parse command line options
    while getopts "c:" opt; do
        case $opt in
            c) 
                if [[ "$OPTARG" =~ ^(stable|mainline)$ ]]; then
                    CHANNEL="$OPTARG"
                else
                    log_error "Channel must be 'stable' or 'mainline'"
                    usage
                fi
                ;;
            *) usage ;;
        esac
    done
    
    # Also support direct parameter (for piping)
    if [ $# -eq 1 ] && [[ "$1" =~ ^(stable|mainline)$ ]]; then
        CHANNEL="$1"
    fi
    
    # Check for root privileges
    if [ "$EUID" -ne 0 ]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
    
    # Detect distribution
    DISTRO=$(detect_distro)
    log_info "Detected distribution: $DISTRO"
    log_info "Selected channel: $CHANNEL"
    
    # Get distribution version
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        VERSION_ID="${VERSION_ID:-unknown}"
    else
        VERSION_ID="unknown"
    fi
    
    # Check official support
    if check_official_support "$DISTRO" "$VERSION_ID"; then
        log_info "Distribution officially supported by nginx.org"
    else
        log_warn "Distribution not officially supported by nginx.org"
        log_info "Will attempt installation anyway or fall back to source"
    fi
    
    # Stop existing nginx if running
    if systemctl is-active --quiet nginx 2>/dev/null; then
        log_info "Stopping existing nginx service"
        sudo systemctl stop nginx
    fi
    
    # Install based on distribution
    case "$DISTRO" in
        rhel)
            install_rhel_centos
            ;;
        fedora)
            install_fedora
            ;;
        debian)
            install_debian_ubuntu debian
            ;;
        ubuntu)
            install_debian_ubuntu ubuntu
            ;;
        alpine)
            install_alpine
            ;;
        amazon)
            install_amazon
            ;;
        *)
            log_warn "Unsupported distribution, falling back to source installation"
            install_from_source
            ;;
    esac
    
    # Verify installation
    if verify_nginx; then
        log_success "NGINX installation completed successfully"
        
        # Enable and start service
        sudo systemctl enable nginx
        sudo systemctl start nginx
        
        log_info "NGINX service enabled and started"
        log_info "You can check status with: sudo systemctl status nginx"
    else
        log_error "NGINX installation verification failed"
        exit 1
    fi
}

# Run main function
main "$@"