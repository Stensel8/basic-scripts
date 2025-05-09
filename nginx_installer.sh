#!/bin/bash
set -e

###############################################
# NGINX Open Source Installer
#
# Usage: sudo ./nginx_installer.sh [mainline|stable]
# Default channel: mainline
#
# Supported distros:
# - Amazon Linux 2023
# - Fedora
# - RHEL / CentOS
# - Debian
# - Ubuntu
###############################################

# Kies channel
CHANNEL="${1:-mainline}"
if [[ "$CHANNEL" != "mainline" && "$CHANNEL" != "stable" ]]; then
  echo "Usage: $0 [mainline|stable]"
  exit 1
fi

# Key en repo info
NGINX_CHANNEL="$CHANNEL"
NGINX_GPG_KEY_URL="https://nginx.org/keys/nginx_signing.key"
KEYRING="/usr/share/keyrings/nginx-archive-keyring.gpg"

# Wat verwachtte versie prefix?
if [ "$CHANNEL" = "mainline" ]; then
  EXPECTED_PREFIX="1.27."
else
  EXPECTED_PREFIX="1.28."
fi

# Kleuren & logfuncties
RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC}    $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC}   $1"; exit 1; }

# Root?
[ "$EUID" -eq 0 ] || error "Run as root."

# Prerequisites installeren
info "Installing prerequisites..."
if   command -v apt-get >/dev/null; then
    apt-get update && apt-get install -y lsb-release gnupg gnupg2 curl && apt-get clean
elif command -v dnf >/dev/null; then
    dnf install -y redhat-lsb-core gnupg gnupg2 curl && dnf clean all
elif command -v yum >/dev/null; then
    yum install -y redhat-lsb-core gnupg gnupg2 curl && yum clean all
elif command -v zypper >/dev/null; then
    zypper refresh && zypper install -y lsb-release gnupg gnupg2 curl && zypper clean --all
elif command -v pacman >/dev/null; then
    pacman -Sy --noconfirm && pacman -S --noconfirm lsb-release gnupg gnupg2 curl && pacman -Sc --noconfirm
elif command -v apk >/dev/null; then
    apk update && apk add lsb-release gnupg curl && rm -rf /var/cache/apk/*
else
    error "No supported package manager found."
fi

# OS-detectie
. /etc/os-release || error "Cannot read /etc/os-release."
distro=${ID,,} version=${VERSION_ID}
info "Detected distro: $distro $version"

# Verwijder oude nginx
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

# Oude repo’s weghalen
info "Cleaning out old repo files..."
rm -f /etc/yum.repos.d/nginx.repo /etc/apt/sources.list.d/nginx.list

# Key-import helper
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

# Repo wegschrijven en testen
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

  # Test custom repo
  arch=$(uname -m)
  url=${REPO_URL//\$basearch/$arch}/repodata/repomd.xml
  if ! curl --head --silent --fail "$url" >/dev/null; then
    info "Custom repo niet gevonden ($url), terugvallen op distro-pakket"
    rm -f /etc/yum.repos.d/nginx.repo
    USE_DISTRO=true
  fi
}

write_repo

# Cache bijwerken
info "Updating caches..."
case "$distro" in
  debian|ubuntu) apt-get update ;;
  fedora)        dnf clean all ;;
  amzn|rhel|centos)
    dnf clean all || yum clean all ;;
esac

# Installeren
info "Installing NGINX..."
case "$distro" in
  debian|ubuntu)
    apt-get install -y nginx || error "apt install failed"
    ;;
  fedora)
    if [ "$USE_DISTRO" = true ]; then
      dnf install -y nginx || error "dnf install failed"
    else
      dnf install -y nginx --enablerepo=nginx-$NGINX_CHANNEL || error "dnf install failed"
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

# Versie-check
ver=$(nginx -v 2>&1 | awk -F/ '{print $2}')
info "Detected NGINX version: $ver"
if [ "$USE_DISTRO" = false ] && [[ "$ver" != $EXPECTED_PREFIX* ]]; then
  error "Expected ${EXPECTED_PREFIX}x but got $ver"
fi

success "NGINX $NGINX_CHANNEL installed."
info "Start met: sudo systemctl start nginx"
