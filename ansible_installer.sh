#!/bin/bash
#
# Ansible Installer Script – Combined and Improved Version
#
# This script installs Ansible in a Python virtual environment with robust
# error handling, detailed logging, package manager detection, Python version
# management (with fallback source build), and global Ansible configuration.
#
# Features:
#   • Colored logging (with console & log file output).
#   • Auto-detection of the system package manager (apt, dnf, or yum).
#   • System dependency installation with dynamic apt dependency checking.
#   • Attempts to use a system Python (default: 3.12) with a fallback
#     to building Python (default fallback: 3.13.2).
#   • Sets up a virtual environment, upgrades pip, and installs Ansible.
#   • Creates global symlinks for Ansible tools.
#   • Writes a basic global ansible.cfg in /etc/ansible using the venv’s collections path.
#
# Requirements: Run as root (e.g., via sudo) for installation of dependencies and global symlinks.
#

set -e
set -o pipefail

# === Color Codes for Console Output ===
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# === Default Settings (Overridable via environment variables) ===
REQ_PYTHON_VERSION="${REQ_PYTHON_VERSION:-3.12}"       # Preferred system Python version
BUILD_PYTHON_VERSION="${BUILD_PYTHON_VERSION:-3.13.2}" # Fallback Python version to build if needed
# Replace the placeholder below with the actual SHA256 checksum for BUILD_PYTHON_VERSION tarball.
BUILD_PYTHON_SHA256="${BUILD_PYTHON_SHA256:-<SHA256_checksum_for_3.13.2>}"
VENV_DIR="${VENV_DIR:-/opt/ansible-env}"                # Virtual environment directory
CLEANUP_SOURCE="${CLEANUP_SOURCE:-false}"              # Set to true to remove Python build files after installation
FORCE_BUILD="${FORCE_BUILD:-false}"                    # Force a rebuild even if the Python binary exists
SKIP_BUILD="${SKIP_BUILD:-false}"                      # Skip building Python if not found

# Timestamped log file
LOG_FILE="/tmp/ansible_install_$(date +%Y%m%d_%H%M%S).log"

# Derived Python build variables
PY_BUILD_TARBALL="Python-${BUILD_PYTHON_VERSION}.tgz"
PY_BUILD_URL="https://www.python.org/ftp/python/${BUILD_PYTHON_VERSION}/${PY_BUILD_TARBALL}"
PY_BUILD_SRC_DIR="/usr/src/Python-${BUILD_PYTHON_VERSION}"
PY_CMD=""  # Will hold the working Python command

# === Logging Functions ===
info() {
    echo -e "${BLUE}[INFO]${NC} $1" | tee -a "$LOG_FILE"
}
success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1" | tee -a "$LOG_FILE"
}
warn() {
    echo -e "${YELLOW}[WARN]${NC} $1" | tee -a "$LOG_FILE"
}
error() {
    echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"
    exit 1
}

# Log a command with visible output (to both console & log file).
log_cmd() {
    info "Executing: $@"
    if "$@" >> "$LOG_FILE" 2>&1 | tee -a "$LOG_FILE"; then
        return 0
    else
        error "Command failed: '$*'. Check log: $LOG_FILE"
    fi
}

# Log a command with output directed only to the log file.
log_cmd_no_tee() {
    info "Executing (output to log only): $@"
    if "$@" >> "$LOG_FILE" 2>&1; then
        return 0
    else
        error "Command failed: '$*'. Check log: $LOG_FILE"
    fi
}

# === Check for Root Privileges ===
if [ "$EUID" -ne 0 ]; then
    error "This script must be run as root (use sudo)."
fi

# === Package Manager Detection ===
PKG_MANAGER=""
if command -v apt &> /dev/null; then
    PKG_MANAGER="apt"
    PKG_INSTALL="apt install -y"
    PKG_UPDATE="apt update -y"
    PKG_UPGRADE="apt upgrade -y"
