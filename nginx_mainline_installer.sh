#!/bin/bash
set -e

###############################################
# NGINX Open Source Mainline Installer
#
# This script installs the NGINX mainline release (e.g. v1.27.x)
# on Amazon Linux 2023. It force-removes any previous NGINX packages
# and repo configurations to ensure that only the mainline repo
# (from nginx.org) is used.
###############################################

# Define colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'  # No Color

# Logging functions
print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# Ensure the script is run as root
if [ "$EUID" -ne 0 ]; then
    print_error "This script must be run as root."
fi

###############################################
# Distribution Detection (for Amazon Linux 2023 only)
###############################################
if [ -r /etc/os-release ]; then
    . /etc/os-release
    distro=$(echo "$ID" | tr '[:upper:]' '[:lower:]')
    version_id="$VERSION_ID"
else
    print_error "Cannot detect OS; /etc/os-release not found."
fi

if [[ "$distro" != "amzn" || "$version_id" != "2023" ]]; then
    print_error "This mainline installer is written only for Amazon Linux 2023.";
fi
print_info "Detected Amazon Linux 2023."

###############################################
# Remove any existing NGINX packages and repo file
###############################################
print_info "Removing any existing NGINX packages..."
dnf remove -y nginx\* || yum remove -y nginx\* || true

REPO_FILE="/etc/yum.repos.d/nginx.repo"
print_info "Removing existing NGINX repository file: $REPO_FILE"
rm -f "$REPO_FILE"

###############################################
# Configure the mainline repository from nginx.org
###############################################
print_info "Configuring NGINX mainline repository..."
cat > "$REPO_FILE" <<EOF
[nginx-mainline]
name=NGINX Mainline for Amazon Linux 2023
baseurl=http://nginx.org/packages/mainline/amzn/2023/\$basearch/
gpgcheck=1
enabled=1
gpgkey=https://nginx.org/keys/nginx_signing.key
module_hotfixes=true
EOF

###############################################
# Clean repo cache and disable default Amazon repos for nginx
###############################################
print_info "Cleaning DNF cache..."
dnf clean all || true

# Disable default Amazon repos so they don't supply an older nginx package.
disable_repos="--disablerepo=amazonlinux --disablerepo=amzn2-core"
print_info "Temporarily disabling Amazon repos: $disable_repos"

###############################################
# Install NGINX from the mainline repo
###############################################
print_info "Installing NGINX mainline from nginx.org..."
dnf install -y nginx --enablerepo=nginx-mainline $disable_repos || print_error "NGINX mainline installation failed."

###############################################
# Verify the installed version
###############################################
installed_version="$(nginx -v 2>&1 | awk -F'/' '{print $2}')"
print_info "NGINX version detected: $installed_version"

if [[ "$installed_version" != 1.27.* ]]; then
    print_error "Expected a 1.27.x version but got: $installed_version."
fi

print_success "NGINX Mainline installation completed successfully!"
print_info "Start NGINX with: sudo systemctl start nginx (or run 'nginx' manually)."

exit 0
