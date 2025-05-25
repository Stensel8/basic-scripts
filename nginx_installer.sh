#!/usr/bin/env bash
#########################################################################
# NGINX 1.28.0 with Custom OpenSSL 3.5.0, Zstd & GeoIP2 Installer
# Compiles nginx with latest OpenSSL for HTTP/3 + Zstd + GeoIP2
#########################################################################

# Safer error handling
set -uo pipefail

# Version definitions
NGINX_VERSION="1.28.0"
OPENSSL_VERSION="3.5.0"
PCRE2_VERSION="10.45"
ZLIB_VERSION="1.3.1"
ZSTD_VERSION="1.5.7"
ZSTD_MODULE_VERSION="0.1.1"
GEOIP2_MODULE_VERSION="3.4"
HEADERS_MORE_MODULE_VERSION="0.38"

# Build configuration
BUILD_DIR="/tmp/nginx-openssl-build-$$"
PREFIX="/usr/local/nginx"
LOG_DIR="/tmp/nginx-install-logs-$$"

# Color definitions
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly PURPLE='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly GRAY='\033[0;90m'
readonly NC='\033[0m' # No Color
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

# Function to free ports 80 and 443
free_ports() {
  # Stop & disable any systemd socket listening on 80 or 443
  for sock in $(systemctl list-sockets --all --no-legend \
                 | awk '/:80|:443/ {print $1}'); do
    echo "Stopping socket $sock"
    systemctl stop "$sock"   2>/dev/null || true
    systemctl disable "$sock" 2>/dev/null || true
  done

  # Stop & disable common web services so they don’t rebind
  for svc in nginx nginx.socket nginx-debug httpd apache2 caddy traefik haproxy; do
    if systemctl is-active "$svc"   &>/dev/null \
    || systemctl is-enabled "$svc" &>/dev/null; then
      echo "Disabling service $svc"
      systemctl stop   "$svc" 2>/dev/null || true
      systemctl disable "$svc" 2>/dev/null || true
    fi
  done

  # Kill any process listening on ports 80 or 443
  for port in 80 443; do
    while ss -ltnp | grep -q ":$port "; do
      pid=$(ss -ltnp | sed -n "s/.*pid=\([0-9]\+\),.*/\1/p" | head -n1)
      echo "Killing PID $pid on port $port"
      kill -9 "$pid" 2>/dev/null || true
      sleep 0.5
    done
  done

  echo "✓ Ports 80 and 443 are now free"
}

# Progress bar function
show_progress() {
    local current=$1
    local total=$2
    local width=50
    local percentage=$((current * 100 / total))
    local completed=$((width * current / total))
    
    printf "\r["
    printf "%${completed}s" | tr ' ' '='
    printf "%$((width - completed))s" | tr ' ' ']'
    printf "] %3d%%" $percentage
}

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

# Cleanup function
cleanup() {
    if [ -n "$BUILD_DIR" ] && [ -d "$BUILD_DIR" ]; then
        rm -rf "$BUILD_DIR"
    fi
    if [ -n "$LOG_DIR" ] && [ -d "$LOG_DIR" ]; then
        rm -rf "$LOG_DIR"
    fi
}
trap cleanup EXIT INT TERM

# Check for root privileges
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "This script must be run as root"
        echo -e "${GRAY}Usage: sudo $0 [install|remove|verify]${NC}"
        exit 1
    fi
}

# Function to print header
print_header() {
    echo
    echo -e "${BOLD}NGINX Custom Build Installer${NC}"
    echo -e "${GRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "NGINX ${CYAN}$NGINX_VERSION${NC} with OpenSSL ${CYAN}$OPENSSL_VERSION${NC}, Zstd & GeoIP2"
    echo -e "${GRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo
}

