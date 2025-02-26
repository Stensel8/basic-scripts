#!/bin/bash
set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'  # No color

# Functions for messaging
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

# Must be run as root or with sudo
if [ "$EUID" -ne 0 ]; then
    print_error "This script must be run as root or with sudo privileges. Exiting."
fi
# Check if kubectl is already installed
if command -v kubectl &>/dev/null; then
    print_warning "kubectl is already installed. Skipping installation."
    KUBECTL_INSTALLED=true
else
    KUBECTL_INSTALLED=false
fi
# Set the Kubernetes minor version.
# To upgrade to a different version, change this variable (e.g.: v1.27)
K8S_VERSION="v1.32"
# Define base URLs for different package formats
APT_BASE_URL="https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/"
RPM_BASE_URL="https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/rpm/"

if [ "$KUBECTL_INSTALLED" != "true" ]; then
    ###############################################################################
    # Installation for Debian-based distributions (apt)
    ###############################################################################
    if command -v apt-get &>/dev/null; then
        print_info "APT-based system detected. Installing kubectl using apt-get..."
        print_info "Updating package index..."
        apt-get update -y
        print_info "Installing required packages: apt-transport-https, ca-certificates, curl, gnupg..."
        apt-get install -y apt-transport-https ca-certificates curl gnupg || print_error "Failed to install required packages."
        # Create /etc/apt/keyrings if it does not exist (older releases may not have it)
        if [ ! -d "/etc/apt/keyrings" ]; then
            print_info "/etc/apt/keyrings directory not found. Creating it..."
            mkdir -p -m 755 /etc/apt/keyrings || print_error "Failed to create /etc/apt/keyrings."
        fi
        print_info "Downloading the Kubernetes public signing key..."
        curl -fsSL "${APT_BASE_URL}Release.key" | \
            gpg --dearmour -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg || print_error "Failed to download the signing key."

        print_info "Setting proper permissions for the keyring..."
        chmod 644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg || print_error "Failed to set permissions on the keyring."

        print_info "Adding the Kubernetes APT repository..."
        echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] ${APT_BASE_URL} /" \
            | tee /etc/apt/sources.list.d/kubernetes.list || print_error "Failed to create /etc/apt/sources.list.d/kubernetes.list."
        chmod 644 /etc/apt/sources.list.d/kubernetes.list || print_error "Failed to set permissions on /etc/apt/sources.list.d/kubernetes.list."
        print_info "Updating package index again..."
        apt-get update -y
        print_info "Installing kubectl..."
        apt-get install -y kubectl || print_error "Failed to install kubectl via apt-get."
    ###############################################################################
    # Installation for Red Hat-based distributions (yum/dnf)
    ###############################################################################
    elif command -v yum &>/dev/null || command -v dnf &>/dev/null; then
        print_info "YUM/DNF-based system detected. Installing kubectl using yum/dnf..."
        print_info "Creating the Kubernetes repo file at /etc/yum.repos.d/kubernetes.repo..."
        cat <<EOF | tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=${RPM_BASE_URL}
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=${RPM_BASE_URL}repodata/repomd.xml.key
exclude=kube*
EOF
        if command -v dnf &>/dev/null; then
            print_info "Installing kubectl via dnf..."
            dnf install -y kubectl --disableexcludes=kubernetes || print_error "Failed to install kubectl via dnf."
        else
            print_info "Installing kubectl via yum..."
            yum install -y kubectl --disableexcludes=kubernetes || print_error "Failed to install kubectl via yum."
        fi
    ###############################################################################
    # Installation for SUSE-based distributions (zypper)
    ###############################################################################
    elif command -v zypper &>/dev/null; then
        print_info "zypper-based system detected. Installing kubectl using zypper..."
        print_info "Creating the Kubernetes repo file at /etc/zypp/repos.d/kubernetes.repo..."
        cat <<EOF | tee /etc/zypp/repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=${RPM_BASE_URL}
enabled=1
gpgcheck=1
gpgkey=${RPM_BASE_URL}repodata/repomd.xml.key
EOF

        print_info "Refreshing repositories..."
        zypper refresh || print_error "Failed to refresh repositories with zypper."

        print_info "Installing kubectl via zypper..."
        zypper --non-interactive install -y kubectl || print_error "Failed to install kubectl via zypper."

    ###############################################################################
    # Fallback: Installation via Snap (if supported)
    ###############################################################################
    elif command -v snap &>/dev/null; then
        print_info "snap package manager detected. Installing kubectl using snap..."
        snap install kubectl --classic || print_error "Failed to install kubectl via snap."

    ###############################################################################
    # Fallback: Installation via Homebrew (Linuxbrew)
    ###############################################################################
    elif command -v brew &>/dev/null; then
        print_info "Homebrew detected. Installing kubectl using Homebrew..."
        brew install kubectl || print_error "Failed to install kubectl via Homebrew."

    else
        print_error "No supported package manager found. Supported methods: apt, yum/dnf, zypper, snap, or Homebrew."
    fi

    print_success "kubectl installation completed successfully!"

    # Verification steps
    print_info "Verify the installation with: kubectl version --client"
    print_info "If you have a Kubernetes cluster configured, check connectivity with: kubectl cluster-info"
fi

# Ask if the user wants to install minikube
read -p "Do you want to install minikube as well? (y/n): " install_minikube

if [[ "$install_minikube" == "y" ]]; then
    print_info "Installing minikube..."
    ARCH=$(uname -m)
    OS=$(uname -s)

    if [[ "$OS" == "Linux" ]]; then
        if [[ "$ARCH" == "x86_64" ]]; then
            curl -LO https://github.com/kubernetes/minikube/releases/latest/download/minikube-linux-amd64
            sudo install minikube-linux-amd64 /usr/local/bin/minikube && rm minikube-linux-amd64
        elif [[ "$ARCH" == "aarch64" ]]; then
            curl -LO https://github.com/kubernetes/minikube/releases/latest/download/minikube-linux-arm64
            sudo install minikube-linux-arm64 /usr/local/bin/minikube && rm minikube-linux-arm64
        elif [[ "$ARCH" == "armv7l" || "$ARCH" == "armv7" ]]; then
            curl -LO https://github.com/kubernetes/minikube/releases/latest/download/minikube-linux-arm
            sudo install minikube-linux-arm /usr/local/bin/minikube && rm minikube-linux-arm
        else
            print_error "Unsupported architecture for minikube installation: $ARCH"
        fi
        print_success "minikube installation completed successfully!"
    else
        print_error "Unsupported operating system for minikube installation: $OS"
    fi
fi
