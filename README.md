## About This Repository

This repository contains a collection of installer scripts that I use internally for automation with Terraform and Ansible. These scripts help me quickly deploy and switch between different versions of NGINX (as well as Docker, Ansible, Terraform, and Kubernetes) on various systems. The idea is to have a simple, one-command installation that can easily be updated or switched between versions when needed.

---

## How to Run a Script

### Run Directly
To run a script directly without saving it, use the following command in a terminal.

For example:

## nginx_stable_installer.sh
```bash
curl -fsSL https://raw.githubusercontent.com/Stensel8/basic-scripts/refs/heads/main/nginx_stable_installer.sh | sudo bash
```

## nginx_mainline_installer.sh
```bash
curl -fsSL https://raw.githubusercontent.com/Stensel8/basic-scripts/refs/heads/main/nginx_mainline_installer.sh | sudo bash
```

## docker_installer.sh
```bash
curl -fsSL https://raw.githubusercontent.com/Stensel8/basic-scripts/refs/heads/main/docker_installer.sh | sudo bash
```

## ansible_installer.sh
```bash
curl -fsSL https://raw.githubusercontent.com/Stensel8/basic-scripts/refs/heads/main/ansible_installer.sh | sudo bash
```

## terraform_installer.sh
```bash
curl -fsSL https://raw.githubusercontent.com/Stensel8/basic-scripts/refs/heads/main/terraform_installer.sh | sudo bash
```

## kubernetes_installer.sh
```bash
curl -fsSL https://raw.githubusercontent.com/Stensel8/basic-scripts/refs/heads/main/kubernetes_installer.sh | sudo bash
```

## Enable-WinRM.ps1
```ps1
irm https://raw.githubusercontent.com/Stensel8/basic-scripts/refs/heads/main/Enable-WinRM.ps1 | iex
```
