#!/usr/bin/env bash
#########################################################################
# NGINX Installer Script - Optimized with GitHub Copilot
#########################################################################

# Enable strict error handling
set -euo pipefail

#########################################################################
# CONFIGURATION VARIABLES
#########################################################################

# Default to mainline release channel
CHANNEL="mainline"

# Version mapping - update these when new versions are released
STABLE_VERSION="1.28.0"
MAINLINE_VERSION="1.27.5"

# Base URL for downloads
NGINX_DOWNLOAD_URL="https://nginx.org/download"
NGINX_KEY_URL="https://nginx.org/keys/nginx_signing.key"

# Log formatting
LOG_INFO="[INFO]"
LOG_WARN="[WARN]"
LOG_ERROR="[ERROR]"
LOG_SUCCESS="[SUCCESS]"

#########################################################################
# HELPER FUNCTIONS
#########################################################################

# Display usage information
usage() { 
    echo "Usage: $0 [-s stable|mainline]" >&2
    exit 1
}

# Print formatted log messages
log_info() { echo "${LOG_INFO} $1"; }
log_warn() { echo "${LOG_WARN} $1"; }
log_error() { echo "${LOG_ERROR} $1"; }
log_success() { echo "${LOG_SUCCESS} $1"; }

# Detect Linux distribution
detect_distro() {
  # Source the OS release information
  . /etc/os-release
  
  # Return simplified distribution category
  case "$ID" in
    ubuntu|debian) echo "debian" ;;
    centos|rhel|rocky|alma) echo "rhel" ;;
    fedora) echo "fedora" ;;
    opensuse*|sles) echo "suse" ;;
    arch) echo "arch" ;;
    *) echo "unknown" ;;
  esac
}

# Verify NGINX installation and version
verify_nginx_version() {
  if ! command -v nginx >/dev/null; then
    log_error "nginx command not found after installation"
    return 1
  fi
  
  # Get NGINX version
  NGINX_VER=$(nginx -v 2>&1)
  log_info "Installed NGINX version: $NGINX_VER"
    # If using a local distribution package, don't enforce exact version match
  if echo "$NGINX_VER" | grep -q "nginx/[0-9]"; then
    # Check if we were able to get a package from the official NGINX repo
    if grep -q "packages/${CHANNEL}" /etc/yum.repos.d/nginx.repo 2>/dev/null || 
       grep -q "packages/${CHANNEL}" /etc/apt/sources.list.d/nginx.list 2>/dev/null; then
      
      # Only then check version match
      if [ "$CHANNEL" = "stable" ] && ! echo "$NGINX_VER" | grep -q "1.28"; then
        log_error "Installed version does not match stable channel (expected 1.28.x)"
        return 1
      elif [ "$CHANNEL" = "mainline" ] && ! echo "$NGINX_VER" | grep -q "1.27"; then
        log_error "Installed version does not match mainline channel (expected 1.27.x)"
        return 1
      fi
    else
      # Using distribution package, log a warning but accept it
      log_warn "Using distribution-provided NGINX package (${NGINX_VER}), not official NGINX repo package"
    fi
  else
    log_error "Unexpected NGINX version format: ${NGINX_VER}"
    return 1
  fi
  
  return 0
}

#########################################################################
# PACKAGE INSTALLATION FUNCTION
#########################################################################

install_nginx_package() {
  case "$DISTRO" in
    debian)
      # Handle Ubuntu Noble release which isn't directly supported
      if [ "$(lsb_release -cs)" = "noble" ]; then
        log_warn "Ubuntu Noble not directly supported, using jammy repositories instead"
        RELEASE="jammy"
        OS_TYPE="ubuntu"
      else
        RELEASE="$(lsb_release -cs)"
        
        # Detect Ubuntu or Debian
        if grep -qi "ubuntu" /etc/os-release; then
          OS_TYPE="ubuntu"
        else
          OS_TYPE="debian"
        fi
      fi
      
      # Import NGINX signing key
      log_info "Importing NGINX signing key"
      curl -fsSL ${NGINX_KEY_URL} | gpg --dearmor \
        | tee /usr/share/keyrings/nginx-archive-keyring.gpg >/dev/null
      
      # Configure repository
      log_info "Configuring ${OS_TYPE} repository for ${CHANNEL} channel"
      cat <<EOF >/etc/apt/sources.list.d/nginx.list
