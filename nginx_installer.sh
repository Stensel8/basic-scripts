#!/usr/bin/env bash
#########################################################################
# NGINX 1.28.0 with Custom OpenSSL 3.5.0 Installer/Remover
# Compiles nginx with latest OpenSSL for better HTTP/3 performance
#########################################################################

set -euo pipefail

NGINX_VERSION="1.28.0"
OPENSSL_VERSION="3.5.0"
BUILD_DIR="/tmp/nginx-openssl-build-$$"
PREFIX="/usr/local/nginx"

log_info() { echo -e "\033[0;34m[INFO]\033[0m $1"; }
log_success() { echo -e "\033[0;32m[SUCCESS]\033[0m $1"; }
log_error() { echo -e "\033[0;31m[ERROR]\033[0m $1"; }
log_warn() { echo -e "\033[1;33m[WARN]\033[0m $1"; }

# Spinner for long operations
spinner() {
    local pid=$1
    local delay=0.1
    local spinstr='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
        local temp=${spinstr#?}
        printf " %c  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b"
    done
    printf "    \b\b\b\b"
}

# Trap to cleanup on exit
cleanup() {
    if [ -n "$BUILD_DIR" ] && [ -d "$BUILD_DIR" ]; then
        log_info "Cleaning up build directory..."
        rm -rf "$BUILD_DIR"
    fi
}
trap cleanup EXIT INT TERM

# Check for root privileges
if [ "$EUID" -ne 0 ]; then
    log_error "This script must be run as root: sudo $0"
    exit 1
fi

# Function to remove existing nginx installation
remove_nginx() {
    log_info "Removing existing nginx installation..."
    
    # Stop nginx service
    log_info "Stopping nginx service..."
    systemctl stop nginx 2>/dev/null || true
    systemctl disable nginx 2>/dev/null || true

    # Remove systemd service file
    log_info "Removing systemd service..."
    rm -f /etc/systemd/system/nginx.service
    systemctl daemon-reload

    # Remove nginx binaries
    log_info "Removing nginx binaries..."
    rm -f /usr/sbin/nginx /usr/bin/nginx

    # Ask about configuration directory
    read -p "Remove nginx configuration directory /etc/nginx? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -rf /etc/nginx
        log_info "Removed /etc/nginx"
    else
        log_warn "Keeping /etc/nginx (your configurations are safe)"
    fi

    # Remove other nginx directories
    log_info "Removing nginx directories..."
    rm -rf /usr/local/nginx
    rm -rf /var/cache/nginx
    rm -rf /var/log/nginx

    # Remove nginx user
    log_info "Removing nginx user..."
    userdel nginx 2>/dev/null || true
    groupdel nginx 2>/dev/null || true

    # Kill any remaining nginx processes (but not this script!)
    # Only kill actual nginx processes, not scripts with nginx in the name
    if pgrep -x nginx >/dev/null 2>&1; then
        pkill -x nginx 2>/dev/null || true
    fi

    # Remove from package manager if installed that way
    if command -v dnf >/dev/null 2>&1; then
        dnf remove -y nginx nginx-* 2>/dev/null || true
    elif command -v apt >/dev/null 2>&1; then
        apt remove --purge -y nginx nginx-* 2>/dev/null || true
    fi

    log_success "Nginx removal completed!"
    exit 0
}

# Function to install nginx with custom OpenSSL
install_nginx() {
    log_info "Installing Nginx $NGINX_VERSION with OpenSSL $OPENSSL_VERSION"

    # Install build dependencies
    log_info "Installing build dependencies..."
    if command -v dnf >/dev/null 2>&1; then
        # Fedora/RHEL/CentOS
        if dnf --version 2>/dev/null | grep -q "dnf5"; then
            dnf install -y @development-tools >/dev/null 2>&1
            dnf install -y pcre2-devel zlib-devel perl wget gcc make >/dev/null 2>&1
        else
            dnf groupinstall -y "Development Tools" >/dev/null 2>&1 || true
            dnf install -y pcre2-devel zlib-devel perl wget gcc make >/dev/null 2>&1
        fi
    elif command -v apt >/dev/null 2>&1; then
        # Ubuntu/Debian
        export DEBIAN_FRONTEND=noninteractive
        apt update >/dev/null 2>&1
        apt install -y build-essential libpcre2-dev zlib1g-dev perl wget gcc make >/dev/null 2>&1
    else
        log_error "Unsupported package manager. This script supports dnf and apt."
        exit 1
    fi

    # Create build directory
    mkdir -p "$BUILD_DIR" && cd "$BUILD_DIR"

    # Download OpenSSL source
    log_info "Downloading OpenSSL $OPENSSL_VERSION..."
    wget -q "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz"
    tar xf "openssl-${OPENSSL_VERSION}.tar.gz"

    # Download nginx source
    log_info "Downloading nginx $NGINX_VERSION source..."
    wget -q "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz"
    tar xf "nginx-${NGINX_VERSION}.tar.gz"

    # Build OpenSSL first (static linking for nginx)
    log_info "Configuring OpenSSL $OPENSSL_VERSION..."
    cd "openssl-${OPENSSL_VERSION}"

    # Configure OpenSSL with optimizations
    ./Configure linux-x86_64 \
        --prefix="$BUILD_DIR/openssl-install" \
        --openssldir="$BUILD_DIR/openssl-install/ssl" \
        enable-tls1_3 \
        enable-ec_nistp_64_gcc_128 \
        no-shared \
        no-tests \
        -fPIC \
        -O3 \
        -march=native >/dev/null 2>&1

    log_info "Building OpenSSL (this takes a while)..."
    make -j"$(nproc)" >/dev/null 2>&1 &
    spinner $!
    
    log_info "Installing OpenSSL libraries..."
    make install_sw >/dev/null 2>&1

    cd ..

    # Configure nginx with custom OpenSSL
    log_info "Configuring nginx with custom OpenSSL..."
    cd "nginx-${NGINX_VERSION}"

    # Set OpenSSL paths
    OPENSSL_PATH="$BUILD_DIR/openssl-install"
    export CFLAGS="-I${OPENSSL_PATH}/include -O3 -march=native"
    export LDFLAGS="-L${OPENSSL_PATH}/lib64 -L${OPENSSL_PATH}/lib"

    ./configure \
        --prefix="$PREFIX" \
        --sbin-path=/usr/sbin/nginx \
        --conf-path=/etc/nginx/nginx.conf \
        --error-log-path=/var/log/nginx/error.log \
        --http-log-path=/var/log/nginx/access.log \
        --pid-path=/run/nginx.pid \
        --lock-path=/run/nginx.lock \
        --http-client-body-temp-path=/var/cache/nginx/client_temp \
        --http-proxy-temp-path=/var/cache/nginx/proxy_temp \
        --http-fastcgi-temp-path=/var/cache/nginx/fastcgi_temp \
        --http-uwsgi-temp-path=/var/cache/nginx/uwsgi_temp \
        --http-scgi-temp-path=/var/cache/nginx/scgi_temp \
        --user=nginx \
        --group=nginx \
        --with-openssl="$BUILD_DIR/openssl-${OPENSSL_VERSION}" \
        --with-compat \
        --with-file-aio \
        --with-threads \
        --with-http_addition_module \
        --with-http_auth_request_module \
        --with-http_dav_module \
        --with-http_flv_module \
        --with-http_gunzip_module \
        --with-http_gzip_static_module \
        --with-http_mp4_module \
        --with-http_random_index_module \
        --with-http_realip_module \
        --with-http_secure_link_module \
        --with-http_slice_module \
        --with-http_ssl_module \
        --with-http_stub_status_module \
        --with-http_sub_module \
        --with-http_v2_module \
        --with-http_v3_module \
        --with-mail \
        --with-mail_ssl_module \
        --with-stream \
        --with-stream_realip_module \
        --with-stream_ssl_module \
        --with-stream_ssl_preread_module \
        --with-cc-opt="-O3 -march=native -mtune=native -fstack-protector-strong" \
        --with-ld-opt="-Wl,-z,relro -Wl,-z,now" >/dev/null 2>&1

    # Build nginx
    log_info "Building nginx with custom OpenSSL (this may take several minutes)..."
    make -j"$(nproc)" >/dev/null 2>&1 &
    spinner $!

    # Install nginx
    log_info "Installing nginx..."
    make install >/dev/null 2>&1

    # Create nginx user if needed
    if ! id nginx >/dev/null 2>&1; then
        useradd --system --home /var/cache/nginx --shell /sbin/nologin --comment "nginx user" nginx
        log_info "Created nginx user"
    else
        log_info "nginx user already exists"
    fi

    # Create required directories
    log_info "Creating required directories..."
    mkdir -p /var/cache/nginx/{client_temp,proxy_temp,fastcgi_temp,uwsgi_temp,scgi_temp}
    mkdir -p /var/log/nginx
    mkdir -p /etc/nginx/{conf.d,snippets}

    # Set permissions
    chown -R nginx:nginx /var/cache/nginx /var/log/nginx
    chmod 755 /var/cache/nginx /var/log/nginx

    # Create systemd service
    log_info "Creating systemd service..."
    cat > /etc/systemd/system/nginx.service << 'EOF'
[Unit]
Description=The NGINX HTTP and reverse proxy server
Documentation=http://nginx.org/en/docs/
After=network.target remote-fs.target nss-lookup.target

[Service]
Type=forking
PIDFile=/run/nginx.pid
ExecStartPre=/usr/sbin/nginx -t
ExecStart=/usr/sbin/nginx
ExecReload=/usr/sbin/nginx -s reload
ExecStop=/bin/kill -s QUIT $MAINPID
KillSignal=SIGQUIT
TimeoutStopSec=5
KillMode=mixed
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

    # Reload systemd and enable service
    systemctl daemon-reload
    systemctl enable nginx >/dev/null 2>&1

    # Test configuration and start
    log_info "Testing nginx configuration..."
    if ! /usr/sbin/nginx -t >/dev/null 2>&1; then
        log_error "Nginx configuration test failed!"
        exit 1
    fi

    log_info "Starting nginx..."
    systemctl start nginx

    # Cleanup build directory
    cd / && rm -rf "$BUILD_DIR"

    # Verify installation
    log_success "Nginx $NGINX_VERSION with OpenSSL $OPENSSL_VERSION installation completed!"

    # Show versions
    nginx_version=$(/usr/sbin/nginx -v 2>&1)
    openssl_version=$(/usr/sbin/nginx -V 2>&1 | grep -o 'OpenSSL [0-9]\+\.[0-9]\+\.[0-9]\+')

    log_info "Installed version: $nginx_version"
    log_info "Built with: $openssl_version"

    # Check HTTP/3 support
    if /usr/sbin/nginx -V 2>&1 | grep -q "http_v3_module"; then
        log_success "✓ HTTP/3 support available"
    else
        log_error "✗ HTTP/3 support not available"
    fi

    # Check QUIC support in OpenSSL
    if /usr/sbin/nginx -V 2>&1 | grep -q "OpenSSL 3\.5"; then
        log_success "✓ OpenSSL 3.5.x with enhanced QUIC support"
    else
        log_info "OpenSSL version detected: $openssl_version"
    fi

    log_info "Nginx is running and enabled for startup"
    log_info "Configuration files are in /etc/nginx/"
    log_info "You can check status with: sudo systemctl status nginx"

    # Show performance info
    log_info "Performance optimizations applied:"
    echo "  • Native CPU optimizations (-march=native -mtune=native)"
    echo "  • OpenSSL 3.5.0 with latest QUIC improvements"
    echo "  • Statically linked OpenSSL for better performance"
    echo "  • Stack protection and security hardening enabled"
}

# Main script logic
main() {
    # Parse command line arguments
    ACTION=""
    if [ $# -gt 0 ]; then
        case "$1" in
            remove|uninstall)
                ACTION="remove"
                ;;
            install|reinstall)
                ACTION="install"
                ;;
            *)
                log_error "Unknown argument: $1"
                log_info "Usage: $0 [install|remove]"
                exit 1
                ;;
        esac
    fi

    # Check if nginx is already installed
    if command -v nginx >/dev/null 2>&1; then
        # Nginx is installed - get version info
        nginx_version=$(nginx -v 2>&1 | grep -o 'nginx/[0-9.]*' | cut -d'/' -f2)
        openssl_info=$(nginx -V 2>&1 | grep -o 'built with OpenSSL [^[:space:]]*' 2>/dev/null || echo "OpenSSL info unavailable")
        
        log_warn "Existing nginx installation detected:"
        log_info "Current version: nginx/$nginx_version"
        log_info "$openssl_info"
        
        # If action was specified via command line, use it
        if [ -n "$ACTION" ]; then
            case "$ACTION" in
                remove)
                    remove_nginx
                    ;;
                install)
                    log_info "Proceeding with installation (existing nginx will be removed first)..."
                    systemctl stop nginx 2>/dev/null || true
                    rm -f /usr/sbin/nginx /usr/bin/nginx
                    install_nginx
                    ;;
            esac
        else
            # Check if we're running interactively
            if [ -t 0 ]; then
                # Interactive mode - show menu
                echo
                echo "What would you like to do?"
                echo "1) Remove existing nginx installation"
                echo "2) Install new nginx (will remove existing first)"
                echo "3) Cancel and exit"
                echo
                read -p "Please choose (1/2/3): " -n 1 -r
                echo
                
                case $REPLY in
                    1)
                        remove_nginx
                        ;;
                    2)
                        log_info "Proceeding with installation (existing nginx will be removed first)..."
                        systemctl stop nginx 2>/dev/null || true
                        rm -f /usr/sbin/nginx /usr/bin/nginx
                        install_nginx
                        ;;
                    3)
                        log_info "Operation cancelled by user"
                        exit 0
                        ;;
                    *)
                        log_error "Invalid choice. Exiting."
                        exit 1
                        ;;
                esac
            else
                # Non-interactive mode (piped) - show instructions
                log_warn "Running in non-interactive mode. Specify an action:"
                echo
                log_info "To install/reinstall nginx:"
                echo "  curl -fsSL https://raw.githubusercontent.com/Stensel8/scripts/main/nginx_installer.sh | sudo bash -s install"
                echo
                log_info "To remove nginx:"
                echo "  curl -fsSL https://raw.githubusercontent.com/Stensel8/scripts/main/nginx_installer.sh | sudo bash -s remove"
                echo
                exit 1
            fi
        fi
    else
        # No nginx installed - proceed with installation
        log_info "No existing nginx installation detected"
        install_nginx
    fi
}

# Run main function
main "$@"