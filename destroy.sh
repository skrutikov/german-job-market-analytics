#!/usr/bin/env bash
set -euo pipefail

# Destroy ONLY the Ubuntu VM managed by this Terraform state.
# An existing Proxmox VM must never be deleted just because its ID was typed
# into terraform.tfvars; the managed VM ID and configured VM ID must match.
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$REPO_ROOT/infrastructure/terraform"
VM_RESOURCE='proxmox_virtual_environment_vm.k3s[0]'

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

# Use the same (full) API token format as deploy.sh.
if [[ -z "${PROXMOX_VE_API_TOKEN:-}" ]]; then
    read -rsp "Enter full Proxmox API token (ID=secret): " PROXMOX_VE_API_TOKEN
    echo
fi
if [[ -z "${PROXMOX_VE_API_TOKEN:-}" || "${PROXMOX_VE_API_TOKEN}" != *=* ]]; then
    echo "ERROR: Expected full token in USER@REALM!TOKEN=SECRET format." >&2
    exit 1
fi
export PROXMOX_VE_API_TOKEN

terraform -chdir="$TF_DIR" init -input=false
terraform -chdir="$TF_DIR" validate

# Only delete a VM tracked by THIS local Terraform state, not an arbitrary
# Proxmox VM with the same number. Reuse the state created by deploy.sh.
if ! terraform -chdir="$TF_DIR" state list | grep -Fxq "$VM_RESOURCE"; then
    echo "ERROR: $VM_RESOURCE is not in this Terraform state; nothing to destroy." >&2
    exit 1
fi

CONFIG_VM_ID="$(printf 'var.vm_id\n' | terraform -chdir="$TF_DIR" console -no-color)"
MANAGED_VM_ID="$(terraform -chdir="$TF_DIR" output -raw managed_vm_id)"
if [[ ! "$CONFIG_VM_ID" =~ ^[0-9]+$ || ! "$MANAGED_VM_ID" =~ ^[0-9]+$ ||
      "$CONFIG_VM_ID" != "$MANAGED_VM_ID" || "$MANAGED_VM_ID" == "100" ]]; then
    echo "ERROR: VM ID mismatch/unsafe value: terraform.tfvars=$CONFIG_VM_ID, state=$MANAGED_VM_ID." >&2
    echo "Refusing to destroy a different VM. Check terraform.tfvars and the state." >&2
    exit 1
fi

echo "Planning destruction of managed VM $MANAGED_VM_ID only."
terraform -chdir="$TF_DIR" plan -destroy -target="$VM_RESOURCE" -out=destroy.tfplan -input=false

echo "WARNING: This permanently deletes VM $MANAGED_VM_ID and its managed disks."
echo "Review the plan. The manually downloaded Cloud Image and Proxmox ACLs are not managed by this script."
read -rp "Type 'destroy $MANAGED_VM_ID' to continue: " CONFIRM
if [[ "$CONFIRM" != "destroy $MANAGED_VM_ID" ]]; then
    echo "Destruction cancelled."
    exit 0
fi

terraform -chdir="$TF_DIR" apply destroy.tfplan