elif command -v dnf &> /dev/null; then
    PKG_MANAGER="dnf"
    PKG_INSTALL="dnf install -y"
    PKG_UPDATE="dnf check-update"
    PKG_UPGRADE="dnf upgrade -y"
elif command -v yum &> /dev/null; then
    PKG_MANAGER="yum"
    PKG_INSTALL="yum install -y"
    PKG_UPDATE="yum check-update"
    PKG_UPGRADE="yum update -y"
else
    error "Unsupported package manager. Exiting."
fi
info "Using package manager: ${PKG_MANAGER}"

# === Update System Packages ===
warn "Updating system packages (output in log)..."
case $PKG_MANAGER in
    apt)
        log_cmd_no_tee env DEBIAN_FRONTEND=noninteractive $PKG_UPDATE
        log_cmd_no_tee env DEBIAN_FRONTEND=noninteractive $PKG_UPGRADE
        ;;
    dnf|yum)
        log_cmd_no_tee $PKG_UPGRADE
        ;;
esac

# === Install Base Dependencies ===
info "Installing system dependencies..."
declare -A deps
if [ "$PKG_MANAGER" = "apt" ]; then
    # Build a dependency list for apt; check if libmpdec-dev exists before adding it.
    apt_deps="build-essential libssl-dev zlib1g-dev libncurses5-dev libffi-dev libsqlite3-dev libbz2-dev libreadline-dev liblzma-dev tk-dev make git wget curl python3-pip python3-venv software-properties-common"
    if apt-cache show libmpdec-dev > /dev/null 2>&1; then
         apt_deps+=" libmpdec-dev"
    fi
    deps["apt"]="$apt_deps"
elif [ "$PKG_MANAGER" = "dnf" ]; then
    deps["dnf"]="gcc openssl-devel bzip2-devel libffi-devel zlib-devel ncurses-devel sqlite-devel xz-devel readline-devel tk-devel make git wget curl mpdecimal-devel python3-pip python3-virtualenv"
elif [ "$PKG_MANAGER" = "yum" ]; then
    deps["yum"]="gcc openssl-devel bzip2-devel libffi-devel zlib-devel ncurses-devel sqlite-devel xz-devel readline-devel tk-devel make git wget curl mpdecimal-devel python3-pip python3-virtualenv"
fi
log_cmd_no_tee $PKG_INSTALL ${deps[$PKG_MANAGER]}

# === Determine Suitable Python ===
info "Searching for Python ${REQ_PYTHON_VERSION}..."
if command -v "python${REQ_PYTHON_VERSION}" &>/dev/null; then
    PY_CMD="python${REQ_PYTHON_VERSION}"
    info "Found system Python: ${PY_CMD}"
elif [ "$PKG_MANAGER" = "apt" ] && [ "$FORCE_BUILD" = false ]; then
    info "Attempting to install Python ${REQ_PYTHON_VERSION} via deadsnakes PPA..."
    if command -v add-apt-repository &>/dev/null; then
        log_cmd_no_tee add-apt-repository -y ppa:deadsnakes/ppa || warn "Could not add deadsnakes PPA. Proceeding without it."
        log_cmd_no_tee apt update -y
        log_cmd_no_tee apt install -y "python${REQ_PYTHON_VERSION}" "python${REQ_PYTHON_VERSION}-venv" || warn "Failed to install python${REQ_PYTHON_VERSION} from PPA."
    else
        warn "Command 'add-apt-repository' not found. Skipping PPA method."
    fi
    if command -v "python${REQ_PYTHON_VERSION}" &>/dev/null; then
        PY_CMD="python${REQ_PYTHON_VERSION}"
        info "Successfully installed Python from PPA: ${PY_CMD}"
    else
        info "Python ${REQ_PYTHON_VERSION} not found via system or PPA."
    fi
fi

