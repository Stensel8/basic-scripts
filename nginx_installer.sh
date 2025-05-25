#!/usr/bin/env bash
#########################################################################
# NGINX 1.28.0 with Custom OpenSSL 3.5.0, Zstd & GeoIP2 Installer
# Compiles nginx with latest OpenSSL for HTTP/3 + Zstd + GeoIP2
#########################################################################

set -euo pipefail

NGINX_VERSION="1.28.0"
OPENSSL_VERSION="3.5.0"
PCRE2_VERSION="10.44"
ZLIB_VERSION="1.3.1"
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
    local frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)

    while kill -0 "$pid" 2>/dev/null; do
        for frame in "${frames[@]}"; do
            printf "\r[%s] " "$frame"
            sleep "$delay"
        done
    done
    printf "\r    \r"
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
    log_info "Removing existing nginx installation…"

    # detect non-interactive (e.g. piped)
    local NONINT=0
    if ! [ -t 0 ]; then NONINT=1; fi

    # 1) Purge distro packages
    if command -v apt >/dev/null 2>&1; then
        log_info "Purging Debian/Ubuntu package…"
        DEBIAN_FRONTEND=noninteractive apt remove --purge -y nginx nginx-* || true
        DEBIAN_FRONTEND=noninteractive apt autoremove -y || true
    fi
    if command -v dnf >/dev/null 2>&1; then
        log_info "Removing Fedora/RHEL package…"
        dnf remove -y nginx nginx-* || true
        dnf autoremove -y || true
    fi
    if command -v brew >/dev/null 2>&1; then
        log_info "Uninstalling Homebrew nginx…"
        brew uninstall nginx || true
    fi
    if command -v snap >/dev/null 2>&1; then
        log_info "Removing Snap nginx…"
        snap remove nginx || true
    fi

    # 2) Stop & disable any service
    log_info "Stopping and disabling services…"
    systemctl stop nginx.service nginx.socket 2>/dev/null || true
    systemctl disable nginx.service nginx.socket 2>/dev/null || true
    service nginx stop 2>/dev/null || true

    # reload systemd to clear stale units
    systemctl daemon-reload

    # 3) Remove binaries (known and discovered)
    log_info "Deleting nginx binaries…"
    rm -f /usr/sbin/nginx /usr/bin/nginx /usr/local/sbin/nginx
    for bin in $(which nginx 2>/dev/null); do rm -f "$bin"; done

    # 4) Remove configs
    if [ $NONINT -eq 1 ]; then
        log_info "Non-interactive: removing all config under /etc/nginx and /usr/local/etc/nginx"
        rm -rf /etc/nginx /usr/local/etc/nginx
    else
        read -p "Remove /etc/nginx and /usr/local/etc/nginx? (y/N): " -n1 -r; echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            rm -rf /etc/nginx /usr/local/etc/nginx
            log_info "Configs removed"
        else
            log_warn "Configs left in place"
        fi
    fi

    # 5) Clean up logs, cache, build dirs, GeoIP data
    log_info "Removing logs, cache, build dirs, and GeoIP data…"
    rm -rf /var/log/nginx /var/cache/nginx "$BUILD_DIR" /opt/nginx* /usr/local/nginx
    rm -rf /usr/local/share/GeoIP /etc/nginx/GeoIP.conf

    # 6) Kill stray processes
    log_info "Killing lingering nginx processes…"
    pkill -x nginx 2>/dev/null || true

    # 7) Remove nginx user/group
    log_info "Removing nginx user/group…"
    userdel nginx 2>/dev/null || true
    groupdel nginx 2>/dev/null || true

    log_success "Nginx removal completed!"
    exit 0
}

