# nginx_stable_installer.sh
#!/bin/bash
set -e

###############################################
# NGINX Open Source Stable Installer
#
# Supported distributions:
# - Amazon Linux 2023
# - Fedora
# - RHEL / CentOS
# - Debian
# - Ubuntu
###############################################

# Variables
NGINX_CHANNEL="stable"
NGINX_GPG_KEY_URL="https://nginx.org/keys/nginx_signing.key"
KEYRING_PATH="/usr/share/keyrings/nginx-archive-keyring.gpg"

# Define colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

# Logging functions
print_info()    { echo -e "${BLUE}[INFO]${NC}    $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_error()   { echo -e "${RED}[ERROR]${NC}   $1"; exit 1; }

# Ensure script is run as root
[ "$EUID" -eq 0 ] || print_error "This script must be run as root."

###############################################
# Detect distribution and version
###############################################
if [ -r /etc/os-release ]; then
    . /etc/os-release
    distro=$(echo "$ID"     | tr '[:upper:]' '[:lower:]')
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
            dnf remove -y nginx* 2>/dev/null \
             || yum remove -y nginx* 2>/dev/null \
             || true
            ;;
        *)
            print_error "Unknown distro for package removal: $distro"
            ;;
    esac
}
remove_existing

###############################################
# Clean out any old repo definitions
###############################################
print_info "Removing any existing NGINX repo files..."
rm -f /etc/yum.repos.d/nginx.repo
rm -f /etc/apt/sources.list.d/nginx.list

###############################################
# Add the NGINX GPG key (Debian/Ubuntu only)
###############################################
add_debian_key() {
    print_info "Importing NGINX signing key..."
    if command -v gpg >/dev/null; then
        curl -fsSL "$NGINX_GPG_KEY_URL" | gpg --dearmor \
          > "$KEYRING_PATH" \
          || print_error "Failed to import keyring."
        KEY_OPT="[signed-by=${KEYRING_PATH}]"
    else
        curl -fsSL "$NGINX_GPG_KEY_URL" | apt-key add - \
          || print_error "Failed to add GPG key."
        KEY_OPT=""
    fi
}

###############################################
# Configure the stable repository
###############################################
configure_repo() {
    print_info "Configuring NGINX ${NGINX_CHANNEL} repository..."
    case "$distro" in

        # Amazon Linux 2023
        amzn)
            REPO_FILE="/etc/yum.repos.d/nginx.repo"
            cat > "$REPO_FILE" <<EOF
[nginx-stable]
name=NGINX Stable for Amazon Linux 2023
baseurl=http://nginx.org/packages/amzn/2023/\$basearch/
gpgcheck=1
enabled=1
gpgkey=${NGINX_GPG_KEY_URL}
module_hotfixes=true
EOF
            ;;

        # Fedora
        fedora)
            REPO_FILE="/etc/yum.repos.d/nginx.repo"
            cat > "$REPO_FILE" <<EOF
[nginx-stable]
name=NGINX Stable for Fedora $version_id
baseurl=http://nginx.org/packages/fedora/$version_id/\$basearch/
gpgcheck=1
enabled=1
gpgkey=${NGINX_GPG_KEY_URL}
EOF
            ;;

        # RHEL / CentOS (7, 8, 9)
        rhel|centos)
            major=$(echo "$version_id" | cut -d. -f1)
            REPO_FILE="/etc/yum.repos.d/nginx.repo"
            cat > "$REPO_FILE" <<EOF
[nginx-stable]
name=NGINX Stable for RHEL/CentOS $major
baseurl=http://nginx.org/packages/rhel/$major/\$basearch/
gpgcheck=1
enabled=1
gpgkey=${NGINX_GPG_KEY_URL}
EOF
            ;;

        # Debian
        debian)
            codename=$(lsb_release -cs)
            add_debian_key
            echo "deb ${KEY_OPT} http://nginx.org/packages/debian $codename nginx" \
                > /etc/apt/sources.list.d/nginx.list
            echo "deb-src ${KEY_OPT} http://nginx.org/packages/debian $codename nginx" \
                >> /etc/apt/sources.list.d/nginx.list
            ;;

        # Ubuntu
        ubuntu)
            codename=$(lsb_release -cs)
            add_debian_key
            echo "deb ${KEY_OPT} http://nginx.org/packages/ubuntu $codename nginx" \
                > /etc/apt/sources.list.d/nginx.list
            echo "deb-src ${KEY_OPT} http://nginx.org/packages/ubuntu $codename nginx" \
                >> /etc/apt/sources.list.d/nginx.list
            ;;

        *)
            print_error "No repo configuration for distro: $distro"
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
# Install NGINX stable
###############################################
print_info "Installing NGINX stable..."
case "$distro" in
    debian|ubuntu)
        apt-get install -y nginx || print_error "apt install failed."
        ;;
    fedora|amzn|rhel|centos)
        dnf install -y nginx \
          || yum install -y nginx \
          || print_error "dnf/yum install failed."
        ;;
esac

###############################################
# Verify installed version (1.28.x)
###############################################
installed_version="$(nginx -v 2>&1 | awk -F'/' '{print $2}')"
print_info "Detected NGINX version: $installed_version"
if [[ "$installed_version" != 1.28.* ]]; then
    print_error "Expected a 1.28.x version but got: $installed_version"
fi

print_success "NGINX stable installation completed successfully!"
print_info "Start NGINX with: sudo systemctl start nginx (or run 'nginx' manually)."

exit 0
