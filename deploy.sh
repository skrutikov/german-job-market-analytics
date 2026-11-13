#!/usr/bin/env bash
set -euo pipefail

# Provision the Ubuntu VM with Terraform.
# Proxmox bootstrap, SSH jump-host setup, k3s and app deployment are documented
# in infrastructure/README.md; they are not yet performed by this script.
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$REPO_ROOT/infrastructure/terraform"

# Non-secret defaults for the current bootcamp environment; override with
# PROXMOX_HOST=... ./deploy.sh on other installations.
PROXMOX_HOST="${PROXMOX_HOST:-195.154.103.231}"
export PROXMOX_VE_ENDPOINT="${PROXMOX_VE_ENDPOINT:-https://${PROXMOX_HOST}:8006/}"
export SSL_CERT_FILE="${SSL_CERT_FILE:-$HOME/.config/proxmox/pve-root-ca.pem}"

if [[ ! -r "$SSL_CERT_FILE" ]]; then
    echo "ERROR: Proxmox CA certificate not readable: $SSL_CERT_FILE" >&2
    exit 1
fi
if [[ ! -f "$TF_DIR/terraform.tfvars" ]]; then
    echo "ERROR: Create $TF_DIR/terraform.tfvars from terraform.tfvars.example first." >&2
    exit 1
fi

# Paste the complete token from the password manager: USER@REALM!TOKEN=SECRET.
# An existing PROXMOX_VE_API_TOKEN is also accepted (e.g. in CI).
if [[ -z "${PROXMOX_VE_API_TOKEN:-}" ]]; then
    read -rsp "Enter full Proxmox API token (ID=secret): " PROXMOX_VE_API_TOKEN
    echo
fi
if [[ -z "${PROXMOX_VE_API_TOKEN:-}" || "${PROXMOX_VE_API_TOKEN}" != *=* ]]; then
    echo "ERROR: Expected full token in USER@REALM!TOKEN=SECRET format." >&2
    exit 1
fi
export PROXMOX_VE_API_TOKEN

# terraform.tfvars is the single source of truth for VM ID, IP, subnet,
# node, storage, sizing and Cloud-Init username.
terraform -chdir="$TF_DIR" init -input=false
terraform -chdir="$TF_DIR" validate
terraform -chdir="$TF_DIR" plan -out=vm.tfplan

echo "Review the plan above carefully (especially changes and destroys)."
read -rp "Type 'apply' to apply the saved plan, or anything else to cancel: " CONFIRM
if [[ "$CONFIRM" != "apply" ]]; then
    echo "Deployment cancelled; no Terraform changes applied."
    exit 0
fi

terraform -chdir="$TF_DIR" apply vm.tfplan
