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

# Check if the script is run as root or with sudo
if [ "$EUID" -ne 0 ]; then
    print_error "This script must be run as root or with sudo privileges. Exiting."
fi

# Detect package manager
if [ -x "$(command -v apt-get)" ]; then
    PM="apt-get"
    print_info "APT-based system detected."
elif [ -x "$(command -v yum)" ]; then
    PM="yum"
    print_info "YUM-based system detected."
else
    print_error "Unsupported package manager. Exiting."
fi

# Check if Docker is already installed
if [ -x "$(command -v docker)" ]; then
    print_warning "Docker is already installed. Skipping installation."
    exit 0
fi

# Install prerequisites
print_info "Installing prerequisites..."
if [ "$PM" == "apt-get" ]; then
    apt-get update -y
    apt-get install -y ca-certificates curl gnupg lsb-release || print_error "Failed to install prerequisites."

    # Create keyring directory
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg || print_error "Failed to download Docker GPG key."

    # Add Docker repository
    DISTRO=$(lsb_release -cs 2>/dev/null || grep VERSION_CODENAME /etc/os-release | cut -d'=' -f2 || echo "focal")
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $DISTRO stable" | \
    tee /etc/apt/sources.list.d/docker.list > /dev/null || print_error "Failed to add Docker repository."

    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || print_error "Failed to install Docker."
elif [ "$PM" == "yum" ]; then
    yum install -y yum-utils || print_error "Failed to install yum-utils."
    yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo || print_error "Failed to add Docker repository."
    yum install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || print_error "Failed to install Docker."
fi

# Enable and start Docker service
print_info "Enabling and starting Docker service..."
systemctl enable docker || print_error "Failed to enable Docker service."
systemctl start docker || print_error "Failed to start Docker service."

print_success "Docker installation completed successfully!"
