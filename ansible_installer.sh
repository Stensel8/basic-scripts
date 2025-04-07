#!/bin/bash
set -e # Exit on error
set -o pipefail # Exit on pipe failures

# === Default Settings ===
# Allow overriding via environment variables or command-line flags
REQ_PYTHON_VERSION="${REQ_PYTHON_VERSION:-3.12}" # Prefer 3.12 first
BUILD_PYTHON_VERSION="${BUILD_PYTHON_VERSION:-3.13.2}" # Fallback build version
# TODO: Fetch SHA256 dynamically or update this when BUILD_PYTHON_VERSION changes
BUILD_PYTHON_SHA256="${BUILD_PYTHON_SHA256:-<SHA256_checksum_for_3.13.2>}"
VENV_DIR="${VENV_DIR:-/opt/ansible-env}"
LOG_FILE="/tmp/ansible_install_$(date +%Y%m%d_%H%M%S).log"
CLEANUP_SOURCE=false
FORCE_BUILD=false
SKIP_BUILD=false
# TODO: Add getopt for command-line parsing (--python-version, --venv-dir, --cleanup, --force-build, etc.)

# === Styling ===
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC} $1" | tee -a "$LOG_FILE"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1" | tee -a "$LOG_FILE"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1" | tee -a "$LOG_FILE"; }
error()   { echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"; exit 1; }
log_cmd() {
    info "Executing: $@"
    # Run command, redirect stdout/stderr to log file AND show on console via tee
    if "$@" >> "$LOG_FILE" 2>&1 | tee -a "$LOG_FILE"; then
        return 0
    else
        error "Command failed: '$*'. Check log: $LOG_FILE"
        # No exit 1 here, error() already does that
    fi
}
log_cmd_no_tee() {
    info "Executing (output to log only): $@"
    if "$@" >> "$LOG_FILE" 2>&1; then
        return 0
    else
        error "Command failed: '$*'. Check log: $LOG_FILE"
    fi
}


# === Variables ===
# Derived variables
PY_BUILD_TARBALL="Python-$BUILD_PYTHON_VERSION.tgz"
PY_BUILD_URL="https://www.python.org/ftp/python/$BUILD_PYTHON_VERSION/$PY_BUILD_TARBALL"
PY_BUILD_SRC_DIR="/usr/src/Python-$BUILD_PYTHON_VERSION"
PY_CMD="" # Will be determined

# === Check root ===
[ "$EUID" -ne 0 ] && error "This script must be run as root (sudo)."

# === Log Start ===
info "Starting Ansible installation script..."
info "Log file: $LOG_FILE"
info "Requested Python: $REQ_PYTHON_VERSION (will build $BUILD_PYTHON_VERSION if needed)"
info "Ansible Virtual Env Dir: $VENV_DIR"

# === Detect distro ===
if [ -f /etc/os-release ]; then . /etc/os-release; DISTRO_ID=${ID,,}; else DISTRO_ID="unknown"; fi
info "Detected distribution: $DISTRO_ID"

# === Package Manager Detection ===
PKG_MANAGER=""
if command -v apt &> /dev/null; then PKG_MANAGER="apt"; PKG_INSTALL="apt install -y"; PKG_UPDATE="apt update -y"; PKG_UPGRADE="apt upgrade -y";
elif command -v dnf &> /dev/null; then PKG_MANAGER="dnf"; PKG_INSTALL="dnf install -y"; PKG_UPDATE="dnf check-update"; PKG_UPGRADE="dnf upgrade -y";
elif command -v yum &> /dev/null; then PKG_MANAGER="yum"; PKG_INSTALL="yum install -y"; PKG_UPDATE="yum check-update"; PKG_UPGRADE="yum update -y";
else error "Unsupported package manager."; fi
info "Using package manager: $PKG_MANAGER"

# === Update system (Optional? Could be risky) ===
warn "Updating system packages (output in log)..."
case $PKG_MANAGER in
    apt) log_cmd_no_tee env DEBIAN_FRONTEND=noninteractive $PKG_UPDATE; log_cmd_no_tee env DEBIAN_FRONTEND=noninteractive $PKG_UPGRADE ;;
    dnf|yum) log_cmd_no_tee $PKG_UPGRADE ;;
