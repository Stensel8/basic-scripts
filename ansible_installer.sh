#!/bin/bash
#
# Ansible Installer - Version 3.0
#
# Installs Ansible in a virtual environment with enhanced error handling,
# logging, Python version management, and more.

set -e
set -o pipefail

# --- Configuration ---
LOG_FILE="/tmp/ansible_installer.log"
REQUESTED_PYTHON_VERSION="${PYTHON_VERSION:-3.12}"
FALLBACK_PYTHON_VERSION="3.13.2"
ANSIBLE_VENV_DIR="./ansible_venv"
ANSIBLE_TOOLS=("ansible" "ansible-playbook" "ansible-vault" "ansible-galaxy")
CONFIG_FILE="/etc/ansible/ansible.cfg"
CLEANUP="${CLEANUP:-false}"

# --- Logging Functions ---
info() {
  local msg="$1"
  echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] $msg"
  echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] $msg" >> "$LOG_FILE"
}

success() {
  local msg="$1"
  echo "$(date '+%Y-%m-%d %H:%M:%S') $msg"
  echo "$(date '+%Y-%m-%d %H:%M:%S') $msg" >> "$LOG_FILE"
}

warn() {
  local msg="$1"
  echo "$(date '+%Y-%m-%d %H:%M:%S') $msg" >&2
  echo "$(date '+%Y-%m-%d %H:%M:%S') $msg" >> "$LOG_FILE"
}

error() {
  local msg="$1"
  echo "$(date '+%Y-%m-%d %H:%M:%S') $msg" >&2
  echo "$(date '+%Y-%m-%d %H:%M:%S') $msg" >> "$LOG_FILE"
}

# --- Helper Functions ---
check_command() {
  if! command -v "$1" &> /dev/null; then
    error "Command '$1' not found. Please ensure it is installed."
    exit 1
  fi
}

install_dependencies() {
  info "Installing build dependencies..."
  if command -v apt-get &> /dev/null; then
    sudo apt-get update
    sudo apt-get install -y --no-install-recommends build-essential python3-dev libffi-dev libssl-dev zlib1g-dev
  elif command -v dnf &> /dev/null |
| command -v yum &> /dev/null; then
    sudo "${0##*/}" -y groupinstall "Development Tools"
    sudo "${0##*/}" install -y python3-devel libffi-devel openssl-devel zlib-devel
  else
    error "Unsupported package manager. Please install build dependencies manually."
    exit 1
  fi
  success "Build dependencies installed."
}

install_python() {
  info "Attempting to install Python version $REQUESTED_PYTHON_VERSION..."
  if command -v apt-get &> /dev/null; then
    sudo apt-get update
    sudo apt-get install -y python3."${REQUESTED_PYTHON_VERSION%.*}"
    if python3."${REQUESTED_PYTHON_VERSION%.*}" --version 2>/dev/null | grep -q "${REQUESTED_PYTHON_VERSION%.*}"; then
      success "Successfully installed Python $REQUESTED_PYTHON_VERSION using apt."
      return 0
    fi
  elif command -v dnf &> /dev/null |
| command -v yum &> /dev/null; then
    sudo "${0##*/}" install -y python3"${REQUESTED_PYTHON_VERSION//./}"
    if python3"${REQUESTED_PYTHON_VERSION//./}" --version 2>/dev/null | grep -q "$REQUESTED_PYTHON_VERSION"; then
      success "Successfully installed Python $REQUESTED_PYTHON_VERSION using yum/dnf."
      return 0
    fi
  fi

  warn "Python version $REQUESTED_PYTHON_VERSION not found via package manager. Attempting to build from source (fallback: $FALLBACK_PYTHON_VERSION)."
  build_python_from_source "$FALLBACK_PYTHON_VERSION"
}

build_python_from_source() {
  local version="$1"
  local filename="Python-$version.tgz"
  local url="https://www.python.org/ftp/python/$version/$filename"
  local expected_sha256=""

  case "$version" in
    "3.13.2") expected_sha256="your_sha256_here_for_3.13.2" ;; # Replace with actual SHA256
    *) error "SHA256 checksum for Python $version not defined. Exiting."; exit 1 ;;
  esac

  info "Downloading Python $version source from $url..."
  wget "$url" |
| { error "Failed to download Python source."; exit 1; }

  echo "$expected_sha256  $filename" | sha256sum -c --strict |
| { error "SHA256 checksum verification failed."; rm -f "$filename"; exit 1; }

  info "Extracting Python source..."
  tar -xf "$filename" |
| { error "Failed to extract Python source."; rm -f "$filename"; exit 1; }
  cd "Python-$version" |
| { error "Failed to change directory."; exit 1; }

  info "Configuring and building Python $version..."
 ./configure --enable-optimizations --enable-shared --with-ensurepip=install |
