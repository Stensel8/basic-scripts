#!/bin/bash
set -e

###############################################
# Fallback handler: This function is called when an error occurs
###############################################
fallback_installer() {
    print_warning "An error occurred during the installation process. Defaulting to the fallback installer."
    curl -fsSL https://get.docker.com | bash || {
        print_error "Fallback installer (get.docker.com) also failed."
    }
    exit 0
}
# Activate the error trap
trap 'fallback_installer' ERR

###############################################
# docker_installer.sh
###############################################

# Define color codes for output messages
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'  # No Color

# Function to print informational messages
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

# Function to print success messages
print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

# Function to print warning messages
print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Function to print error messages and exit
print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

# Ensure the script is run as root or with sudo privileges
if [ "$EUID" -ne 0 ]; then
    print_error "This script must be run as root or with sudo privileges. Exiting."
fi

###############################################
# Utility Functions
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

# Show a deprecation warning for unsupported or EOL distributions
deprecation_notice() {
    local distro="$1"
    local version="$2"
    print_warning "This Linux distribution ($distro $version) is deprecated and no longer supported."
    print_info "Consider upgrading to a newer version of $distro."
    sleep 5
}

# Print instructions to run Docker as a non-root user (rootless mode)
print_docker_rootless_info() {
    print_info "To run Docker as a non-root user, consider installing rootless mode:"
    echo "    dockerd-rootless-setuptool.sh install"
    print_info "See https://docs.docker.com/go/rootless/ for more information."
}

# Check if the distribution is forked (e.g., Linux Mint)
check_forked_distro() {
    if command_exists lsb_release; then
        set +e
        lsb_release -a -u > /dev/null 2>&1
        if [ "$?" = "0" ]; then
            print_info "Forked distribution detected. Using upstream release information."
        fi
        set -e
    fi
}

# Detect distribution using /etc/os-release. Also check ID_LIKE for broader compatibility.
get_distribution() {
    if [ -r /etc/os-release ]; then
        . /etc/os-release
        # Use ID if available; fallback to ID_LIKE if necessary
        echo "${ID,,}"
    else
        echo "unknown"
    fi
}

# Get additional distro info (e.g., ID_LIKE) for finer classification
get_distro_like() {
    if [ -r /etc/os-release ]; then
        . /etc/os-release
        echo "${ID_LIKE,,}"
    else
        echo ""
    fi
}

###############################################
# Main Installation Function
###############################################
do_install() {
    print_info "Starting Docker installation..."

    # Check if Docker is already installed
    if command_exists docker; then
        print_warning "Docker is already installed. Skipping installation."
        exit 0
    fi

    # Detect distribution and additional info
    distro=$(get_distribution)
    distro_like=$(get_distro_like)
    check_forked_distro

    case "$distro" in
        ubuntu|debian|raspbian)
            print_info "APT-based system detected: $distro"
            # Get distribution codename (using lsb_release or /etc/os-release)
            if command_exists lsb_release; then
                codename=$(lsb_release -cs)
            else
                codename=$(grep VERSION_CODENAME /etc/os-release | cut -d'=' -f2)
            fi

            # Warn on deprecated older releases if needed
            if [ "$distro" == "ubuntu" ] && { [ "$codename" = "trusty" ] || [ "$codename" = "xenial" ]; }; then
                deprecation_notice "$distro" "$codename"
            elif [ "$distro" == "debian" ] && [ "$codename" = "jessie" ]; then
                deprecation_notice "$distro" "$codename"
            fi

            print_info "Updating package list and installing prerequisites..."
            apt-get update -y || print_error "Failed to update package list."
            apt-get install -y ca-certificates curl gnupg lsb-release || print_error "Failed to install prerequisites."

            print_info "Adding Docker GPG key and repository..."
            mkdir -p /etc/apt/keyrings
            curl -fsSL "https://download.docker.com/linux/$distro/gpg" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg || print_error "Failed to download Docker GPG key."
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$distro $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list

            print_info "Updating package list..."
            apt-get update -y

            print_info "Installing Docker packages..."
            apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || print_error "Failed to install Docker."
            print_docker_rootless_info
            ;;
        centos|fedora|rhel)
            print_info "YUM/DNF-based system detected: $distro"
            if command_exists dnf; then
                pkg_manager="dnf"
                pkg_flags="-y -q --best"
            else
                pkg_manager="yum"
                pkg_flags="-y -q"
            fi

            print_info "Installing yum-utils and adding Docker repository..."
            print_info "Installing dnf-plugins-core for config-manager support..."
            $pkg_manager install $pkg_flags dnf-plugins-core || print_warning "Failed to install dnf-plugins-core, continuing."
            $pkg_manager install $pkg_flags yum-utils || print_error "Failed to install yum-utils."
            rm -f /etc/yum.repos.d/docker-ce.repo /etc/yum.repos.d/docker-ce-staging.repo
            print_info "Adding Docker CE repo (Fedora 41+)…"
            $pkg_manager config-manager addrepo --from-repofile=https://download.docker.com/linux/fedora/docker-ce.repo \
            || print_error "Failed to add Docker repository."


            print_info "Installing Docker packages..."
            $pkg_manager install $pkg_flags docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || print_error "Failed to install Docker."
            ;;
        amzn)
            print_info "Amazon Linux detected."
            # Distinguish between Amazon Linux 2 and Amazon Linux 2023 based on /etc/os-release content
            if grep -qi "2023" /etc/os-release; then
                print_info "Amazon Linux 2023 detected. Using CentOS repository override."
                override_release="9"
            else
                print_info "Assuming Amazon Linux 2. Using standard installation."
                override_release="8"
            fi

            if command_exists dnf; then
                pkg_manager="dnf"
                pkg_flags="-y -q --best"
            else
                pkg_manager="yum"
                pkg_flags="-y -q"
            fi

            print_info "Installing dnf-plugins-core..."
            $pkg_manager install $pkg_flags dnf-plugins-core || print_error "Failed to install dnf-plugins-core."

            print_info "Adding Docker repository from CentOS..."
            print_info "Adding Docker CE repo (Fedora 41+)…"
$pkg_manager config-manager addrepo --from-repofile=https://download.docker.com/linux/fedora/docker-ce.repo \
    || print_error "Failed to add Docker repository."


            print_info "Overriding \$releasever in the repo file to '$override_release'..."
            sed -i "s/\\\$releasever/$override_release/g" /etc/yum.repos.d/docker-ce.repo

            print_info "Installing Docker packages..."
            $pkg_manager install $pkg_flags docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || print_error "Failed to install Docker."
            ;;
        sles)
            print_info "SLES system detected."
            if [ "$(uname -m)" != "s390x" ]; then
                print_error "SLES packages are currently only available for s390x architecture."
            fi
            print_info "Adding Docker repository for SLES..."
            # Insert SLES-specific installation commands here.
            #//TODO:
            ;;
        *)
            # Special case for macOS (Darwin)
            if [[ "$(uname -s)" == *"Darwin"* ]]; then
                print_error "Unsupported operating system 'macOS'. Please install Docker Desktop from https://www.docker.com/products/docker-desktop"
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
# Verify Package Manager Existence and Start Installation
###############################################
if command_exists apt-get; then
    print_info "APT-based package manager detected."
elif command_exists yum || command_exists dnf; then
    print_info "YUM/DNF-based package manager detected."
else
    print_error "No supported package manager found. Exiting."
fi

do_install