# nginx ${CHANNEL}
deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] \
  http://nginx.org/packages/${CHANNEL}/${OS_TYPE} \
  ${RELEASE} nginx
EOF

      # Update package lists and install
      if ! apt-get update 2>/dev/null; then
        log_error "Repository update failed - package might not be available"
        return 1
      fi
      
      log_info "Installing NGINX package"
      if ! apt-get install -y nginx; then
        log_error "Failed to install nginx from package repository"
        return 1
      fi
      ;;

    rhel|fedora)
      # For newer Fedora versions that might not be supported 
      if [ "$DISTRO" = "fedora" ]; then
        RELVER=$(rpm -E %fedora)
        if [ "$RELVER" -ge 38 ]; then
          log_warn "Fedora $RELVER might not have official nginx packages, trying anyway"
        fi
      fi
        # Configure repository
      log_info "Configuring ${DISTRO} repository for ${CHANNEL} channel"
      cat <<EOF >/etc/yum.repos.d/nginx.repo
[nginx-${CHANNEL}]
name=nginx ${CHANNEL} repo
baseurl=http://nginx.org/packages/${CHANNEL}/$([ "$DISTRO" = "fedora" ] && echo "fedora" || echo "rhel")/\$releasever/\$basearch/
gpgcheck=1
enabled=1
gpgkey=${NGINX_KEY_URL}
EOF

      # Install package using appropriate package manager
      log_info "Installing NGINX package"
      if command -v dnf &>/dev/null; then
        if ! dnf -y --refresh install nginx; then
          log_error "Failed to install nginx from package repository"
          return 1
        fi
      else
        if ! yum -y install nginx; then
          log_error "Failed to install nginx from package repository"
          return 1
        fi
      fi
      ;;

    suse)
      # Configure repository
      log_info "Configuring openSUSE repository for ${CHANNEL} channel"
      zypper addrepo --name nginx-${CHANNEL} \
        http://nginx.org/packages/${CHANNEL}/opensuse/$(. /etc/os-release && echo $VERSION_ID)/ nginx
      
      # Refresh package lists and install
      zypper --gpg-auto-import-keys refresh
      log_info "Installing NGINX package"
      if ! zypper install -y nginx; then
        log_error "Failed to install nginx from package repository"
        return 1
      fi
      ;;

    arch)
      # Install from Arch repositories
      log_info "Installing NGINX from Arch repositories"
      if ! pacman -Sy --noconfirm nginx; then
        log_error "Failed to install nginx from package repository"
        return 1
      fi
      ;;

    *) 
      log_error "Unsupported distribution"
      return 1
      ;;
  esac
    # Verify installation and version
  verify_nginx_version
  return $?
}

#########################################################################
# SOURCE INSTALLATION FUNCTION
#########################################################################

