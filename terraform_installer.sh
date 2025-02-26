#!/bin/bash
set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Functions for colored messages
function print_info {
    echo -e "${BLUE}[INFO]${NC} $1"
}

function print_success {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

function print_warning {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

function print_error {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

# Ensure the script is run as root or with sudo privileges.
if [ "$EUID" -ne 0 ]; then
    print_error "This script must be run as root or with sudo privileges. Exiting."
fi

# Check if Terraform is already installed.
if command -v terraform >/dev/null 2>&1; then
    print_warning "Terraform is already installed. Skipping installation."
    exit 0
fi

# Detect package manager and follow appropriate installation steps.
if command -v apt-get >/dev/null 2>&1; then
    print_info "APT-based system detected."

    print_info "Updating package lists..."
    apt-get update -y

    print_info "Installing prerequisites: gnupg, software-properties-common, and curl..."
    apt-get install -y gnupg software-properties-common curl || print_error "Failed to install prerequisites."

    print_info "Adding HashiCorp GPG key..."
    wget -O- https://apt.releases.hashicorp.com/gpg | gpg --dearmor | tee /usr/share/keyrings/hashicorp-archive-keyring.gpg > /dev/null || print_error "Failed to add HashiCorp GPG key."

    DISTRO_CODENAME=$(lsb_release -cs 2>/dev/null || echo "buster")
    print_info "Adding HashiCorp repository for '${DISTRO_CODENAME}'..."
    echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com ${DISTRO_CODENAME} main" | tee /etc/apt/sources.list.d/hashicorp.list || print_error "Failed to add HashiCorp repository."

    print_info "Updating package lists from the new repository..."
    apt-get update -y

    print_info "Installing Terraform..."
    apt-get install -y terraform || print_error "Failed to install Terraform."

elif command -v yum >/dev/null 2>&1; then
    print_info "YUM-based system detected."

    print_info "Installing prerequisite: yum-utils..."
    yum install -y yum-utils || print_error "Failed to install yum-utils."

    print_info "Adding HashiCorp repository..."
    yum-config-manager --add-repo https://rpm.releases.hashicorp.com/RHEL/hashicorp.repo || print_error "Failed to add HashiCorp repository."

    print_info "Installing Terraform..."
    yum install -y terraform || print_error "Failed to install Terraform."

elif command -v dnf >/dev/null 2>&1; then
    print_info "DNF-based system detected."

    print_info "Installing prerequisite: dnf-plugins-core..."
    dnf install -y dnf-plugins-core || print_error "Failed to install dnf-plugins-core."

    print_info "Adding HashiCorp repository..."
    dnf config-manager --add-repo https://rpm.releases.hashicorp.com/RHEL/hashicorp.repo || print_error "Failed to add HashiCorp repository."

    print_info "Installing Terraform..."
    dnf install -y terraform || print_error "Failed to install Terraform."

else
    print_error "Unsupported package manager. Exiting."
fi

print_success "Terraform installation completed successfully!"