esac

# === Install Dependencies ===
info "Installing base dependencies (output in log)..."
# Define dependencies per package manager
declare -A deps
deps["apt"]="build-essential libssl-dev zlib1g-dev libncurses5-dev libffi-dev libsqlite3-dev libbz2-dev libreadline-dev liblzma-dev tk-dev make git wget curl libmpdec-dev python3-pip python3-venv software-properties-common"
deps["dnf"]="gcc openssl-devel bzip2-devel libffi-devel zlib-devel ncurses-devel sqlite-devel xz-devel readline-devel tk-devel make git wget curl mpdecimal-devel python3-pip python3-virtualenv"
deps["yum"]="gcc openssl-devel bzip2-devel libffi-devel zlib-devel ncurses-devel sqlite-devel xz-devel readline-devel tk-devel make git wget curl mpdecimal-devel python3-pip python3-virtualenv" # Adjust for older yum if needed

log_cmd_no_tee $PKG_INSTALL ${deps[$PKG_MANAGER]}

# === Find Suitable Python ===
info "Looking for suitable Python ($REQ_PYTHON_VERSION)..."

# Check if requested version command exists
if command -v "python${REQ_PYTHON_VERSION}" &>/dev/null; then
    PY_CMD="python${REQ_PYTHON_VERSION}"
    info "Found existing system Python: $PY_CMD"
# Try PPA for Debian/Ubuntu if not found and not forcing build
elif [ "$PKG_MANAGER" == "apt" ] && [ "$FORCE_BUILD" = false ]; then
    info "Trying to install Python $REQ_PYTHON_VERSION via deadsnakes PPA..."
    # Check if add-apt-repository exists
    if command -v add-apt-repository &>/dev/null; then
        if ! command -v "python${REQ_PYTHON_VERSION}" &>/dev/null; then
            log_cmd_no_tee add-apt-repository -y ppa:deadsnakes/ppa || warn "Could not add deadsnakes PPA. Proceeding without it."
            log_cmd_no_tee apt update -y
            # Try installing, but don't fail script if it doesn't work
            log_cmd_no_tee apt install -y "python${REQ_PYTHON_VERSION}" "python${REQ_PYTHON_VERSION}-venv" || warn "Failed to install python${REQ_PYTHON_VERSION} from PPA."
        fi
        # Re-check if it's available now
        if command -v "python${REQ_PYTHON_VERSION}" &>/dev/null; then
            PY_CMD="python${REQ_PYTHON_VERSION}"
            info "Successfully installed Python from PPA: $PY_CMD"
        else
             info "Python $REQ_PYTHON_VERSION not found via system or PPA."
        fi
    else
        warn "Command 'add-apt-repository' not found. Cannot use PPA."
    fi
fi

