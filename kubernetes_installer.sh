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
    echo -e "<span class="math-inline">\{BLUE\}\[INFO\]</span>{NC} <span class="math-inline">1"
\}
function print\_success \{
echo \-e "</span>{GREEN}[SUCCESS]${NC} <span class="math-inline">1"
\}
function print\_warning \{
echo \-e "</span>{YELLOW}[WARNING]${NC} <span class="math-inline">1"
\}
function print\_error \{
echo \-e "</span>{RED}[ERROR]${NC} $1"
    exit 1
}

# Must be run as root or with sudo
if [ "<span class="math-inline">EUID" \-ne 0 \]; then
print\_error "This script must be run as root or with sudo privileges\. Exiting\."
fi
\# Check if kubectl is already installed
if command \-v kubectl &\>/dev/null; then
print\_warning "kubectl is already installed\. Skipping installation\."
KUBECTL\_INSTALLED\=true
else
KUBECTL\_INSTALLED\=false
fi
\# Set the Kubernetes minor version\.
\# To upgrade to a different version, change this variable \(e\.g\.\: v1\.27\)
K8S\_VERSION\="v1\.32"
\# Define base URLs for different package formats
APT\_BASE\_URL\="https\://pkgs\.k8s\.io/core\:/stable\:/</span>{K8S_VERSION}/deb/"
RPM_BASE_URL="https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/rpm/"

if [ "<span class="math-inline">KUBECTL\_INSTALLED" \!\= "true" \]; then
\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#
\# Installation for Debian\-based distributions \(apt\)
\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#
if command \-v apt\-get &\>/dev/null; then
print\_info "APT\-based system detected\. Installing kubectl using apt\-get\.\.\."
print\_info "Updating package index\.\.\."
apt\-get update \-y
print\_info "Installing required packages\: apt\-transport\-https, ca\-certificates, curl, gnupg\.\.\."
apt\-get install \-y apt\-transport\-https ca\-certificates curl gnupg \|\| print\_error "Failed to install required packages\."
\# Create /etc/apt/keyrings if it does not exist \(older releases may not have it\)
if \[ \! \-d "/etc/apt/keyrings" \]; then
print\_info "/etc/apt/keyrings directory not found\. Creating it\.\.\."
mkdir \-p \-m 755 /etc/apt/keyrings \|\| print\_error "Failed to create /etc/apt/keyrings\."
fi
print\_info "Downloading the Kubernetes public signing key\.\.\."
curl \-fsSL "</span>{APT_BASE_URL}Release.key" | \
            gpg --dearmour -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg || print_error "Failed to download the signing key."

        print_info "Setting proper permissions for the keyring..."
        chmod 644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg || print_error "Failed to set permissions on the keyring."

        print_info "Adding the Kubernetes APT repository..."
        echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] <span class="math-inline">\{APT\_BASE\_URL\} /" \\
\| tee /etc/apt/sources\.list\.d/kubernetes\.list \|\| print\_error "Failed to create /etc/apt/sources\.list\.d/kubernetes\.list\."
chmod 644 /etc/apt/sources\.list\.d/kubernetes\.list \|\| print\_error "Failed to set permissions on /etc/apt/sources\.list\.d/kubernetes\.list\."
print\_info "Updating package index again\.\.\."
apt\-get update \-y
print\_info "Installing kubectl\.\.\."
apt\-get install \-y kubectl \|\| print\_error "Failed to install kubectl via apt\-get\."
\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#
\# Installation for Red Hat\-based distributions \(yum/dnf\)
\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#
elif command \-v yum &\>/dev/null \|\| command \-v dnf &\>/dev/null; then
print\_info "YUM/DNF\-based system detected\. Installing kubectl using yum/dnf\.\.\."
print\_info "Creating the Kubernetes repo file at /etc/yum\.repos\.d/kubernetes\.repo\.\.\."
cat <<EOF \| tee /etc/yum\.repos\.d/kubernetes\.repo
\[kubernetes\]
name\=Kubernetes
baseurl\=</span>{RPM_BASE_URL}
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=<span class="math-inline">\{RPM\_BASE\_URL\}repodata/repomd\.xml\.key
exclude\=kube\*
EOF
if command \-v dnf &\>/dev/null; then
print\_info "Installing kubectl via dnf\.\.\."
dnf install \-y kubectl \-\-disableexcludes\=kubernetes \|\| print\_error "Failed to install kubectl via dnf\."
else
print\_info "Installing kubectl via yum\.\.\."
yum install \-y kubectl \-\-disableexcludes\=kubernetes \|\| print\_error "Failed to install kubectl via yum\."
fi
\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#
\# Installation for SUSE\-based distributions \(zypper\)
\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#\#
elif command \-v zypper &\>/dev/null; then
print\_info "zypper\-based system detected\. Installing kubectl using zypper\.\.\."
print\_info "Creating the Kubernetes repo file at /etc/zypp/repos\.d/kubernetes\.repo\.\.\."
cat <<EOF \| tee /etc/zypp/repos\.d/kubernetes\.repo
\[kubernetes\]
name\=Kubernetes
baseurl\=</span>{RPM_BASE_URL}
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

if [[ "<span class="math-inline">install\_minikube" \=\= "y" \]\]; then
print\_info "Installing minikube\.\.\."
ARCH\=</span>(uname -m)
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
            sudo install minikube-linux-arm /usr/local/bin/minikube &&