# === Build Python from Source if Necessary ===
if [ -z "$PY_CMD" ] && [ "$SKIP_BUILD" = false ]; then
    info "No suitable Python found. Building Python ${BUILD_PYTHON_VERSION} from source."
    TARGET_PY_BIN="/usr/local/bin/python${BUILD_PYTHON_VERSION%.*}"
    if [ -x "$TARGET_PY_BIN" ] && [ "$FORCE_BUILD" = false ]; then
        info "Python ${BUILD_PYTHON_VERSION} already exists at ${TARGET_PY_BIN}."
        PY_CMD="$TARGET_PY_BIN"
    else
        cd /usr/src
        if [ ! -f "$PY_BUILD_TARBALL" ] || ! echo "$BUILD_PYTHON_SHA256  $PY_BUILD_TARBALL" | sha256sum --check --status; then
            warn "Downloading Python ${BUILD_PYTHON_VERSION} tarball..."
            rm -f "$PY_BUILD_TARBALL"
            log_cmd wget -q "$PY_BUILD_URL"
            if ! echo "$BUILD_PYTHON_SHA256  $PY_BUILD_TARBALL" | sha256sum --check --status; then
                error "SHA256 checksum mismatch for ${PY_BUILD_TARBALL}! Aborting."
            fi
            info "SHA256 checksum verified for ${PY_BUILD_TARBALL}."
        else
            info "Tarball ${PY_BUILD_TARBALL} exists and checksum is valid."
        fi

        if [ -d "$PY_BUILD_SRC_DIR" ]; then
            info "Removing existing source directory: ${PY_BUILD_SRC_DIR}"
            rm -rf "$PY_BUILD_SRC_DIR"
        fi
        info "Extracting Python source..."
        log_cmd tar -xzf "$PY_BUILD_TARBALL"
        cd "$PY_BUILD_SRC_DIR"
        info "Configuring Python build..."
        log_cmd_no_tee ./configure --enable-optimizations --with-system-libmpdec --prefix=/usr/local
        info "Building Python ${BUILD_PYTHON_VERSION} (this may take several minutes)..."
        log_cmd_no_tee make -j"$(nproc)"
        info "Installing Python using altinstall..."
        log_cmd_no_tee make altinstall
        if [ -x "$TARGET_PY_BIN" ]; then
            info "Python ${BUILD_PYTHON_VERSION} installed successfully."
            PY_CMD="$TARGET_PY_BIN"
        else
            error "Python build/installation failed. Aborting."
        fi
    fi
elif [ -z "$PY_CMD" ]; then
    error "Could not find or install a suitable Python version (${REQ_PYTHON_VERSION} or ${BUILD_PYTHON_VERSION}). Aborting."
fi

# Final check for the Python command
if [ -z "$PY_CMD" ] || ! command -v "$PY_CMD" &>/dev/null; then
    error "Unable to determine a working Python command (PY_CMD='${PY_CMD}'). Aborting."
fi
info "Using Python command: ${PY_CMD}"
"$PY_CMD" --version >> "$LOG_FILE" 2>&1

# === Create Virtual Environment ===
if [ -d "$VENV_DIR" ]; then
    info "Virtual environment already exists at ${VENV_DIR}. Skipping creation."
else
    info "Creating virtual environment at ${VENV_DIR} using ${PY_CMD}..."
    mkdir -p "$(dirname "$VENV_DIR")"
    log_cmd "$PY_CMD" -m venv "$VENV_DIR"
fi

# === Install/Upgrade Pip and Ansible in the Virtual Environment ===
info "Activating virtual environment and installing/upgrading pip and Ansible..."
(
    source "$VENV_DIR/bin/activate"
    if ! command -v pip &>/dev/null; then
        error "pip not found in virtual environment. Activation may have failed."
    fi
    pip --version >> "$LOG_FILE" 2>&1
    log_cmd_no_tee pip install --upgrade pip setuptools wheel
    log_cmd_no_tee pip install ansible
    # === Install additional Ansible dependencies (for connecting with Windows based systems/WinRM) ===
    log_cmd_no_tee pip install pywinrm requests-ntlm
    log_cmd_no_tee pip install ansible
) || error "Failed during virtual environment operations."

