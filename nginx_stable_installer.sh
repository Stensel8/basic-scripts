#!/bin/bash
set -e

###############################################
# NGINX Open Source Stable Installer
#
# Installs the stable release (e.g. v1.26.3) of NGINX on
# Amazon Linux 2023 by removing old NGINX packages and
# setting up the stable repository from nginx.org.
###############################################

# Define color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'  # No Color

# Logging functions for clear progress reporting
print_info()  { echo -e "${BLUE}[INFO]${NC}  $1"; }
print_success(){ echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_error()  { echo -e "${RED}[ERROR]${NC}   $1"; exit 1; }

# Ensure the script runs as root
if [ "$EUID" -ne 0 ]; then
    print_error "This script must be run as root."
fi

###############################################
# Install prerequisites (lsb-release, GPG tools)
###############################################
print_info "Installing prerequisites..."
if   command -v apt-get >/dev/null; then
    apt-get update && apt-get install -y lsb-release gnupg gnupg2 && apt-get clean
elif command -v dnf >/dev/null; then
    dnf install -y redhat-lsb-core gnupg gnupg2 && dnf clean all
elif command -v yum >/dev/null; then
    yum install -y redhat-lsb-core gnupg gnupg2 && yum clean all
elif command -v zypper >/dev/null; then
    zypper refresh && zypper install -y lsb-release gnupg gnupg2 && zypper clean --all
elif command -v pacman >/dev/null; then
    pacman -Sy --noconfirm && pacman -S --noconfirm lsb-release gnupg gnupg2 && pacman -Sc --noconfirm
elif command -v apk >/dev/null; then
    apk update && apk add lsb-release gnupg && rm -rf /var/cache/apk/*
else
    print_error "No supported package manager found."
fi

###############################################
# Detect Amazon Linux 2023 Only
###############################################
if [ -r /etc/os-release ]; then
    . /etc/os-release
    distro=$(echo "$ID" | tr '[:upper:]' '[:lower:]')
    version_id="$VERSION_ID"
else
    print_error "Cannot detect OS; /etc/os-release not found."
fi

if [[ "$distro" != "amzn" || "$version_id" != "2023" ]]; then
    print_error "This stable installer is written only for Amazon Linux 2023."
fi

print_info "Detected Amazon Linux 2023."

###############################################
# Remove Existing NGINX Packages and Repo File
###############################################
print_info "Removing any existing NGINX packages..."
dnf remove -y nginx\* || yum remove -y nginx\* || true

REPO_FILE="/etc/yum.repos.d/nginx.repo"
print_info "Removing existing NGINX repo file..."
rm -f "$REPO_FILE"

###############################################
# Configure the Stable Repository from nginx.org
###############################################
print_info "Configuring NGINX stable repository..."
cat > "$REPO_FILE" <<EOF
[nginx-stable]
name=NGINX Stable for Amazon Linux 2023
baseurl=http://nginx.org/packages/amzn/2023/\$basearch/
gpgcheck=1
enabled=1
gpgkey=https://nginx.org/keys/nginx_signing.key
module_hotfixes=true
EOF

###############################################
# Clean Cache & Disable Default Amazon Repos for NGINX
###############################################
print_info "Cleaning DNF cache..."
dnf clean all || true

# Disable default Amazon Linux repos so the official nginx.org package is used.
disable_repos="--disablerepo=amazonlinux --disablerepo=amzn2-core"
print_info "Temporarily disabling Amazon repos: $disable_repos"

###############################################
# Install NGINX from the Stable Repository
###############################################
print_info "Installing NGINX stable from nginx.org..."
dnf install -y nginx --enablerepo=nginx-stable $disable_repos || print_error "NGINX stable installation failed."

###############################################
# Verify the Installed Version (should start with 1.26.)
###############################################
installed_version="$(nginx -v 2>&1 | awk -F'/' '{print $2}')"
print_info "NGINX version detected: $installed_version"

if [[ "$installed_version" != 1.26.* ]]; then
    print_error "Expected a 1.26.x version but got: $installed_version."
fi

print_success "NGINX Stable installation completed successfully!"
print_info "You can start NGINX with: sudo systemctl start nginx (if applicable) or run 'nginx' manually."

exit 0