# === Build Python from source if no suitable Python found ===
if [ -z "$PY_CMD" ] && [ "$SKIP_BUILD" = false ]; then
    info "No suitable Python found or PPA failed. Attempting to build Python $BUILD_PYTHON_VERSION from source."
    TARGET_PY_BIN="/usr/local/bin/python${BUILD_PYTHON_VERSION%.*}" # e.g., /usr/local/bin/python3.13

    if [ -x "$TARGET_PY_BIN" ] && [ "$FORCE_BUILD" = false ]; then
        info "Python $BUILD_PYTHON_VERSION already built and installed ($TARGET_PY_BIN). Skipping build."
        PY_CMD="$TARGET_PY_BIN"
    else
        # Check disk space in /usr/src (e.g., need ~1GB?)
        # check_disk_space /usr/src 1000 # Implement this function

        cd /usr/src
        # Verify checksum (SHA256)
        if [ ! -f "$PY_BUILD_TARBALL" ] || ! echo "$BUILD_PYTHON_SHA256  $PY_BUILD_TARBALL" | sha256sum --check --status; then
            warn "Downloading fresh Python $BUILD_PYTHON_VERSION tarball..."
            rm -f "$PY_BUILD_TARBALL"
            log_cmd wget -q "$PY_BUILD_URL" # Use log_cmd for better feedback
             # Verify again after download
            if ! echo "$BUILD_PYTHON_SHA256  $PY_BUILD_TARBALL" | sha256sum --check --status; then
                 error "SHA256 checksum mismatch for downloaded $PY_BUILD_TARBALL! Aborting."
            fi
             info "SHA256 checksum verified for $PY_BUILD_TARBALL."
        else
            info "Python tarball $PY_BUILD_TARBALL already exists and checksum is valid."
        fi

        if [ -d "$PY_BUILD_SRC_DIR" ]; then
             info "Removing existing source directory: $PY_BUILD_SRC_DIR"
             rm -rf "$PY_BUILD_SRC_DIR"
        fi
        info "Extracting Python source..."
        log_cmd tar -xzf "$PY_BUILD_TARBALL"

        cd "$PY_BUILD_SRC_DIR"
        info "Configuring Python build (Output to log)..."
        # Log configure output for debugging, don't tee
        log_cmd_no_tee ./configure --enable-optimizations --with-system-libmpdec --prefix=/usr/local

        info "Building Python $BUILD_PYTHON_VERSION (this can take several minutes)..."
        # Log make output, maybe tee for progress? Requires careful handling of large output.
        # Consider logging make to file, but printing dots or progress bar to console.
        log_cmd_no_tee make -j"$(nproc)" # Using log_cmd_no_tee to avoid flooding console, check log on failure

        info "Installing Python (altinstall)..."
        log_cmd_no_tee make altinstall # altinstall is crucial

        # Verify installation
        if [ -x "$TARGET_PY_BIN" ]; then
            info "Python $BUILD_PYTHON_VERSION successfully built and installed."
            PY_CMD="$TARGET_PY_BIN"
        else
            error "Python build/installation failed. Check log: $LOG_FILE"
        fi
    fi
# Handle case where no Python found and building was skipped or failed
elif [ -z "$PY_CMD" ]; then
     error "Could not find or install a suitable Python version ($REQ_PYTHON_VERSION or $BUILD_PYTHON_VERSION). Aborting."
fi

# === Final Python Check ===
if [ -z "$PY_CMD" ] || ! command -v $PY_CMD &>/dev/null; then
    error "Failed to determine a working Python command (PY_CMD='$PY_CMD'). Aborting."
fi
info "Using Python command: $PY_CMD"
$PY_CMD --version >> "$LOG_FILE" 2>&1 # Log version

# === Virtualenv Setup ===
if [ -d "$VENV_DIR" ]; then
    info "Ansible virtual environment '$VENV_DIR' already exists. Skipping creation."
    # Optional: Add check if venv python matches $PY_CMD and recreate/warn if not?
else
    info "Creating Ansible virtual environment in '$VENV_DIR'..."
    # Ensure the parent directory exists if VENV_DIR is nested (e.g., /some/path/ansible-env)
    mkdir -p "$(dirname "$VENV_DIR")"
    log_cmd "$PY_CMD" -m venv "$VENV_DIR"
fi

# === Activate Venv (within subshell for safety) ===
info "Installing/Updating Ansible in virtual environment..."
(
    # Source activation script directly
    source "$VENV_DIR/bin/activate"

    # Verify pip is working inside venv
    if ! command -v pip &>/dev/null; then
        error "pip command not found within the virtual environment '$VENV_DIR'. Activation might have failed."
    fi
    pip --version >> "$LOG_FILE" 2>&1

    # Upgrade pip, setuptools, wheel first (quietly to reduce noise)
    log_cmd_no_tee pip install --upgrade pip setuptools wheel

    # Install Ansible (quietly)
    log_cmd_no_tee pip install ansible

    # Deactivate is automatic when subshell exits
) || error "Failed during virtual environment operations (pip install?). Check log." # Catch errors in the subshell

# === Symlink globally ===
info "Creating global symlinks in /usr/local/bin..."
for tool in ansible ansible-playbook ansible-galaxy ansible-doc ansible-config ansible-console ansible-connection ansible-inventory ansible-vault; do
     if [ -f "$VENV_DIR/bin/$tool" ]; then
         log_cmd ln -sf "$VENV_DIR/bin/$tool" "/usr/local/bin/$tool"
     else
         warn "Executable $tool not found in venv $VENV_DIR/bin/. Skipping symlink."
     fi
