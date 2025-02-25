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

# Ensure the script is run as root.
if [ "$EUID" -ne 0 ]; then
    print_error "This script must be run as root or with sudo privileges. Exiting."
fi

# Check if Ansible is already installed.
if [ -x "$(command -v ansible)" ]; then
    print_warning "Ansible is already installed. Skipping installation."
    exit 0
fi

# Detect package manager and install Ansible accordingly.
if [ -x "$(command -v apt-get)" ]; then
    print_info "APT-based system detected."
    apt-get update -y

    # Differentiate Ubuntu from Debian.
    if [ -f /etc/lsb-release ]; then
        print_info "Ubuntu environment detected. Installing required packages..."
        apt-get install -y software-properties-common || print_error "Failed to install software-properties-common."

        print_info "Adding Ansible PPA..."
        add-apt-repository --yes --update ppa:ansible/ansible || print_error "Failed to add Ansible PPA."
    else
        # Assume Debian. The official documentation suggests using an Ubuntu PPA.
        print_info "Debian environment detected. Installing prerequisites..."
        apt-get install -y wget gnupg || print_error "Failed to install prerequisites (wget, gnupg)."

        # Set UBUNTU_CODENAME appropriately: adjust this value if needed.
        UBUNTU_CODENAME="jammy"
        print_info "Adding Ansible repository for Debian using UBUNTU_CODENAME=${UBUNTU_CODENAME}..."
        wget -O- "https://keyserver.ubuntu.com/pks/lookup?fingerprint=on&op=get&search=0x6125E2A8C77F2818FB7BD15B93C4A3FD7BB9C367" \
            | gpg --dearmour -o /usr/share/keyrings/ansible-archive-keyring.gpg || print_error "Failed to download Ansible GPG key."

        echo "deb [signed-by=/usr/share/keyrings/ansible-archive-keyring.gpg] http://ppa.launchpad.net/ansible/ansible/ubuntu ${UBUNTU_CODENAME} main" \
            > /etc/apt/sources.list.d/ansible.list || print_error "Failed to add Ansible repository."
    fi

    apt-get update -y
    print_info "Installing Ansible..."
    apt-get install -y ansible || print_error "Failed to install Ansible."

elif [ -x "$(command -v yum)" ]; then
    print_info "YUM-based system detected."
    # Check for DNF first (Fedora-based systems)
    if command -v dnf &> /dev/null; then
        print_info "DNF detected. Installing Ansible via dnf..."
        dnf install -y ansible || print_error "Failed to install Ansible via dnf."
    else
        print_info "YUM detected. Enabling EPEL repository and installing Ansible..."
        yum install -y epel-release || print_error "Failed to enable EPEL repository."
        yum install -y ansible || print_error "Failed to install Ansible via yum."
    fi

elif [ -x "$(command -v zypper)" ]; then
    print_info "zypper-based system detected. Installing Ansible..."
    zypper install -y ansible || print_error "Failed to install Ansible via zypper."

elif [ -x "$(command -v pacman)" ]; then
    print_info "pacman-based system detected. Installing Ansible..."
    pacman -Sy --noconfirm ansible || print_error "Failed to install Ansible via pacman."

else
    print_error "Unsupported package manager. Exiting."
fi

print_success "Ansible installation completed successfully!"
