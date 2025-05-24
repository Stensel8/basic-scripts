#!/usr/bin/env bash
#########################################################################
# NGINX 1.28.0 Source Installer for Fedora
# Compiles latest stable nginx with HTTP/3 support
#########################################################################

set -euo pipefail

NGINX_VERSION="1.28.0"
BUILD_DIR="/tmp/nginx-build-$$"
PREFIX="/usr/local/nginx"

log_info() { echo -e "\033[0;34m[INFO]\033[0m $1"; }
log_success() { echo -e "\033[0;32m[SUCCESS]\033[0m $1"; }
log_error() { echo -e "\033[0;31m[ERROR]\033[0m $1"; }

# Check root
if [ "$EUID" -ne 0 ]; then
    log_error "Run as root: sudo $0"
    exit 1
fi

log_info "Installing Nginx $NGINX_VERSION from source with HTTP/3"

# Remove existing nginx
log_info "Removing existing nginx..."
systemctl stop nginx 2>/dev/null || true
dnf remove -y nginx nginx-* 2>/dev/null || true

# Install build dependencies
log_info "Installing build dependencies..."
dnf groupinstall -y "Development Tools"
dnf install -y pcre2-devel zlib-devel openssl-devel wget

# Create build directory
mkdir -p "$BUILD_DIR" && cd "$BUILD_DIR"

# Download nginx source
log_info "Downloading nginx $NGINX_VERSION source..."
wget "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz"
wget "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz.asc"

# Verify signature (optional)
log_info "Extracting source..."
tar xf "nginx-${NGINX_VERSION}.tar.gz"
cd "nginx-${NGINX_VERSION}"

# Configure with modules including HTTP/3
log_info "Configuring build with HTTP/3 and modern modules..."
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
    --with-stream_ssl_preread_module

# Build
log_info "Building nginx (this may take several minutes)..."
make -j"$(nproc)"

# Install
log_info "Installing nginx..."
make install

# Create nginx user
log_info "Creating nginx user..."
useradd --system --home /var/cache/nginx --shell /sbin/nologin --comment "nginx user" --user-group nginx 2>/dev/null || true

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

# Create basic nginx.conf if it doesn't exist
if [ ! -f /etc/nginx/nginx.conf ]; then
    log_info "Creating basic nginx.conf..."
    cat > /etc/nginx/nginx.conf << 'EOF'
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log;
pid /run/nginx.pid;

events {
    worker_connections 1024;
}

http {
    log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
                      '$status $body_bytes_sent "$http_referer" '
                      '"$http_user_agent" "$http_x_forwarded_for"';

    access_log  /var/log/nginx/access.log  main;

    sendfile            on;
    tcp_nopush          on;
    tcp_nodelay         on;
    keepalive_timeout   65;
    types_hash_max_size 2048;

    include             /etc/nginx/mime.types;
    default_type        application/octet-stream;

    include /etc/nginx/conf.d/*.conf;

    server {
        listen       80 default_server;
        listen       [::]:80 default_server;
        server_name  _;
        root         /usr/share/nginx/html;

        location / {
            root   /usr/share/nginx/html;
            index  index.html index.htm;
        }

        error_page   500 502 503 504  /50x.html;
        location = /50x.html {
            root   /usr/share/nginx/html;
        }
    }
}
EOF
fi

# Create default web root
mkdir -p /usr/share/nginx/html
cat > /usr/share/nginx/html/index.html << 'EOF'
<!DOCTYPE html>
<html>
<head>
    <title>Welcome to nginx!</title>
</head>
<body>
    <h1>Welcome to nginx!</h1>
    <p>nginx 1.28.0 with HTTP/3 support</p>
    <p>Compiled from source on Fedora</p>
</body>
</html>
EOF

# Reload systemd and enable service
systemctl daemon-reload
systemctl enable nginx

# Test configuration
log_info "Testing nginx configuration..."
/usr/sbin/nginx -t

# Start nginx
log_info "Starting nginx..."
systemctl start nginx

# Cleanup build directory
cd / && rm -rf "$BUILD_DIR"

# Verify installation
log_success "Nginx $NGINX_VERSION installation completed!"
nginx_version=$(/usr/sbin/nginx -v 2>&1)
log_info "Installed version: $nginx_version"

# Check HTTP/3 support
if /usr/sbin/nginx -V 2>&1 | grep -q "http_v3_module"; then
    log_success "✓ HTTP/3 support available"
else
    log_error "✗ HTTP/3 support not available"
fi

log_info "Nginx is running and enabled for startup"
log_info "Configuration files are in /etc/nginx/"
log_info "You can check status with: sudo systemctl status nginx"