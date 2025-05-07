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

# Define colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'  # No Color

# Logging functions
print_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then
    print_error "This script must be run as root."
fi

###############################################
# Detect distribution and version
###############################################
if [ -r /etc/os-release ]; then
    . /etc/os-release
    distro=$(echo "$ID" | tr '[:upper:]' '[:lower:]')
    version_id="$VERSION_ID"
else
    print_error "Cannot detect OS; /etc/os-release not found."
fi

print_info "Detected distribution: $distro $version_id"

###############################################
# Remove any existing NGINX packages
###############################################
remove_existing() {
    print_info "Removing existing NGINX packages..."
    case "$distro" in
        debian|ubuntu)
            apt-get remove -y nginx* || true
            ;;
        fedora)
            dnf remove -y nginx* || true
            ;;
        amzn|rhel|centos)
            # RHEL / CentOS / Amazon Linux may have yum or dnf
            dnf remove -y nginx* 2>/dev/null \
                || yum remove -y nginx* 2>/dev/null \
                || true
            ;;
        *)
            print_error "Unknown distribution for removal: $distro"
            ;;
    esac
}

remove_existing

###############################################
# Add the NGINX GPG key (Debian/Ubuntu)
###############################################
add_debian_key() {
    print_info "Importing NGINX signing key..."
    curl -fsSL https://nginx.org/keys/nginx_signing.key \
        | apt-key add - \
        || print_error "Failed to add NGINX GPG key."
}

###############################################
# Configure repository per distribution
###############################################
configure_repo() {
    print_info "Configuring NGINX mainline repository..."

    case "$distro" in
        # Amazon Linux 2023
        amzn)
            REPO_FILE="/etc/yum.repos.d/nginx.repo"
            cat > "$REPO_FILE" <<EOF
[nginx-mainline]
name=NGINX Mainline for Amazon Linux 2023
baseurl=http://nginx.org/packages/mainline/amzn/2023/\$basearch/
gpgcheck=1
enabled=1
gpgkey=https://nginx.org/keys/nginx_signing.key
module_hotfixes=true
EOF
            ;;

        # Fedora
        fedora)
            if command -v dnf &>/dev/null; then
                dnf install -y dnf-plugins-core
                dnf config-manager --add-repo=https://nginx.org/packages/mainline/fedora/"$version_id"/\$basearch/
            else
                print_error "dnf not found on Fedora."
            fi
            ;;

        # RHEL / CentOS (7, 8, 9)
        rhel|centos)
            major=$(echo "$version_id" | cut -d. -f1)
            REPO_FILE="/etc/yum.repos.d/nginx.repo"
            cat > "$REPO_FILE" <<EOF
[nginx-mainline]
name=NGINX Mainline for RHEL/CentOS $major
baseurl=http://nginx.org/packages/mainline/rhel/$major/\$basearch/
gpgcheck=1
enabled=1
gpgkey=https://nginx.org/keys/nginx_signing.key
EOF
            ;;

        # Debian
        debian)
            codename=$(lsb_release -cs)
            echo "deb http://nginx.org/packages/mainline/debian $codename nginx" \
                > /etc/apt/sources.list.d/nginx.list
            echo "deb-src http://nginx.org/packages/mainline/debian $codename nginx" \
                >> /etc/apt/sources.list.d/nginx.list
            add_debian_key
            ;;

        # Ubuntu
        ubuntu)
            codename=$(lsb_release -cs)
            echo "deb http://nginx.org/packages/mainline/ubuntu $codename nginx" \
                > /etc/apt/sources.list.d/nginx.list
            echo "deb-src http://nginx.org/packages/mainline/ubuntu $codename nginx" \
                >> /etc/apt/sources.list.d/nginx.list
            add_debian_key
            ;;

        *)
            print_error "No repo configuration for distribution: $distro"
            ;;
    esac
}

configure_repo

###############################################
# Update package cache / metadata
###############################################
print_info "Updating package cache / repo metadata..."
case "$distro" in
    debian|ubuntu)
        apt-get update || print_error "apt update failed."
        ;;
    fedora)
        dnf clean all
        ;;
    amzn|rhel|centos)
        dnf clean all || yum clean all
        ;;
esac

###############################################
# Install NGINX mainline
###############################################
print_info "Installing NGINX mainline..."
case "$distro" in
    debian|ubuntu)
        apt-get install -y nginx || print_error "apt install failed."
        ;;
    fedora|amzn|rhel|centos)
        dnf install -y nginx || yum install -y nginx \
            || print_error "dnf/yum install failed."
        ;;
esac

###############################################
# Verify installed version
###############################################
installed_version="$(nginx -v 2>&1 | awk -F'/' '{print $2}')"
print_info "Detected NGINX version: $installed_version"

if [[ "$installed_version" != 1.27.* ]]; then
    print_error "Expected a 1.27.x version but got: $installed_version"
fi

print_success "NGINX mainline installation completed successfully!"
print_info "Start NGINX with: sudo systemctl start nginx (or run 'nginx' manually)."

exit 0
