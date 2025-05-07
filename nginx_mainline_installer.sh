#!/bin/bash
set -e

###############################################
# NGINX Open Source Mainline Installer
#
# Supported distributions:
# - Amazon Linux 2023
# - Fedora
# - RHEL / CentOS
# - Debian
# - Ubuntu
###############################################

# Channel & key
NGINX_CHANNEL="mainline"
NGINX_GPG_KEY_URL="https://nginx.org/keys/nginx_signing.key"
KEYRING="/usr/share/keyrings/nginx-archive-keyring.gpg"

# Colors & logging
RED='\033[0;31m' GREEN='\033[0;32m' BLUE='\033[0;34m' NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC}    $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC}   $1"; exit 1; }

# must be root
[ "$EUID" -eq 0 ] || error "Run as root."

# detect OS
. /etc/os-release || error "Cannot read /etc/os-release."
distro=${ID,,} version=${VERSION_ID}
info "Detected distro: $distro $version"

# remove old nginx
info "Removing existing NGINX packages..."
case "$distro" in
  debian|ubuntu) apt-get remove -y nginx* || true ;;
  fedora)        dnf remove -y nginx* || true ;;
  amzn|rhel|centos)
    dnf remove -y nginx* 2>/dev/null \
      || yum remove -y nginx* 2>/dev/null \
      || true
    ;;
  *) error "Unsupported distro: $distro" ;;
esac

# wipe out old repo files
info "Cleaning out old repo files..."
rm -f /etc/yum.repos.d/nginx.repo \
      /etc/apt/sources.list.d/nginx.list

# helper for Debian/Ubuntu key
add_key() {
  info "Importing NGINX key..."
  if command -v gpg >/dev/null; then
    curl -fsSL "$NGINX_GPG_KEY_URL" \
      | gpg --dearmor > "$KEYRING" \
      || error "gpg key import failed"
    KEYOPT="[signed-by=$KEYRING]"
  else
    curl -fsSL "$NGINX_GPG_KEY_URL" \
      | apt-key add - \
      || error "apt-key add failed"
    KEYOPT=""
  fi
}

# write repo, then test it
USE_DISTRO=false
write_repo() {
  info "Configuring NGINX $NGINX_CHANNEL repo..."
  case "$distro" in
    amzn)
      cat > /etc/yum.repos.d/nginx.repo <<EOF
[nginx-$NGINX_CHANNEL]
name=NGINX ${NGINX_CHANNEL^} for Amazon Linux 2023
baseurl=http://nginx.org/packages/$NGINX_CHANNEL/amzn/2023/\$basearch/
gpgcheck=1
enabled=1
gpgkey=$NGINX_GPG_KEY_URL
module_hotfixes=true
EOF
      REPO_URL="http://nginx.org/packages/$NGINX_CHANNEL/amzn/2023/\$basearch"
      ;;

    fedora)
      cat > /etc/yum.repos.d/nginx.repo <<EOF
[nginx-$NGINX_CHANNEL]
name=NGINX ${NGINX_CHANNEL^} for Fedora $version
baseurl=http://nginx.org/packages/$NGINX_CHANNEL/fedora/$version/\$basearch/
gpgcheck=1
enabled=1
gpgkey=$NGINX_GPG_KEY_URL
EOF
      REPO_URL="http://nginx.org/packages/$NGINX_CHANNEL/fedora/$version/\$basearch"
      ;;

    rhel|centos)
      major=${version%%.*}
      cat > /etc/yum.repos.d/nginx.repo <<EOF
[nginx-$NGINX_CHANNEL]
name=NGINX ${NGINX_CHANNEL^} for RHEL/CentOS $major
baseurl=http://nginx.org/packages/$NGINX_CHANNEL/rhel/$major/\$basearch/
gpgcheck=1
enabled=1
gpgkey=$NGINX_GPG_KEY_URL
EOF
      REPO_URL="http://nginx.org/packages/$NGINX_CHANNEL/rhel/$major/\$basearch"
      ;;

    debian)
      codename=$(lsb_release -cs)
      add_key
      echo "deb $KEYOPT http://nginx.org/packages/$NGINX_CHANNEL/debian $codename nginx" \
        > /etc/apt/sources.list.d/nginx.list
      echo "deb-src $KEYOPT http://nginx.org/packages/$NGINX_CHANNEL/debian $codename nginx" \
        >> /etc/apt/sources.list.d/nginx.list
      # repourl not used for APT
      return
      ;;

    ubuntu)
      codename=$(lsb_release -cs)
      add_key
      echo "deb $KEYOPT http://nginx.org/packages/$NGINX_CHANNEL/ubuntu $codename nginx" \
        > /etc/apt/sources.list.d/nginx.list
      echo "deb-src $KEYOPT http://nginx.org/packages/$NGINX_CHANNEL/ubuntu $codename nginx" \
        >> /etc/apt/sources.list.d/nginx.list
      return
      ;;

    *)
      error "Unsupported distro: $distro"
      ;;
  esac

  # test the repo URL for Fedora/RHEL/Amazon
  if [ -n "$REPO_URL" ]; then
    # expand $basearch
    arch=$(uname -m)
    url=${REPO_URL//\$basearch/$arch}/repodata/repomd.xml
    if ! curl --head --silent --fail "$url" >/dev/null; then
      info "Custom repo not found at $url, falling back to distro nginx"
      rm -f /etc/yum.repos.d/nginx.repo
      USE_DISTRO=true
    fi
  fi
}

write_repo

# update cache
info "Updating caches..."
case "$distro" in
  debian|ubuntu) apt-get update ;; 
  fedora)        dnf clean all ;;
  amzn|rhel|centos)
    dnf clean all || yum clean all ;;
esac

# install
info "Installing NGINX..."
case "$distro" in
  debian|ubuntu)
    apt-get install -y nginx \
      || error "apt install failed"
    ;;
  fedora)
    if [ "$USE_DISTRO" = true ]; then
      dnf install -y nginx || error "dnf install failed"
    else
      dnf install -y nginx --enablerepo=nginx-$NGINX_CHANNEL \
        || error "dnf install failed"
    fi
    ;;
  amzn|rhel|centos)
    if [ "$USE_DISTRO" = true ]; then
      dnf install -y nginx || yum install -y nginx || error "install failed"
    else
      dnf install -y nginx --enablerepo=nginx-$NGINX_CHANNEL \
        || yum install -y nginx --enablerepo=nginx-$NGINX_CHANNEL \
        || error "install failed"
    fi
    ;;
esac

# version check (strict only if custom repo used)
ver=$(nginx -v 2>&1 | awk -F/ '{print $2}')
info "Detected NGINX version: $ver"
if [ "$USE_DISTRO" = false ] && [[ "$ver" != 1.27.* ]]; then
  error "Expected 1.27.x from custom repo but got $ver"
fi

success "NGINX mainline installed."
info "Run: sudo systemctl start nginx"
