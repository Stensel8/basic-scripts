#!/bin/bash
set -e

###############################################
# Docker Installer Script
###############################################

# Colors for messages
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'  # No Color

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

# Ensure the script is run as root or with sudo
if [ "$EUID" -ne 0 ]; then
    print_error "This script must be run as root or with sudo privileges. Exiting."
fi

###############################################
# Functions from get.docker.com installer script
###############################################

# Check if a command exists
command_exists() {
    command -v "$@" > /dev/null 2>&1
}

# Compare two version strings (Major.Minor)
version_compare() {
    local ver_a_major ver_b_major ver_a_minor ver_b_minor
    ver_a_major="$(echo "$1" | cut -d'.' -f1)"
    ver_b_major="$(echo "$2" | cut -d'.' -f1)"
    if [ "$ver_a_major" -lt "$ver_b_major" ]; then
        return 1
    elif [ "$ver_a_major" -gt "$ver_b_major" ]; then
        return 0
    fi
    ver_a_minor="$(echo "$1" | cut -d'.' -f2)"
    ver_b_minor="$(echo "$2" | cut -d'.' -f2)"
    # Remove leading zeros
    ver_a_minor="${ver_a_minor#0}"
    ver_b_minor="${ver_b_minor#0}"
    if [ "${ver_a_minor:-0}" -lt "${ver_b_minor:-0}" ]; then
        return 1
    fi
    return 0
}

# Check if $VERSION is greater or equal to a given version
version_gte() {
    if [ -z "$VERSION" ]; then
        return 0
    fi
    version_compare "$VERSION" "$1"
}

# Get Linux distribution ID (using /etc/os-release)
get_distribution() {
    local lsb_dist=""
    if [ -r /etc/os-release ]; then
        . /etc/os-release
        lsb_dist="$ID"
    fi
    echo "$lsb_dist"
}

# Show a deprecation warning for unsupported or EOL distributions
deprecation_notice() {
    local distro="$1"
    local distro_version="$2"
    print_warning "This Linux distribution ($distro $distro_version) is deprecated and no longer supported."
    print_info "Consider upgrading to a newer version of $distro."
    sleep 5
}

# Provide instructions to run Docker as non-root (rootless mode)
echo_docker_as_nonroot() {
    print_info "To run Docker as a non-root user, consider installing rootless mode:"
    echo "    dockerd-rootless-setuptool.sh install"
    print_info "See https://docs.docker.com/go/rootless/ for more information."
}

# Check if this is a forked distro (e.g., Linux Mint)
check_forked() {
    if command_exists lsb_release; then
        set +e
        lsb_release -a -u > /dev/null 2>&1
        if [ "$?" = "0" ]; then
            print_info "Forked distro detected. Using upstream release information."
        fi
        set -e
    fi
}

###############################################
# Main Installation Function
###############################################
do_install() {
    print_info "Starting Docker installation (integrated with get.docker.com functions)."

    # Check if Docker is already installed
    if command_exists docker; then
        print_warning "Docker appears to be already installed. Skipping installation."
        exit 0
    fi

    # Detect distribution and version
    distro=$(get_distribution | tr '[:upper:]' '[:lower:]')
    check_forked

    case "$distro" in
        ubuntu|debian|raspbian)
            print_info "APT-based system detected: $distro"
            if command_exists lsb_release; then
                dist_version=$(lsb_release --codename | cut -f2)
            else
                dist_version=$(grep VERSION_CODENAME /etc/os-release | cut -d'=' -f2)
            fi

            # Warning for older versions
            case "$distro.$dist_version" in
                ubuntu.trusty|ubuntu.xenial|debian.jessie)
                    deprecation_notice "$distro" "$dist_version"
                    ;;
            esac

            print_info "Updating package list and installing prerequisites..."
            apt-get update -y || print_error "Failed to update package list."
            apt-get install -y ca-certificates curl gnupg lsb-release || print_error "Failed to install prerequisites."

            print_info "Adding Docker GPG key and repository..."
            mkdir -p /etc/apt/keyrings
            curl -fsSL "https://download.docker.com/linux/$distro/gpg" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg || print_error "Failed to download Docker GPG key."
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$distro $dist_version stable" > /etc/apt/sources.list.d/docker.list

            print_info "Updating package list..."
            apt-get update -y

            print_info "Installing Docker packages..."
            apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || print_error "Failed to install Docker."
            echo_docker_as_nonroot
            ;;

        centos|fedora|rhel)
            print_info "YUM-based system detected: $distro"
            if command_exists dnf; then
                pkg_manager="dnf"
                pkg_manager_flags="-y -q --best"
            else
                pkg_manager="yum"
                pkg_manager_flags="-y -q"
            fi

            print_info "Installing yum-utils and adding Docker repository..."
            $pkg_manager install $pkg_manager_flags yum-utils || print_error "Failed to install yum-utils."
            rm -f /etc/yum.repos.d/docker-ce.repo /etc/yum.repos.d/docker-ce-staging.repo
            yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo || print_error "Failed to add Docker repository."

            print_info "Installing Docker packages..."
            $pkg_manager install $pkg_manager_flags docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || print_error "Failed to install Docker."
            ;;

        sles)
            print_info "SLES system detected."
            if [ "$(uname -m)" != "s390x" ]; then
                print_error "Packages for SLES are currently only available for s390x."
            fi
            print_info "Adding Docker repository for SLES..."
            # SLES-specific installation commands should be added here.
            ;;

        *)
            if [ -z "$distro" ]; then
                if [[ "$(uname -s)" == *"Darwin"* ]]; then
                    print_error "Unsupported operating system 'macOS'. Please install Docker Desktop from https://www.docker.com/products/docker-desktop"
                fi
            fi
            print_error "Unsupported distribution: $distro"
            ;;
    esac

    print_info "Enabling and starting Docker service..."
    systemctl enable docker || print_error "Failed to enable Docker service."
    systemctl start docker || print_error "Failed to start Docker service."

    print_success "Docker installation completed successfully!"
}

###############################################
# Detect Package Manager (APT or YUM) and Run Installer
###############################################
if [ -x "$(command -v apt-get)" ]; then
    PM="apt-get"
    print_info "APT-based system detected."
elif [ -x "$(command -v yum)" ]; then
    PM="yum"
    print_info "YUM-based system detected."
else
    print_error "Unsupported package manager. Exiting."
fi

do_install