install_nginx_from_source() {
  log_info "Building NGINX from source"
  log_info "This will ensure you get the correct version for the selected channel"
  
  # Set version based on channel
  if [ "$CHANNEL" = "stable" ]; then
    VER="${STABLE_VERSION}"
  else
    VER="${MAINLINE_VERSION}"
  fi
    # Create build directory
  BUILD_DIR="/tmp/nginx-build"
  log_info "Creating build directory: ${BUILD_DIR}"
  mkdir -p ${BUILD_DIR} && cd ${BUILD_DIR}
  
  # Download source and signature
  log_info "Downloading NGINX ${VER} source code"
  curl -fsSL ${NGINX_DOWNLOAD_URL}/nginx-${VER}.tar.gz -o nginx.tar.gz
  curl -fsSL ${NGINX_DOWNLOAD_URL}/nginx-${VER}.tar.gz.asc -o nginx.tar.gz.asc
  
  # Import key and verify signature
  log_info "Verifying package signature"
  gpg --batch --import <(curl -fsSL ${NGINX_KEY_URL})
  gpg --batch --verify nginx.tar.gz.asc nginx.tar.gz || log_warn "Signature verification failed, continuing anyway"
    # Check for required build dependencies and install them
  log_info "Checking for and installing build dependencies"
  case "$DISTRO" in
    debian)
      log_info "Installing build dependencies for Debian/Ubuntu"
      apt-get update -qq
      apt-get install -y build-essential libpcre3-dev zlib1g-dev libssl-dev
      ;;
    rhel|fedora)
      log_info "Installing build dependencies for RHEL/Fedora"
      if command -v dnf &>/dev/null; then
        dnf -y install gcc make pcre-devel zlib-devel openssl-devel
      else
        yum -y install gcc make pcre-devel zlib-devel openssl-devel
      fi
      ;;
    suse)
      log_info "Installing build dependencies for openSUSE"
      zypper install -y gcc make pcre-devel zlib-devel libopenssl-devel
      ;;
    arch)
      log_info "Installing build dependencies for Arch Linux"
      pacman -S --noconfirm gcc make pcre zlib openssl
      ;;
    *)
      log_error "Unsupported distribution for source build"
      return 1
      ;;
  esac
  
  # Extract and build
  log_info "Extracting source code"
  tar xf nginx.tar.gz
  cd nginx-${VER}
  
  # Configure with standard modules
  log_info "Configuring build with HTTP SSL and Stream modules"
  ./configure --with-http_ssl_module --with-stream --prefix=/usr/local
  
  # Build and install
  log_info "Compiling NGINX (this may take a while)"
  make -j"$(nproc || echo 1)"
  log_info "Installing NGINX to /usr/local"
  make install
  
  # Create symlink to make it available in PATH
  log_info "Creating symlink in /usr/bin for easier access"
  ln -sf /usr/local/sbin/nginx /usr/bin/nginx 2>/dev/null || log_warn "Failed to create symlink"
  
  # Install systemd service file if it doesn't exist
  if [ ! -f /etc/systemd/system/nginx.service ]; then
    log_info "Creating systemd service file"
    cat > /etc/systemd/system/nginx.service <<EOF
[Unit]
Description=The NGINX HTTP and reverse proxy server
After=network.target

[Service]
Type=forking
PIDFile=/usr/local/logs/nginx.pid
ExecStartPre=/usr/local/sbin/nginx -t
ExecStart=/usr/local/sbin/nginx
ExecReload=/usr/local/sbin/nginx -s reload
ExecStop=/bin/kill -s QUIT \$MAINPID
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    log_info "Installed nginx.service systemd unit"
  fi
  
  # Verify the installation
  if command -v nginx >/dev/null; then
    NGINX_VER=$(nginx -v 2>&1)
    log_info "Installed NGINX version: $NGINX_VER"
    
    # Verify version matches what we expect
    if [ "$CHANNEL" = "stable" ] && ! echo "$NGINX_VER" | grep -q "1.28"; then
      log_warn "Installed version does not match stable channel (expected 1.28.x)"
    elif [ "$CHANNEL" = "mainline" ] && ! echo "$NGINX_VER" | grep -q "1.27"; then
      log_warn "Installed version does not match mainline channel (expected 1.27.x)"
    fi
  else
    log_warn "nginx command not in PATH. You can run it with: /usr/local/sbin/nginx"
  fi
  
  log_success "NGINX $VER installed from source"
  log_info "You can start it with: sudo systemctl start nginx"
}

#########################################################################
# MAIN SCRIPT EXECUTION
#########################################################################

# Parse command line options
# First check for direct parameters (bash -s stable)
if [ $# -eq 1 ] && [[ "$1" =~ ^(stable|mainline)$ ]]; then
    CHANNEL="$1"
    log_info "Setting channel to $CHANNEL (from direct parameter)"
# Otherwise parse traditional options
else
    while getopts "s:" opt; do
        case $opt in
            s) 
                if [[ "$OPTARG" =~ ^(stable|mainline)$ ]]; then
                    CHANNEL="$OPTARG"
                    log_info "Setting channel to $CHANNEL (from -s option)"
                else
                    log_error "Channel must be 'stable' or 'mainline'"
                    usage
                fi
                ;;
            *) usage ;;
        esac
    done
fi

# Check for root privileges
log_info "Checking for root privileges"
(( EUID == 0 )) || { log_error "This script must be run as root"; exit 1; }

# Detect distribution
DISTRO=$(detect_distro)
log_info "Detected distribution: $DISTRO"  # Try package installation first
log_info "Attempting to install NGINX from official packages (channel: $CHANNEL)"
if install_nginx_package; then
  log_success "NGINX ($CHANNEL) installed via package manager"
  exit 0
fi

# Fall back to source installation if package installation fails
log_info "Package installation failed, falling back to source installation"
install_nginx_from_source

exit 0
