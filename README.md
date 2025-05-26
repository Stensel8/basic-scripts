# Scripts Repository

## About This Repository

This repository contains a collection of enhanced and complex installer scripts that I use internally for automation (also with Terraform and Ansible). These scripts help me quickly deploy and switch between different versions of NGINX (as well as Docker, Ansible, Terraform, and Kubernetes) on various systems. The idea is to have a simple, one-command installation that can easily be updated or switched between versions when needed.

---

## How to Run a Script

### Run Directly
To run a script directly without saving it, use the following command in a terminal.

For example:

### nginx_installer.sh

This script installs a custom compiled NGINX with OpenSSL 3.5.0 for improved HTTP/3 and QUIC support. The build includes performance optimizations for your specific CPU architecture.

### nginx_installer.sh - Install
```bash
curl -fsSL https://raw.githubusercontent.com/Stensel8/scripts/main/nginx_installer.sh \
  | sudo env CONFIRM=yes bash -s install
```
### nginx_installer.sh - Verify
```bash
curl -fsSL https://raw.githubusercontent.com/Stensel8/scripts/main/nginx_installer.sh \
  | sudo env CONFIRM=yes bash -s verify
```
### nginx_installer.sh - Remove
```bash
curl -fsSL https://raw.githubusercontent.com/Stensel8/scripts/main/nginx_installer.sh \
  | sudo env CONFIRM=yes bash -s remove
```

**Features:**
- NGINX 1.28.0 (LTS version)
- OpenSSL 3.5.0 with enhanced QUIC support
- HTTP/3 module enabled
- CPU-specific optimizations (`-march=native`)
- Statically linked OpenSSL for better performance
- Full feature set including mail, stream, and all standard modules

**Note:** The script will detect existing NGINX installations and offer to remove them before installing the custom build.

### openssl+openssh_installer.sh - Install
```bash
curl -fsSL https://raw.githubusercontent.com/Stensel8/scripts/main/openssl+openssh_installer.sh \
  | sudo env CONFIRM=yes bash -s install
```
### openssl+openssh_installer.sh - Verify
```bash
curl -fsSL https://raw.githubusercontent.com/Stensel8/scripts/main/openssl+openssh_installer.sh \
  | sudo env CONFIRM=yes bash -s verify
```
### openssl+openssh_installer.sh - Remove
```bash
curl -fsSL https://raw.githubusercontent.com/Stensel8/scripts/main/openssl+openssh_installer.sh \
  | sudo env CONFIRM=yes bash -s verify
```
**Features:**
- OpenSSL 3.5.0 (LTS version)
- OpenSSH 10.0 with enhanced security features
- CPU-specific optimizations for better performance
- Improved cryptographic algorithm support
- Hardened security configurations by default
- Complete with all standard modules and extensions

**Note:** The script checks for existing OpenSSL and OpenSSH installations and will prompt before replacing them to avoid disrupting your system configuration.


## docker_installer.sh
```bash
curl -fsSL https://raw.githubusercontent.com/Stensel8/scripts/refs/heads/main/docker_installer.sh | sudo bash
```

## ansible_installer.sh
```bash
curl -fsSL https://raw.githubusercontent.com/Stensel8/scripts/refs/heads/main/ansible_installer.sh | sudo bash
```

## terraform_installer.sh
```bash
curl -fsSL https://raw.githubusercontent.com/Stensel8/scripts/refs/heads/main/terraform_installer.sh | sudo bash
```

## kubernetes_installer.sh
```bash
curl -fsSL https://raw.githubusercontent.com/Stensel8/scripts/refs/heads/main/kubernetes_installer.sh | sudo bash
```

## Enable-WinRM.ps1
```ps1
irm https://raw.githubusercontent.com/Stensel8/scripts/refs/heads/main/Enable-WinRM.ps1 | iex
```