| { error "Failed to configure Python."; make clean; cd..; rm -rf "Python-$version" "$filename"; exit 1; }
  make -j "$(nproc)" |
| { error "Failed to build Python."; make clean; cd..; rm -rf "Python-$version" "$filename"; exit 1; }

  info "Installing Python $version using altinstall..."
  sudo make altinstall |
| { error "Failed to install Python using altinstall."; make clean; cd..; rm -rf "Python-$version" "$filename"; exit 1; }

  cd..
  rm -rf "Python-$version" "$filename"
  success "Successfully built and installed Python $version using altinstall."
}

setup_virtual_environment() {
  info "Setting up virtual environment in $ANSIBLE_VENV_DIR..."
  if; then
    info "Virtual environment already exists. Checking Python version..."
    local venv_python_version=$("$ANSIBLE_VENV_DIR/bin/python3" --version 2>/dev/null | awk '{print $2}')
    if]; then
      warn "Existing virtual environment's Python version ($venv_python_version) does not match the intended version ($REQUESTED_PYTHON_VERSION or $FALLBACK_PYTHON_VERSION). Consider removing '$ANSIBLE_VENV_DIR' if you want a new environment."
    else
      info "Existing virtual environment's Python version is acceptable."
      return 0
    fi
  fi
  python3 -m venv "$ANSIBLE_VENV_DIR" |
| { error "Failed to create virtual environment."; exit 1; }
  success "Virtual environment created."
}

install_ansible() {
  info "Installing Ansible in the virtual environment..."
  source "$ANSIBLE_VENV_DIR/bin/activate" |
| { error "Failed to activate virtual environment."; exit 1; }
  pip install --upgrade pip setuptools wheel |
| { error "Failed to upgrade pip, setuptools, or wheel."; deactivate; exit 1; }
  pip install ansible |
| { error "Failed to install Ansible."; deactivate; exit 1; }
  deactivate
  success "Ansible installed in the virtual environment."
}

create_symlinks() {
  info "Creating symbolic links for Ansible tools in /usr/local/bin..."
  for tool in "${ANSIBLE_TOOLS[@]}"; do
    if; then
      sudo ln -sf "$ANSIBLE_VENV_DIR/bin/$tool" "/usr/local/bin/$tool" |
| warn "Failed to create symlink for $tool. Ensure you have necessary permissions."
    else
      warn "Ansible tool '$tool' not found in the virtual environment."
    fi
  done
  success "Symbolic links created."
}

configure_ansible_cfg() {
  info "Configuring ansible.cfg..."
  local collections_path="$ANSIBLE_VENV_DIR/lib/python*/site-packages/ansible/collections"
  collections_path=$(eval echo "$collections_path") # Resolve wildcard

  if [! -f "$CONFIG_FILE" ]; then
    info "Creating default ansible.cfg at $CONFIG_FILE..."
    sudo mkdir -p "$(dirname "$CONFIG_FILE")"
    sudo touch "$CONFIG_FILE"
  fi

  sudo sed -i "/^collections_paths/d" "$CONFIG_FILE"
  sudo echo "collections_paths = $collections_path" >> "$CONFIG_FILE"
  success "ansible.cfg configured with collections_path: $collections_path"
}

cleanup() {
  if [ "$CLEANUP" = "true" ]; then
    info "Performing cleanup..."
    # Cleanup of Python source files is handled within the build_python_from_source function
    success "Cleanup complete."
  else
    info "Skipping cleanup (set CLEANUP=true to enable)."
  fi
}

final_output() {
  local python_version=$("$ANSIBLE_VENV_DIR/bin/python3" --version 2>/dev/null | awk '{print $2}')
  local ansible_version=$("$ANSIBLE_VENV_DIR/bin/pip show ansible | grep Version | awk '{print $2}'")

  echo ""
  success "Ansible installation complete!"
  echo "Installed Python Version: $python_version"
  echo "Installed Ansible Version: $ansible_version"
  echo "Virtual Environment Location: $ANSIBLE_VENV_DIR"
  echo ""
  echo "To activate the virtual environment, run: source $ANSIBLE_VENV_DIR/bin/activate"
  echo "To deactivate, run: deactivate"
  echo ""
  echo "Ansible tools (ansible, ansible-playbook, etc.) are now available in /usr/local/bin."
  echo ""
  echo "To uninstall, deactivate the virtual environment and remove the '$ANSIBLE_VENV_DIR' directory."
  echo ""
  info "Detailed installation log can be found at: $LOG_FILE"
  echo ""
}

# --- Main Script ---
info "Starting Ansible installation..."

check_command wget
check_command tar
check_command make
check_command gcc
check_command python3
check_command pip

install_dependencies

install_python

setup_virtual_environment

install_ansible

create_symlinks

configure_ansible_cfg

cleanup

final_output

info "Ansible installation script finished."

exit 0
