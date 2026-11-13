#!/usr/bin/env bash
set -euo pipefail

# Proxmox infrastructure
export PROXMOX_HOST="195.154.103.231"
export VM_ID="101"
export VM_IP="10.10.10.21"
export SDN_ZONE="studnat"
export SDN_VNET="nat0"
export VM_USER="group3"

# Terraform provider configuration
export PROXMOX_VE_ENDPOINT="https://${PROXMOX_HOST}:8006/"
export SSL_CERT_FILE="$HOME/.config/proxmox/pve-root-ca.pem"

# Proxmox authentication
read -rsp "Enter Proxmox token secret: " TOKEN_SECRET
echo
export PROXMOX_VE_API_TOKEN="${TOKEN_SECRET}"
unset TOKEN_SECRET

# Provision infrastructure
terraform -chdir=infrastructure/terraform plan \
    -var="vm_id=${VM_ID}" \
    -var="vm_ipv4_cidr=${VM_IP}/24" \
    -out=vm.tfplan
terraform -chdir=infrastructure/terraform apply vm.tfplan