# Function to install nginx with custom OpenSSL, Zstd and GeoIP2
install_nginx() {
    log_info "Installing Nginx $NGINX_VERSION with OpenSSL $OPENSSL_VERSION, Zstd & GeoIP2"

    # Install build dependencies
    log_info "Installing build dependencies..."
    if command -v dnf >/dev/null 2>&1; then
        # Fedora/RHEL/CentOS
        if dnf --version 2>/dev/null | grep -q "dnf5"; then
            dnf install -y @development-tools >/dev/null 2>&1
            dnf install -y pcre2-devel zlib-devel perl wget gcc make git \
                libmaxminddb-devel libzstd-devel >/dev/null 2>&1
        else
            dnf groupinstall -y "Development Tools" >/dev/null 2>&1 || true
            dnf install -y pcre2-devel zlib-devel perl wget gcc make git \
                libmaxminddb-devel libzstd-devel >/dev/null 2>&1
        fi
    elif command -v apt >/dev/null 2>&1; then
        # Ubuntu/Debian
        export DEBIAN_FRONTEND=noninteractive
        apt update >/dev/null 2>&1
        apt install -y build-essential libpcre2-dev zlib1g-dev perl wget gcc make git \
            libmaxminddb-dev mmdb-bin libzstd-dev >/dev/null 2>&1
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

    # Download PCRE2 source
    log_info "Downloading PCRE2 $PCRE2_VERSION..."
    wget -q "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${PCRE2_VERSION}/pcre2-${PCRE2_VERSION}.tar.gz"
    tar xf "pcre2-${PCRE2_VERSION}.tar.gz"

    # Download zlib source
    log_info "Downloading zlib $ZLIB_VERSION..."
    wget -q "https://zlib.net/zlib-${ZLIB_VERSION}.tar.gz"
    tar xf "zlib-${ZLIB_VERSION}.tar.gz"

    # Download nginx source
    log_info "Downloading nginx $NGINX_VERSION source..."
    wget -q "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz"
    tar xf "nginx-${NGINX_VERSION}.tar.gz"

    # Clone Zstd nginx module
    log_info "Cloning zstd-nginx-module..."
    git clone --depth 1 https://github.com/tokers/zstd-nginx-module.git >/dev/null 2>&1

    # Clone GeoIP2 module
    log_info "Cloning ngx_http_geoip2_module..."
    git clone --depth 1 https://github.com/leev/ngx_http_geoip2_module.git >/dev/null 2>&1

    # Clone headers-more module for complete server header hiding
    log_info "Cloning headers-more-nginx-module..."
    git clone --depth 1 https://github.com/openresty/headers-more-nginx-module.git >/dev/null 2>&1

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

    # Configure nginx with custom OpenSSL, Zstd and GeoIP2
    log_info "Configuring nginx with custom OpenSSL, Zstd & GeoIP2..."
    cd "nginx-${NGINX_VERSION}"

    # Set OpenSSL paths
    OPENSSL_PATH="$BUILD_DIR/openssl-install"
    export CFLAGS="-I${OPENSSL_PATH}/include -O3 -march=native"
    export LDFLAGS="-L${OPENSSL_PATH}/lib64 -L${OPENSSL_PATH}/lib -lzstd"

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
        --add-dynamic-module=../zstd-nginx-module \
        --add-dynamic-module=../ngx_http_geoip2_module \
        --add-dynamic-module=../headers-more-nginx-module \
        --with-cc-opt="-O3 -march=native -mtune=native -fstack-protector-strong" \
        --with-ld-opt="-Wl,-z,relro -Wl,-z,now -lzstd" >/dev/null 2>&1

    # Build nginx
    log_info "Building nginx with custom OpenSSL, Zstd & GeoIP2 (this may take several minutes)..."
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
    mkdir -p /etc/nginx/{conf.d,snippets,modules}
    mkdir -p /usr/local/share/GeoIP

    # Copy dynamic modules
    log_info "Installing dynamic modules..."
    if [ -f objs/ngx_http_zstd_filter_module.so ]; then
        cp objs/ngx_http_zstd_filter_module.so /etc/nginx/modules/
        log_success "Copied zstd filter module"
    else
        log_warn "zstd filter module not found in objs/"
    fi
    
    if [ -f objs/ngx_http_zstd_static_module.so ]; then
        cp objs/ngx_http_zstd_static_module.so /etc/nginx/modules/
        log_success "Copied zstd static module"
    else
        log_warn "zstd static module not found in objs/"
    fi
    
    if [ -f objs/ngx_http_geoip2_module.so ]; then
        cp objs/ngx_http_geoip2_module.so /etc/nginx/modules/
        log_success "Copied GeoIP2 HTTP module"
    else
        log_warn "GeoIP2 HTTP module not found in objs/"
    fi
    
    if [ -f objs/ngx_stream_geoip2_module.so ]; then
        cp objs/ngx_stream_geoip2_module.so /etc/nginx/modules/
        log_success "Copied GeoIP2 stream module"
    else
        log_info "GeoIP2 stream module not built (normal if stream not configured)"
    fi
    
    if [ -f objs/ngx_http_headers_more_filter_module.so ]; then
        cp objs/ngx_http_headers_more_filter_module.so /etc/nginx/modules/
        log_success "Copied headers-more module"
    else
        log_warn "headers-more module not found in objs/"
    fi

    # Set permissions
    chown -R nginx:nginx /var/cache/nginx /var/log/nginx
    chmod 755 /var/cache/nginx /var/log/nginx

    # Create basic nginx configuration with modules
    log_info "Creating basic nginx configuration..."
    cat > /etc/nginx/nginx.conf << 'EOF'
# Load dynamic modules
load_module modules/ngx_http_zstd_filter_module.so;
load_module modules/ngx_http_zstd_static_module.so;
load_module modules/ngx_http_geoip2_module.so;
load_module modules/ngx_http_headers_more_filter_module.so;
# load_module modules/ngx_stream_geoip2_module.so; # Uncomment if using stream

user nginx;
worker_processes auto;
worker_cpu_affinity auto;
worker_rlimit_nofile 65535;
error_log /var/log/nginx/error.log warn;
pid /run/nginx.pid;

# Load balance between CPU cores
thread_pool default threads=32 max_queue=65536;

events {
    worker_connections 65535;
    use epoll;
    multi_accept on;
    accept_mutex off;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" "$http_x_forwarded_for" '
                    'rt=$request_time uct="$upstream_connect_time" '
                    'uht="$upstream_header_time" urt="$upstream_response_time"';

    access_log /var/log/nginx/access.log main;

    # Performance optimizations
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    keepalive_requests 1000;
    reset_timedout_connection on;
    client_body_timeout 10;
    send_timeout 2;
    
    # Optimize buffer sizes
    client_body_buffer_size 128k;
    client_max_body_size 10m;
    client_header_buffer_size 1k;
    large_client_header_buffers 4 16k;
    output_buffers 1 32k;
    postpone_output 1460;

    # Enable open file cache
    open_file_cache max=200000 inactive=20s;
    open_file_cache_valid 30s;
    open_file_cache_min_uses 2;
    open_file_cache_errors on;

    # Gzip compression
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types text/plain text/css text/xml application/json application/javascript 
               application/xml+rss application/atom+xml image/svg+xml;
    gzip_disable "msie6";

    # Zstd compression - Better than Brotli!
    zstd on;
    zstd_comp_level 3;  # 1-19, higher = better compression but slower
    zstd_types text/plain text/css text/xml application/json application/javascript 
               application/xml+rss application/atom+xml image/svg+xml
               application/x-font-ttf application/x-font-opentype application/vnd.ms-fontobject
               image/x-icon font/opentype text/javascript application/x-javascript;

    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "no-referrer-when-downgrade" always;
    add_header Content-Security-Policy "default-src 'self' http: https: data: blob: 'unsafe-inline'" always;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;
    add_header Permissions-Policy "camera=(), microphone=(), geolocation=(), interest-cohort=()" always;

    # Hide nginx version
    server_tokens off;
    more_clear_headers 'Server';
    more_clear_headers 'X-Powered-By';
    
    # Set custom server header (optional - comment out for no header at all)
    # more_set_headers 'Server: Web Server';

    # SSL Configuration
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    
    # SSL session cache
    ssl_session_cache shared:SSL:50m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;
    
    # SSL OCSP stapling
    ssl_stapling on;
    ssl_stapling_verify on;
    resolver 1.1.1.1 1.0.0.1 8.8.8.8 8.8.4.4 valid=300s;
    resolver_timeout 5s;
    
    # DH parameters (generate with: openssl dhparam -out /etc/nginx/dhparam.pem 4096)
    # ssl_dhparam /etc/nginx/dhparam.pem;
    
    # Enable HSTS
    map $scheme $hsts_header {
        https "max-age=31536000; includeSubDomains; preload";
    }

    # Rate limiting zones
    limit_req_zone $binary_remote_addr zone=general:10m rate=10r/s;
    limit_req_zone $binary_remote_addr zone=api:10m rate=100r/s;
    limit_conn_zone $binary_remote_addr zone=addr:10m;

    # Include additional configurations
    include /etc/nginx/conf.d/*.conf;

    # Default HTTP server - redirect all to HTTPS when SSL is configured
    server {
        listen 80 default_server;
        listen [::]:80 default_server;
        server_name _;
        root /usr/share/nginx/html;
        
        location / {
            index index.html index.htm;
            try_files $uri $uri/ =404;
        }
        
        location = /404.html {
            internal;
        }

        error_page 404 /404.html;
        error_page 500 502 503 504 /50x.html;
        location = /50x.html {
            root /usr/share/nginx/html;
        }
    }
}
EOF

    # Create example GeoIP2 configuration
    cat > /etc/nginx/conf.d/geoip2.conf.example << 'EOF'
# GeoIP2 configuration example
# Uncomment and configure after adding your MaxMind license to /etc/nginx/GeoIP.conf

# geoip2 /usr/local/share/GeoIP/GeoLite2-Country.mmdb {
#     auto_reload 60m;
#     $geoip2_metadata_country_build metadata build_epoch;
#     $geoip2_data_country_code country iso_code;
#     $geoip2_data_country_name country names en;
# }

# geoip2 /usr/local/share/GeoIP/GeoLite2-City.mmdb {
#     auto_reload 60m;
#     $geoip2_metadata_city_build metadata build_epoch;
#     $geoip2_data_city_name city names en;
#     $geoip2_data_city_geoname_id city geoname_id;
#     $geoip2_data_continent_code continent code;
#     $geoip2_data_continent_name continent names en;
#     $geoip2_data_location_latitude location latitude;
#     $geoip2_data_location_longitude location longitude;
#     $geoip2_data_location_timezone location time_zone;
#     $geoip2_data_postal_code postal code;
# }
EOF

    # Create GeoIP.conf template
    cat > /etc/nginx/GeoIP.conf.example << 'EOF'
# MaxMind GeoIP.conf Template
# Get your license from https://www.maxmind.com/en/my_license_key
# Rename this file to GeoIP.conf after adding your credentials

AccountID YOUR_ACCOUNT_ID
LicenseKey YOUR_LICENSE_KEY
EditionIDs GeoLite2-City GeoLite2-Country
EOF

    # Create example SSL site configuration
    cat > /etc/nginx/conf.d/example-ssl.conf.disabled << 'EOF'
# Example SSL configuration with HTTP/2 and HTTP/3
# Rename to example-ssl.conf and update with your domain and certificates

server {
    listen 80;
    listen [::]:80;
    server_name example.com www.example.com;
    
    # Redirect all HTTP to HTTPS
    location / {
        return 301 https://$server_name$request_uri;
    }
    
    # ACME challenge for Let's Encrypt
    location /.well-known/acme-challenge/ {
        root /var/www/letsencrypt;
    }
}

server {
    # SSL configuration
    listen 443 ssl;
    listen [::]:443 ssl;
    
    # HTTP/2
    http2 on;
    
    # HTTP/3 / QUIC
    listen 443 quic reuseport;
    listen [::]:443 quic reuseport;
    http3 on;
    
    server_name example.com www.example.com;
    root /var/www/example.com;
    index index.html index.htm index.php;
    
    # SSL certificates
    ssl_certificate /etc/nginx/ssl/example.com/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/example.com/privkey.pem;
    ssl_trusted_certificate /etc/nginx/ssl/example.com/chain.pem;
    
    # Enable early data (0-RTT)
    ssl_early_data on;
    
    # Add headers
    add_header Alt-Svc 'h3=":443"; ma=86400' always;
    add_header X-Early-Data $ssl_early_data;
    
    # QUIC retry
    quic_retry on;
    
    # Rate limiting
    limit_req zone=general burst=20 nodelay;
    limit_conn addr 50;
    
    location / {
        try_files $uri $uri/ =404;
    }
    
    # PHP-FPM configuration (if needed)
    # location ~ \.php$ {
    #     fastcgi_pass unix:/var/run/php/php8.1-fpm.sock;
    #     fastcgi_index index.php;
    #     fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
    #     include fastcgi_params;
    # }
    
    # Deny access to hidden files
    location ~ /\. {
        deny all;
        access_log off;
        log_not_found off;
    }
}
EOF

    # Create a default HTTPS configuration (disabled by default)
    cat > /etc/nginx/conf.d/default-ssl.conf.disabled << 'EOF'
# Default HTTPS server with HTTP/2 and HTTP/3
# This will be used when you have SSL certificates
# To enable: mv default-ssl.conf.disabled default-ssl.conf

server {
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;
    
    # HTTP/2
    http2 on;
    
    # HTTP/3 / QUIC
    listen 443 quic reuseport default_server;
    listen [::]:443 quic reuseport default_server;
    http3 on;
    
    # Add Alt-Svc header to advertise HTTP/3
    add_header Alt-Svc 'h3=":443"; ma=86400' always;
    
    # QUIC retry
    quic_retry on;
    
    # SSL certificate paths (you need to add your own certificates)
    ssl_certificate /etc/nginx/ssl/default/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/default/privkey.pem;
    
    server_name _;
    root /usr/share/nginx/html;

    # Early data
    ssl_early_data on;
    
    # Rate limiting
    limit_req zone=general burst=20 nodelay;
    limit_conn addr 50;

    location / {
        index index.html index.htm;
        try_files $uri $uri/ =404;
    }

    location = /404.html {
        internal;
    }

    error_page 404 /404.html;
    error_page 500 502 503 504 /50x.html;
    location = /50x.html {
        root /usr/share/nginx/html;
    }
}
EOF

    # Create HTML directories
    mkdir -p /usr/share/nginx/html
    
    # Generate DH parameters for better SSL security
    log_info "Generating DH parameters (this may take a few minutes)..."
    openssl dhparam -out /etc/nginx/dhparam.pem 2048 >/dev/null 2>&1 &
    spinner $!
    
    # Create SSL directory
    mkdir -p /etc/nginx/ssl
    
    # Create default index.html
    cat > /usr/share/nginx/html/index.html << 'EOF'
<!DOCTYPE html>
<html>
<head>
    <title>Welcome!</title>
    <style>
        body {
            width: 35em;
            margin: 0 auto;
            font-family: Tahoma, Verdana, Arial, sans-serif;
        }
    </style>
</head>
<body>
<h1>Welcome!</h1>
<p>If you see this page, the web server is successfully installed and working.</p>
</body>
</html>
EOF

    # Create custom error pages without nginx branding
    cat > /usr/share/nginx/html/404.html << 'EOF'
<!DOCTYPE html>
<html>
<head>
    <title>404 Not Found</title>
    <style>
        body {
            width: 35em;
            margin: 0 auto;
            font-family: Tahoma, Verdana, Arial, sans-serif;
        }
    </style>
</head>
<body>
<h1>404 Not Found</h1>
<p>The requested resource was not found on this server.</p>
</body>
</html>
EOF

    cat > /usr/share/nginx/html/50x.html << 'EOF'
<!DOCTYPE html>
<html>
<head>
    <title>Server Error</title>
    <style>
        body {
            width: 35em;
            margin: 0 auto;
            font-family: Tahoma, Verdana, Arial, sans-serif;
        }
    </style>
</head>
<body>
<h1>Server Error</h1>
<p>An error occurred. Please try again later.</p>
</body>
</html>
EOF

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

# Fix for file limit warning
LimitNOFILE=65535
LimitNPROC=65535

[Install]
WantedBy=multi-user.target
EOF

    # Also set system limits for nginx user
    log_info "Setting system limits for nginx user..."
    echo "nginx soft nofile 65535" >> /etc/security/limits.conf
    echo "nginx hard nofile 65535" >> /etc/security/limits.conf
    
    # Create sysctl config for better performance
    log_info "Optimizing system parameters..."
    cat > /etc/sysctl.d/99-nginx-performance.conf << 'EOF'
# Nginx Performance Tuning
net.core.somaxconn = 65535
net.ipv4.tcp_max_tw_buckets = 1440000
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_keepalive_intvl = 15
net.core.rmem_default = 31457280
net.core.rmem_max = 33554432
net.core.wmem_default = 31457280
net.core.wmem_max = 33554432
net.core.netdev_max_backlog = 65535
net.core.optmem_max = 25165824
net.ipv4.tcp_mem = 786432 1048576 26777216
net.ipv4.udp_mem = 65536 131072 262144
net.ipv4.tcp_rmem = 8192 87380 33554432
net.ipv4.udp_rmem_min = 16384
net.ipv4.tcp_wmem = 8192 65536 33554432
net.ipv4.udp_wmem_min = 16384
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_mtu_probing = 1
EOF
    
    # Apply sysctl settings
    sysctl -p /etc/sysctl.d/99-nginx-performance.conf >/dev/null 2>&1 || true

    # Reload systemd and enable service
    systemctl daemon-reload
    systemctl enable nginx >/dev/null 2>&1

    # Test configuration and start
    log_info "Testing nginx configuration..."
    if ! /usr/sbin/nginx -t >/dev/null 2>&1; then
        log_error "Nginx configuration test failed!"
        log_info "Showing detailed error:"
        /usr/sbin/nginx -t 2>&1 || true
        
        # Check if modules are loaded correctly
        log_info "Checking module files:"
        ls -la /etc/nginx/modules/ 2>&1 || true
        
        # Try without zstd first to isolate the issue
        log_info "Testing without zstd module..."
        cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.backup
        sed -i '/load_module.*zstd/d' /etc/nginx/nginx.conf
        sed -i '/zstd/d' /etc/nginx/nginx.conf
        
        if /usr/sbin/nginx -t >/dev/null 2>&1; then
            log_warn "Configuration works without zstd. Module issue detected."
            log_info "Proceeding without zstd for now..."
        else
            log_error "Configuration still fails without zstd module"
            mv /etc/nginx/nginx.conf.backup /etc/nginx/nginx.conf
            exit 1
        fi
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

    # Check Zstd support
    if /usr/sbin/nginx -V 2>&1 | grep -q "zstd-nginx-module"; then
        log_success "✓ Zstandard (zstd) compression support available"
    fi

    # Check GeoIP2 support
    if /usr/sbin/nginx -V 2>&1 | grep -q "ngx_http_geoip2_module"; then
        log_success "✓ GeoIP2 support available"
    fi

    log_info "Nginx is running and enabled for startup"
    log_info "Configuration files are in /etc/nginx/"
    log_info "You can check status with: sudo systemctl status nginx"

    # Show performance info
    log_info "Performance optimizations applied:"
    echo "  • Native CPU optimizations (-march=native -mtune=native)"
    echo "  • OpenSSL 3.5.0 with latest QUIC improvements"
    echo "  • Statically linked OpenSSL for better performance"
    echo "  • Zstandard compression (better than Brotli!)"
    echo "  • GeoIP2 module for geolocation features"
    echo "  • Stack protection and security hardening enabled"
    
    log_info "Next steps:"
    echo "  1. For GeoIP2: Add your MaxMind license to /etc/nginx/GeoIP.conf"
    echo "  2. For Zstd: Already configured and enabled in nginx.conf"
    echo "  3. Test compression: curl -H 'Accept-Encoding: zstd' http://localhost"
}

# New function to verify and debug nginx installation
verify_nginx() {
    log_info "Running NGINX installation verification..."
    
    # Check nginx binary
    log_info "Checking nginx binary..."
    if command -v nginx >/dev/null 2>&1; then
        log_success "nginx found at: $(which nginx)"
        nginx -v 2>&1 || true
    else
        log_error "nginx binary not found"
    fi

    # Check nginx configuration
    log_info "Checking nginx configuration syntax..."
    if [ -f /etc/nginx/nginx.conf ]; then
        log_success "nginx.conf found"
        # Test configuration with verbose output
        nginx -t -c /etc/nginx/nginx.conf 2>&1 || {
            log_error "Configuration test failed"
            log_info "Showing detailed error:"
            nginx -T 2>&1 | head -50
        }
    else
        log_error "nginx.conf not found at /etc/nginx/nginx.conf"
    fi

    # Check modules
    log_info "Checking installed modules..."
    if [ -d /etc/nginx/modules ]; then
        log_success "Modules directory found:"
        ls -la /etc/nginx/modules/
    else
        log_error "Modules directory not found"
    fi

    # Check nginx version details
    log_info "Checking nginx build details..."
    nginx -V 2>&1 || true

    # Check for zstd module specifically
    log_info "Checking for zstd module in build..."
    if nginx -V 2>&1 | grep -q "zstd-nginx-module"; then
        log_success "zstd module found in build"
    else
        log_warn "zstd module not found in build configuration"
    fi

    # Check permissions
    log_info "Checking permissions..."
    ls -la /var/log/nginx/ 2>/dev/null || log_error "/var/log/nginx not found"
    ls -la /var/cache/nginx/ 2>/dev/null || log_error "/var/cache/nginx not found"

    # Check systemd service
    log_info "Checking systemd service..."
    if systemctl is-enabled nginx >/dev/null 2>&1; then
        log_success "nginx service is enabled"
    else
        log_warn "nginx service is not enabled"
    fi

    # Try to get more info about the zstd module
    log_info "Checking zstd module configuration..."
    if [ -f /etc/nginx/modules/ngx_http_zstd_filter_module.so ]; then
        log_success "zstd filter module found"
        file /etc/nginx/modules/ngx_http_zstd_filter_module.so
        ldd /etc/nginx/modules/ngx_http_zstd_filter_module.so 2>&1 || true
    else
        log_error "zstd filter module not found"
    fi

    # Create a test configuration without zstd_vary
    log_info "Creating test configuration..."
    tee /tmp/nginx-test.conf > /dev/null << 'EOF'
load_module modules/ngx_http_zstd_filter_module.so;
load_module modules/ngx_http_zstd_static_module.so;

user nginx;
worker_processes 1;
error_log /var/log/nginx/error.log warn;
pid /run/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    # Test zstd without zstd_vary
    zstd on;
    zstd_comp_level 3;

    server {
        listen 80;
        server_name localhost;
        root /usr/share/nginx/html;
    }
}
EOF

    log_info "Testing minimal configuration..."
    nginx -t -c /tmp/nginx-test.conf 2>&1 || log_error "Minimal config also failed"

    # Cleanup
    rm -f /tmp/nginx-test.conf

    log_info "Verification complete!"
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
            verify|check|debug)
                ACTION="verify"
                ;;
            *)
                log_error "Unknown argument: $1"
                log_info "Usage: $0 [install|remove|verify]"
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
                    exit 0
                    ;;
                install)
                    log_info "Proceeding with installation (existing nginx will be removed first)..."
                    systemctl stop nginx 2>/dev/null || true
                    rm -f /usr/sbin/nginx /usr/bin/nginx
                    install_nginx
                    ;;
                verify)
                    verify_nginx
                    exit 0
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
                echo "3) Verify/Debug nginx installation"
                echo "4) Cancel and exit"
                echo
                read -p "Please choose (1/2/3/4): " -n 1 -r
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
                        verify_nginx
                        ;;
                    4)
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
                log_info "To verify/debug nginx installation:"
                echo "  curl -fsSL https://raw.githubusercontent.com/Stensel8/scripts/main/nginx_installer.sh | sudo bash -s verify"
                echo
                exit 1
            fi
        fi
    else
        # No nginx installed - proceed with installation
        log_info "No existing nginx installation detected"
        if [[ "$ACTION" == "remove" ]]; then
            exit 0
        elif [[ "$ACTION" == "verify" ]]; then
            log_error "No nginx installation found to verify"
            exit 1
        fi
        install_nginx
    fi
}

# Run main function
main "$@"