# === Create Global Symlinks for Ansible Tools ===
info "Creating global symlinks for Ansible tools in /usr/local/bin..."
for tool in ansible ansible-playbook ansible-galaxy ansible-doc ansible-config ansible-console ansible-connection ansible-inventory ansible-vault; do
    if [ -f "$VENV_DIR/bin/$tool" ]; then
        log_cmd ln -sf "$VENV_DIR/bin/$tool" "/usr/local/bin/$tool"
    else
        warn "Executable ${tool} not found in ${VENV_DIR}/bin. Skipping symlink."
    fi
done

# === Configure Global Ansible Settings (ansible.cfg) ===
info "Configuring global Ansible settings..."
ANSIBLE_CFG_DIR="/etc/ansible"
ANSIBLE_CFG="${ANSIBLE_CFG_DIR}/ansible.cfg"
log_cmd mkdir -p "$ANSIBLE_CFG_DIR"
# Determine the site-packages directory from the virtual environment
VENV_SITE_PACKAGES=$("$VENV_DIR/bin/python" -c "import site; print(site.getsitepackages()[0])")
if [ -z "$VENV_SITE_PACKAGES" ] || [ ! -d "$VENV_SITE_PACKAGES" ]; then
    error "Unable to determine the site-packages directory within the virtual environment!"
fi
VENV_COLLECTIONS_PATH="${VENV_SITE_PACKAGES}/ansible_collections"
cat > "$ANSIBLE_CFG" <<EOF
# Global Ansible configuration managed by installation script
[defaults]
collections_path = ${VENV_COLLECTIONS_PATH}:/usr/share/ansible/collections
EOF
success "Updated global Ansible configuration at ${ANSIBLE_CFG}."

# === Optional Cleanup of Python Source Files ===
if [ "$CLEANUP_SOURCE" = true ] && [ -d "$PY_BUILD_SRC_DIR" ]; then
    info "Cleaning up Python source files..."
    log_cmd rm -rf "$PY_BUILD_SRC_DIR"
    log_cmd rm -f "/usr/src/$PY_BUILD_TARBALL"
fi

# === Final Verification and Output ===
info "Verifying installation..."
PY_VER=$("$PY_CMD" --version 2>&1) || PY_VER="N/A"
ANSIBLE_VER=$(ansible --version | head -n 1 2>&1) || ANSIBLE_VER="N/A"
ANSIBLE_CFG_INFO=$(ansible --version | grep "config file" 2>&1) || ANSIBLE_CFG_INFO="Config file not reported"

echo -e "\n${GREEN}==============================================================${NC}"
success "Ansible installation script completed successfully!"
echo -e "${GREEN}==============================================================${NC}\n"
echo -e "${BLUE}Python Used:${NC}              ${GREEN}${PY_CMD} (${PY_VER})${NC}"
echo -e "${BLUE}Ansible Version:${NC}          ${GREEN}${ANSIBLE_VER}${NC}"
echo -e "${BLUE}Ansible Config:${NC}           ${GREEN}${ANSIBLE_CFG_INFO}${NC}"
echo -e "${BLUE}Virtual Environment:${NC}      ${GREEN}${VENV_DIR}${NC}"
echo ""
echo -e "${BLUE}To activate manually:${NC}     ${GREEN}source ${VENV_DIR}/bin/activate${NC}"
echo -e "${BLUE}To uninstall (basic):${NC}       ${GREEN}sudo rm -rf ${VENV_DIR} /usr/local/bin/ansible* /etc/ansible${NC}"
echo -e "${BLUE}Log File:${NC}                 ${GREEN}${LOG_FILE}${NC}"
echo ""
info "System Information:"
uname -a | tee -a "$LOG_FILE"
date | tee -a "$LOG_FILE"
success "Installation Finished."

exit 0