done

# === Configure ansible.cfg (Minimalist approach) ===
ANSIBLE_CFG_DIR="/etc/ansible"
ANSIBLE_CFG="$ANSIBLE_CFG_DIR/ansible.cfg"
info "Configuring global Ansible settings ($ANSIBLE_CFG)..."
log_cmd mkdir -p "$ANSIBLE_CFG_DIR"

# Get the Python site-packages path *within the venv*
# This relies on standard venv layout but is more robust than parsing pythonX.Y
VENV_SITE_PACKAGES=$("$VENV_DIR/bin/python" -c "import site; print(site.getsitepackages()[0])")
if [ -z "$VENV_SITE_PACKAGES" ] || [ ! -d "$VENV_SITE_PACKAGES" ]; then
    error "Could not determine site-packages directory within the virtual environment!"
fi
VENV_COLLECTIONS_PATH="$VENV_SITE_PACKAGES/ansible_collections"

# Create ansible.cfg only setting the venv collections path
# Ansible will merge this with user (~/.ansible.cfg) and project (./ansible.cfg) configs
cat > "$ANSIBLE_CFG" <<EOF
# Ansible configuration managed by installation script
# Ansible will search multiple paths for collections, including:
# - $VENV_COLLECTIONS_PATH (defined below)
# - ~/.ansible/collections
# - /usr/share/ansible/collections
# See Ansible documentation for full path precedence.
[defaults]
collections_path = $VENV_COLLECTIONS_PATH:/usr/share/ansible/collections

# Example: Uncomment and set if needed
# inventory = $ANSIBLE_CFG_DIR/hosts
# library = /usr/share/my_modules/
# remote_user = user
# ask_pass = false

[privilege_escalation]
# Example:
# become = true
# become_method = sudo
# become_user = root
# become_ask_pass = false
EOF
info "Created/Updated $ANSIBLE_CFG with venv collection path."

# === Cleanup (Optional) ===
if [ "$CLEANUP_SOURCE" = true ] && [ -n "$PY_BUILD_SRC_DIR" ] && [ -d "$PY_BUILD_SRC_DIR" ]; then
    info "Cleaning up Python source files..."
    log_cmd rm -rf "$PY_BUILD_SRC_DIR"
    log_cmd rm -f "/usr/src/$PY_BUILD_TARBALL"
fi

# === Check versions ===
info "Verifying installation..."
PY_VER=$($PY_CMD --version 2>&1) || PY_VER="N/A"
# Use the symlinked ansible command
ANSIBLE_VER=$(ansible --version | head -n 1 2>&1) || ANSIBLE_VER="N/A"
ANSIBLE_CFG_VER=$(ansible --version | grep "config file" 2>&1) || ANSIBLE_CFG_VER="Config file not reported"

# === Final output ===
echo -e "\n${GREEN}==============================================================${NC}"
success " Ansible installation script completed!"
echo -e "${GREEN}==============================================================${NC}\n"
echo -e "${BLUE}Python Used:${NC}              ${GREEN}$PY_CMD ($PY_VER)${NC}"
echo -e "${BLUE}Ansible Version:${NC}          ${GREEN}$ANSIBLE_VER${NC}"
echo -e "${BLUE}Ansible Config:${NC}           ${GREEN}$ANSIBLE_CFG_VER${NC}"
echo -e "${BLUE}Virtual Environment:${NC}      ${GREEN}$VENV_DIR${NC}"
echo ""
echo -e "${BLUE}To activate manually:${NC}     ${GREEN}source $VENV_DIR/bin/activate${NC}"
echo -e "${BLUE}To uninstall (basic):${NC}   ${GREEN}sudo rm -rf $VENV_DIR /usr/local/bin/ansible* /etc/ansible${NC}"
echo -e "${BLUE}Full Log File:${NC}            ${GREEN}$LOG_FILE${NC}"
echo -e "\n${BLUE}System Info:${NC}"
uname -a | tee -a "$LOG_FILE"
date | tee -a "$LOG_FILE"
echo -e "\n${GREEN}-------------------- Installation Finished --------------------${NC}"

exit 0