# Remove existing nginx installation
remove_nginx() {
    print_header
    log_step "Removing existing NGINX installation"
    echo
    
    local steps=(
        "Stopping services"
        "Killing processes"
        "Removing packages"
        "Cleaning directories"
        "Removing user/group"
    )
    
    local total_steps=${#steps[@]}
    local current_step=0
    
    # Stop services
    ((current_step++))
    show_progress $current_step $total_steps
    echo -e " ${steps[$((current_step-1))]}"
    # Stop all possible nginx service names
    systemctl stop nginx.service nginx.socket nginx-debug.service 2>/dev/null || true
    systemctl disable nginx.service nginx.socket nginx-debug.service 2>/dev/null || true
    
    # Kill all nginx processes
    ((current_step++))
    show_progress $current_step $total_steps
    echo -e " ${steps[$((current_step-1))]}"
    
    # Kill  nginx (master + workers)
    if pgrep -x nginx >/dev/null; then
    pkill -15 -x nginx 2>/dev/null || true   # graceful
    sleep 1
    pkill -9 -x nginx 2>/dev/null || true    # force-kill
    sleep 1
    fi
    # Wait to ensure processes are terminated
    sleep 1
    
    # Remove packages
    ((current_step++))
    show_progress $current_step $total_steps
    echo -e " ${steps[$((current_step-1))]}"
    
    if command -v dnf >/dev/null 2>&1; then
        dnf remove -y nginx nginx-* &>/dev/null || true
        dnf autoremove -y &>/dev/null || true
    elif command -v apt >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt remove --purge -y nginx nginx-* nginx-common nginx-full &>/dev/null || true
        DEBIAN_FRONTEND=noninteractive apt autoremove --purge -y &>/dev/null || true
    fi
    
    # Clean directories
    ((current_step++))
    show_progress $current_step $total_steps
    echo -e " ${steps[$((current_step-1))]}"
    
    rm -rf /etc/nginx /var/log/nginx /var/cache/nginx /usr/local/nginx
    rm -f /usr/sbin/nginx /usr/bin/nginx /usr/local/sbin/nginx
    rm -f /lib/systemd/system/nginx.service /etc/systemd/system/nginx.service
    rm -f /etc/init.d/nginx
    # Remove systemd configuration cache
    systemctl daemon-reload 2>/dev/null || true
    
    # Remove user/group
    ((current_step++))
    show_progress $current_step $total_steps
    echo -e " ${steps[$((current_step-1))]}"
    userdel nginx 2>/dev/null || true
    groupdel nginx 2>/dev/null || true
    
    # Clear the shell's path cache
    hash -r 2>/dev/null || true
    
    echo
    echo
    log_success "NGINX removal completed successfully!"
    
    # Give it a moment to ensure everything is cleaned up
    sleep 2
    
    # Check if any nginx processes still running
    if pgrep -x nginx >/dev/null; then
        log_warn "Some NGINX processes are still running! Try manually killing them with:"
        echo -e "${GRAY}  sudo pkill -9 -f nginx${NC}"
        echo
    fi
    
    # Check if port 80 is still in use and identify the process
    check_port_80
}

# Function to check if port 80 is in use and by what process
check_port_80() {
    if ss -tuln | grep -q ":80 "; then
        log_warn "Port 80 is still in use after removal!"
        echo -e "Attempting to identify the process using port 80..."
        
        # Try lsof if available
        if command -v lsof >/dev/null 2>&1; then
            echo -e "${GRAY}Process using port 80:${NC}"
            lsof -i :80 | tail -n +2
        # Try fuser if available
        elif command -v fuser >/dev/null 2>&1; then
            echo -e "${GRAY}Process using port 80:${NC}"
            fuser -v 80/tcp
        # Use netstat as fallback
        elif command -v netstat >/dev/null 2>&1; then
            echo -e "${GRAY}Process using port 80:${NC}"
            netstat -tulpn | grep ":80 "
        fi
        
        echo
        log_warn "You may need to manually stop this service before starting NGINX."
        return 1
    fi
    
    log_success "Port 80 is free and available for use."
    return 0
}

# Install dependencies
install_dependencies() {
    log_step "Installing build dependencies"
    
    local deps_log="$LOG_DIR/dependencies.log"
    
    if command -v dnf >/dev/null 2>&1; then
        log_detail "Detected Fedora/RHEL system"
        {
            if dnf --version 2>/dev/null | grep -q "dnf5"; then
                dnf install -y @development-tools
            else
                dnf groupinstall -y "Development Tools"
            fi
            dnf install -y pcre2-devel zlib-devel perl wget gcc make git \
                libmaxminddb-devel libzstd-devel
        } &>"$deps_log" &
        spinner $! "Installing packages"
    elif command -v apt >/dev/null 2>&1; then
        log_detail "Detected Ubuntu/Debian system"
        {
            export DEBIAN_FRONTEND=noninteractive
            apt update
            apt install -y build-essential libpcre2-dev zlib1g-dev perl wget gcc make git \
                libmaxminddb-dev mmdb-bin libzstd-dev
        } &>"$deps_log" &
        spinner $! "Installing packages"
    else
        log_error "Unsupported package manager"
        return 1
    fi
    
    [ $? -eq 0 ] || { log_error "Failed to install dependencies. Check $deps_log"; return 1; }
    echo
}

# Download source files
download_sources() {
    log_step "Downloading source files"
    echo
    
    mkdir -p "$BUILD_DIR" && cd "$BUILD_DIR" || return 1
    
    local sources=(
        "OpenSSL $OPENSSL_VERSION|https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz"
        "PCRE2 $PCRE2_VERSION|https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${PCRE2_VERSION}/pcre2-${PCRE2_VERSION}.tar.gz"
        "zlib $ZLIB_VERSION|https://zlib.net/zlib-${ZLIB_VERSION}.tar.gz"
        "NGINX $NGINX_VERSION|https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz"
    )
    
    for source in "${sources[@]}"; do
        IFS='|' read -r name url <<< "$source"
        log_detail "Downloading $name"
        
        # Download with quiet mode and no progress bar
        if ! wget -q --no-verbose "$url" 2>/dev/null; then
            log_error "Failed to download $name"
            return 1
        fi
        
        # Extract quietly
        tar xf "$(basename "$url")" 2>/dev/null || return 1
    done
    
    # Clone modules
    log_detail "Cloning GeoIP2 module"
    git clone --quiet --depth 1 --branch "$GEOIP2_MODULE_VERSION" \
        https://github.com/leev/ngx_http_geoip2_module.git 2>/dev/null || \
        { log_warn "Using master branch for GeoIP2"; git clone --quiet --depth 1 https://github.com/leev/ngx_http_geoip2_module.git 2>/dev/null; }
    
    log_detail "Cloning headers-more module"
    git clone --quiet --depth 1 --branch "v$HEADERS_MORE_MODULE_VERSION" \
        https://github.com/openresty/headers-more-nginx-module.git 2>/dev/null || \
        { log_warn "Using master branch for headers-more"; git clone --quiet --depth 1 https://github.com/openresty/headers-more-nginx-module.git 2>/dev/null; }
    
    echo
}

# Build OpenSSL
build_openssl() {
    log_step "Building OpenSSL $OPENSSL_VERSION"
    cd "$BUILD_DIR/openssl-${OPENSSL_VERSION}" || return 1
    
    local openssl_log="$LOG_DIR/openssl-build.log"
    
    {
        ./Configure linux-x86_64 \
            --prefix="$BUILD_DIR/openssl-install" \
            --openssldir="$BUILD_DIR/openssl-install/ssl" \
            enable-tls1_3 \
            enable-ec_nistp_64_gcc_128 \
            no-shared \
            no-tests \
            -fPIC \
            -O3 \
            -march=native && \
        make -j"$(nproc)" && \
        make install_sw
    } &>"$openssl_log" &
    
    spinner $! "Building OpenSSL"
    [ $? -eq 0 ] || { log_error "OpenSSL build failed. Check $openssl_log"; return 1; }
    
    cd "$BUILD_DIR" || return 1
    echo
}

# Build Zstd
build_zstd() {
    log_step "Building Zstd $ZSTD_VERSION"
    
    local zstd_log="$LOG_DIR/zstd-build.log"
    
    wget -q --no-verbose "https://github.com/facebook/zstd/releases/download/v${ZSTD_VERSION}/zstd-${ZSTD_VERSION}.tar.gz" 2>/dev/null || return 1
    tar xf "zstd-${ZSTD_VERSION}.tar.gz" 2>/dev/null || return 1
    cd "zstd-${ZSTD_VERSION}" || return 1
    
    {
        make -j"$(nproc)" CFLAGS="-fPIC -O3" && \
        make install PREFIX="$BUILD_DIR/zstd-install"
    } &>"$zstd_log" &
    
    spinner $! "Building Zstd"
    [ $? -eq 0 ] || { log_error "Zstd build failed. Check $zstd_log"; return 1; }
    
    cd "$BUILD_DIR" || return 1
    echo
}

# Configure and build nginx
build_nginx() {
    log_step "Configuring NGINX with custom modules"
    cd "$BUILD_DIR/nginx-${NGINX_VERSION}" || return 1
    
    # Clone Zstd module
    local ZSTD_MODULE_DIR="$BUILD_DIR/zstd-nginx-module"
    git clone --quiet --depth 1 --branch "$ZSTD_MODULE_VERSION" \
        https://github.com/tokers/zstd-nginx-module.git "$ZSTD_MODULE_DIR" 2>/dev/null || \
        { log_warn "Using master branch for Zstd module"; git clone --quiet --depth 1 https://github.com/tokers/zstd-nginx-module.git "$ZSTD_MODULE_DIR" 2>/dev/null; }
    
    # Set paths
    export CFLAGS="-I${BUILD_DIR}/openssl-install/include -I${BUILD_DIR}/zstd-install/include -O3 -march=native"
    export LDFLAGS="-L${BUILD_DIR}/openssl-install/lib64 -L${BUILD_DIR}/openssl-install/lib -L${BUILD_DIR}/zstd-install/lib"
    
    local config_log="$LOG_DIR/nginx-configure.log"
    
    {
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
            --with-pcre="$BUILD_DIR/pcre2-${PCRE2_VERSION}" \
            --with-pcre-jit \
            --with-zlib="$BUILD_DIR/zlib-${ZLIB_VERSION}" \
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
            --add-dynamic-module=../ngx_http_geoip2_module \
            --add-dynamic-module=../headers-more-nginx-module \
            --add-dynamic-module="$ZSTD_MODULE_DIR" \
            --with-cc-opt="-O3 -march=native -mtune=native -fstack-protector-strong" \
            --with-ld-opt="$LDFLAGS"
    } &>"$config_log" &
    
    spinner $! "Configuring NGINX"
    [ $? -eq 0 ] || { log_error "Configuration failed. Check $config_log"; return 1; }
    
    echo
    log_step "Building NGINX"
    
    local build_log="$LOG_DIR/nginx-build.log"
    make -j"$(nproc)" &>"$build_log" &
    spinner $! "Compiling NGINX"
    [ $? -eq 0 ] || { log_error "Build failed. Check $build_log"; return 1; }
    
    make install &>"$LOG_DIR/nginx-install.log" &
    spinner $! "Installing NGINX"
    [ $? -eq 0 ] || { log_error "Installation failed"; return 1; }
    
    echo
}

# Setup system configuration
setup_system() {
    log_step "Setting up system configuration"
    
    # Create nginx user
    if ! id nginx >/dev/null 2>&1; then
        useradd --system --home /var/cache/nginx --shell /sbin/nologin --comment "nginx user" nginx
        log_detail "Created nginx user"
    fi
    
    # Create directories
    local dirs=(
        "/var/cache/nginx/client_temp"
        "/var/cache/nginx/proxy_temp"
        "/var/cache/nginx/fastcgi_temp"
        "/var/cache/nginx/uwsgi_temp"
        "/var/cache/nginx/scgi_temp"
        "/var/log/nginx"
        "/etc/nginx/conf.d"
        "/etc/nginx/snippets"
        "/etc/nginx/modules"
        "/usr/share/nginx/html"
    )
    
    for dir in "${dirs[@]}"; do
        mkdir -p "$dir"
    done
    
    # Copy modules
    cd "$BUILD_DIR/nginx-${NGINX_VERSION}" || return 1
    local modules=(
        "ngx_http_zstd_filter_module.so"
        "ngx_http_geoip2_module.so"
        "ngx_stream_geoip2_module.so"
        "ngx_http_headers_more_filter_module.so"
    )
    
    for module in "${modules[@]}"; do
        if [ -f "objs/$module" ]; then
            cp "objs/$module" /etc/nginx/modules/
            log_detail "Installed $module"
        fi
    done
    
    # Set permissions
    chown -R nginx:nginx /var/cache/nginx /var/log/nginx
    chmod 755 /var/cache/nginx /var/log/nginx
    
    # Create configuration files
    create_nginx_config
    create_systemd_service
    create_sysctl_config
    
    # Generate DH parameters (in background, don't wait)
    log_detail "Generating DH parameters (will complete in background)"
    nohup openssl dhparam -out /etc/nginx/dhparam.pem 2048 &>/dev/null &
    
    echo
}

# Create nginx configuration
create_nginx_config() {
    # Check if Zstd module was built
    local ZSTD_AVAILABLE=0
    if [ -f "/etc/nginx/modules/ngx_http_zstd_filter_module.so" ]; then
        ZSTD_AVAILABLE=1
    fi
    
    cat > /etc/nginx/nginx.conf << 'EOF'
# Load dynamic modules
load_module modules/ngx_http_geoip2_module.so;
load_module modules/ngx_http_headers_more_filter_module.so;
EOF

    if [ $ZSTD_AVAILABLE -eq 1 ]; then
        echo "load_module modules/ngx_http_zstd_filter_module.so;" >> /etc/nginx/nginx.conf
    fi

    cat >> /etc/nginx/nginx.conf << 'EOF'

user nginx;
worker_processes auto;
worker_cpu_affinity auto;
worker_rlimit_nofile 65535;
error_log /var/log/nginx/error.log warn;
pid /run/nginx.pid;

events {
    worker_connections 65535;
    use epoll;
    multi_accept on;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" "$http_x_forwarded_for"';

    access_log /var/log/nginx/access.log main;

    # Performance settings
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    
    # Compression
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types text/plain text/css text/xml application/json application/javascript 
               application/xml+rss application/atom+xml image/svg+xml;
EOF

    if [ $ZSTD_AVAILABLE -eq 1 ]; then
        cat >> /etc/nginx/nginx.conf << 'EOF'
    
    # Zstd compression
    zstd on;
    zstd_comp_level 3;
    zstd_types text/plain text/css text/xml application/json application/javascript 
               application/xml+rss application/atom+xml image/svg+xml;
EOF
    fi

    cat >> /etc/nginx/nginx.conf << 'EOF'

    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    
    # Hide NGINX version and force a plain "nginx" Server header
    server_tokens off;
    more_clear_headers 'Server';
    more_set_headers   'Server: nginx';

    # SSL Configuration
    ssl_protocols       TLSv1.2 TLSv1.3;
    
    # Top-5 TLS 1.2 ciphers (server-preferred)
    ssl_ciphers ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-GCM-SHA256;
    ssl_prefer_server_ciphers on;

    # Top-5 TLS 1.3 ciphers
    ssl_conf_command    Ciphersuites TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:TLS_AES_128_GCM_SHA256:TLS_AES_128_CCM_SHA256:TLS_AES_128_CCM_8_SHA256;
    ssl_session_cache shared:SSL:50m;
    ssl_session_timeout 1d;
    
    # Include additional configurations
    include /etc/nginx/conf.d/*.conf;
    
    # Default server
    server {
        listen 80 default_server;
        listen [::]:80 default_server;
        server_name _;
        root /usr/share/nginx/html;
        
        location / {
            index index.html index.htm;
        }
    }
}
EOF

    # Create default index.html
    cat > /usr/share/nginx/html/index.html << 'EOF'
<!DOCTYPE html>
<html>
<head>
    <title>Welcome to NGINX</title>
    <style>
        body {
            width: 35em;
            margin: 0 auto;
            font-family: Tahoma, Verdana, Arial, sans-serif;
        }
    </style>
</head>
<body>
    <h1>Welcome to NGINX!</h1>
    <p>If you see this page, the web server is successfully installed and working.</p>
</body>
</html>
EOF
}

# Create systemd service
create_systemd_service() {
    cat > /etc/systemd/system/nginx.service << 'EOF'
[Unit]
Description=The NGINX HTTP and reverse proxy server
After=network.target remote-fs.target nss-lookup.target

[Service]
Type=forking
PIDFile=/run/nginx.pid
ExecStartPre=/usr/sbin/nginx -t
ExecStart=/usr/sbin/nginx
ExecReload=/usr/sbin/nginx -s reload
ExecStop=/bin/kill -s QUIT $MAINPID
PrivateTmp=true
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable nginx &>/dev/null
}

# Create sysctl configuration
create_sysctl_config() {
    cat > /etc/sysctl.d/99-nginx-performance.conf << 'EOF'
# NGINX Performance Tuning
net.core.somaxconn = 65535
net.ipv4.tcp_max_tw_buckets = 1440000
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_keepalive_intvl = 15
EOF
    
    sysctl -p /etc/sysctl.d/99-nginx-performance.conf &>/dev/null
}

# Start nginx service
start_nginx() {
    log_step "Starting NGINX service"
    
    if nginx -t &>/dev/null; then
        systemctl start nginx
        if systemctl is-active nginx &>/dev/null; then
            log_success "NGINX started successfully"
        else
            log_error "Failed to start NGINX"
            return 1
        fi
    else
        log_error "Configuration test failed"
        nginx -t
        return 1
    fi
    echo
}

# Show installation summary
show_summary() {
    echo
    echo -e "${BOLD}Installation Summary${NC}"
    echo -e "${GRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    # Check if nginx is actually available now
    if command -v nginx >/dev/null 2>&1; then
        local nginx_version=$(nginx -v 2>&1 | grep -o 'nginx/[0-9.]*')
        local openssl_version=$(nginx -V 2>&1 | grep -o 'built with OpenSSL [0-9.]*' | cut -d' ' -f4)
        
        echo -e "${GREEN}✓${NC} NGINX ${CYAN}$nginx_version${NC} installed"
        echo -e "${GREEN}✓${NC} OpenSSL ${CYAN}$openssl_version${NC} with HTTP/3 support"
    else
        echo -e "${YELLOW}!${NC} NGINX binary not found in PATH. Try: ${CYAN}hash -r${NC} to refresh your shell"
        echo -e "${YELLOW}!${NC} Manual check: ${CYAN}/usr/sbin/nginx -v${NC}"
    fi
    
    # Check feature availability
    if [ -f "/etc/nginx/modules/ngx_http_zstd_filter_module.so" ]; then
        echo -e "${GREEN}✓${NC} Zstd compression enabled"
    else
        echo -e "${YELLOW}!${NC} Zstd compression not available"
    fi
    
    echo -e "${GREEN}✓${NC} GeoIP2 module installed"
    echo -e "${GREEN}✓${NC} Headers More module installed"
    echo
    
    # Status check
    if systemctl is-active nginx &>/dev/null; then
        echo -e "${GREEN}✓${NC} NGINX service is ${GREEN}running${NC}"
    else
        echo -e "${YELLOW}!${NC} NGINX service is ${YELLOW}not running${NC}"
        echo -e "   Check with: ${CYAN}sudo systemctl status nginx${NC}"
        
        # Check for common issues
        if ss -tuln | grep -q ":80 "; then
            echo -e "   ${YELLOW}Port 80 is already in use by another process!${NC}"
            echo -e "   Find it with: ${CYAN}sudo lsof -i :80${NC}"
        fi
    fi
    echo
    
    # Component version table
    echo -e "${BOLD}Installed Components & Versions${NC}"
    echo -e "${GRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo
    printf "%-30s %-20s %-50s\n" "Component" "Version" "Source"
    printf "%-30s %-20s %-50s\n" "nginx" "$NGINX_VERSION" "https://nginx.org/"
    printf "%-30s %-20s %-50s\n" "OpenSSL" "$OPENSSL_VERSION" "https://github.com/openssl/openssl"
    printf "%-30s %-20s %-50s\n" "PCRE2" "$PCRE2_VERSION" "https://github.com/PCRE2Project/pcre2"
    printf "%-30s %-20s %-50s\n" "zlib" "$ZLIB_VERSION" "https://zlib.net/"
    printf "%-30s %-20s %-50s\n" "Zstandard" "$ZSTD_VERSION" "https://github.com/facebook/zstd"
    printf "%-30s %-20s %-50s\n" "ngx_http_zstd_module" "$ZSTD_MODULE_VERSION" "https://github.com/tokers/zstd-nginx-module"
    printf "%-30s %-20s %-50s\n" "ngx_http_geoip2_module" "$GEOIP2_MODULE_VERSION" "https://github.com/leev/ngx_http_geoip2_module"
    printf "%-30s %-20s %-50s\n" "headers-more-nginx-module" "$HEADERS_MORE_MODULE_VERSION" "https://github.com/openresty/headers-more-nginx-module"
    echo
    
    echo -e "${BOLD}Quick Start Guide${NC}"
    echo -e "${GRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo
    echo -e "  ${BOLD}Configuration files:${NC}"
    echo -e "  ${GRAY}•${NC} Main config: ${CYAN}/etc/nginx/nginx.conf${NC}"
    echo -e "  ${GRAY}•${NC} Site configs: ${CYAN}/etc/nginx/conf.d/*.conf${NC}"
    echo
    echo -e "  ${BOLD}Useful commands:${NC}"
    echo -e "  ${GRAY}•${NC} Test config: ${CYAN}sudo nginx -t${NC}"
    echo -e "  ${GRAY}•${NC} Reload: ${CYAN}sudo systemctl reload nginx${NC}"
    echo -e "  ${GRAY}•${NC} Status: ${CYAN}sudo systemctl status nginx${NC}"
    echo -e "  ${GRAY}•${NC} Logs: ${CYAN}sudo tail -f /var/log/nginx/error.log${NC}"
    echo
    echo -e "  ${BOLD}Next steps:${NC}"
    echo -e "  ${GRAY}1.${NC} Create your site config in ${CYAN}/etc/nginx/conf.d/${NC}"
    echo -e "  ${GRAY}2.${NC} Get SSL certificates (e.g., Let's Encrypt)"
    echo -e "  ${GRAY}3.${NC} Configure your domains and applications"
    echo
    echo -e "${GRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo
}

# Verify installation
verify_nginx() {
    print_header
    log_step "Verifying NGINX installation"
    echo
    
    local checks=(
        "nginx binary:command -v nginx"
        "configuration:nginx -t"
        "service status:systemctl is-active nginx"
        "modules directory:ls /etc/nginx/modules/"
        "port 80 availability:! ss -tuln | grep -q ':80 ' || systemctl is-active nginx"
    )
    
    for check in "${checks[@]}"; do
        IFS=':' read -r name cmd <<< "$check"
        if eval "$cmd" &>/dev/null; then
            log_success "$name"
        else
            log_error "$name"
        fi
    done
    
    echo
    log_info "NGINX version details:"
    nginx -V 2>&1 | grep -E "(nginx version|built with|configure arguments)" | sed 's/^/  /' | fold -s -w 80
    echo
}

# Main installation function
install_nginx() {
    print_header
    free_ports
    # Check for existing installation and remove it
    if command -v nginx >/dev/null 2>&1 || [ -f "/usr/sbin/nginx" ] || [ -f "/etc/nginx/nginx.conf" ] || pgrep -f nginx >/dev/null; then
        log_warn "Existing NGINX installation detected"
        log_info "Removing existing installation first..."
        # Directly call remove_nginx function
        remove_nginx
        
        # Verify removal success
        if pgrep -x nginx >/dev/null; then
            log_error "Unable to remove existing NGINX processes. Please reboot and try again."
            exit 1
        fi
    fi
    
    # Installation steps
    install_dependencies || exit 1
    download_sources || exit 1
    build_openssl || exit 1
    build_zstd || exit 1
    build_nginx || exit 1
    setup_system || exit 1
    
    # Check if port 80 is already in use before starting
    if ! check_port_80; then
        log_warn "NGINX installed but NOT started due to port conflict."
    else
        start_nginx || log_warn "Failed to start NGINX, but installation completed."
    fi
    
    # Cleanup
    cd / && rm -rf "$BUILD_DIR"
    
    show_summary
}

# Main script
main() {
    check_root
    
    case "${1:-}" in
        install|reinstall)
            install_nginx
            ;;
        remove|uninstall)
            remove_nginx
            ;;
        verify|check)
            verify_nginx
            ;;
        *)
            print_header
            echo -e "${BOLD}Usage:${NC} $0 [install|remove|verify]"
            echo
            echo -e "  ${CYAN}install${NC}  - Install NGINX with custom modules"
            echo -e "  ${CYAN}remove${NC}   - Remove NGINX installation"
            echo -e "  ${CYAN}verify${NC}   - Verify NGINX installation"
            echo
            
            # Auto-detect if nginx is installed
            if command -v nginx >/dev/null 2>&1; then
                local nginx_version=$(nginx -v 2>&1 | grep -o 'nginx/[0-9.]*' | cut -d'/' -f2)
                echo -e "${YELLOW}Existing NGINX $nginx_version detected${NC}"
                echo
            fi
            
            # Show local execution help
            echo -e "${BOLD}Local execution:${NC}"
            echo -e "  ${GRAY}•${NC} Make executable: ${CYAN}chmod +x nginx_installer.sh${NC}"
            echo -e "  ${GRAY}•${NC} Run: ${CYAN}sudo ./nginx_installer.sh install${NC}"
            echo
            
            exit 1
            ;;
    esac
}

# Run main function
main "$@"
