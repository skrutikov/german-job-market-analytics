#!/usr/bin/env bash
# Delete ONLY the VM tracked by the requested Terraform workspace.
# Usage: bash deployment/scripts/destroy.sh VM_ID
set -euo pipefail

if (( $# != 1 )); then
    echo "Usage: ./deployment/scripts/destroy.sh VM_ID" >&2
    exit 2
fi
VM_ID="$1"
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
TF_DIR="$REPO_ROOT/deployment/terraform"
TFVARS="$TF_DIR/instances/vm-$VM_ID.tfvars.json"
PLAN="$TF_DIR/instances/vm-$VM_ID-destroy.tfplan"
VM_RESOURCE='proxmox_virtual_environment_vm.k3s[0]'
source "$REPO_ROOT/deployment/scripts/terraform_vm_workspace.sh"

command -v terraform >/dev/null || { echo "ERROR: Terraform is required." >&2; exit 1; }
VM_CIDR="$(python3 "$REPO_ROOT/deployment/scripts/vm_instance_config.py" \
    verify "$TF_DIR" "$VM_ID")" || exit 1

PROXMOX_HOST="${PROXMOX_HOST:-195.154.103.231}"
export PROXMOX_VE_ENDPOINT="${PROXMOX_VE_ENDPOINT:-https://${PROXMOX_HOST}:8006/}"
export SSL_CERT_FILE="${SSL_CERT_FILE:-$HOME/.config/proxmox/pve-root-ca.pem}"
[[ -r "$SSL_CERT_FILE" ]] || {
    echo "ERROR: Proxmox CA certificate not readable: $SSL_CERT_FILE" >&2
    exit 1
}
if [[ -z "${PROXMOX_VE_API_TOKEN:-}" ]]; then
    read -rsp "Enter full Proxmox API token (ID=secret): " PROXMOX_VE_API_TOKEN
    echo
fi
[[ -n "${PROXMOX_VE_API_TOKEN:-}" && "$PROXMOX_VE_API_TOKEN" == *=* ]] || {
    echo "ERROR: Expected full Proxmox token in USER@REALM!TOKEN=SECRET format." >&2
    exit 1
}
export PROXMOX_VE_API_TOKEN

# Never create a workspace during destruction; it must already exist.
terraform_vm_workspace existing
terraform -chdir="$TF_DIR" validate
terraform -chdir="$TF_DIR" state list | grep -Fxq "$VM_RESOURCE" || {
    echo "ERROR: Workspace $VM_WORKSPACE does not manage a VM; nothing to destroy." >&2
    exit 1
}
MANAGED_VM_ID="$(terraform -chdir="$TF_DIR" output -raw managed_vm_id)"
MANAGED_VM_IP="$(terraform -chdir="$TF_DIR" output -raw managed_vm_ipv4)"
[[ "$MANAGED_VM_ID" == "$VM_ID" && "$MANAGED_VM_IP" == "$VM_CIDR" ]] || {
    echo "ERROR: Workspace state does not match VM $VM_ID at $VM_CIDR." >&2
    exit 1
}
if [[ "$VM_ID" == 100 && "${ALLOW_DESTROY_VM100:-false}" != true ]]; then
    echo "ERROR: Refusing to destroy VM 100 without ALLOW_DESTROY_VM100=true." >&2
    exit 1
fi

terraform -chdir="$TF_DIR" plan -destroy -target="$VM_RESOURCE" \
    -var-file="$TFVARS" -out="$PLAN" -input=false
echo "WARNING: This deletes VM $VM_ID ($VM_CIDR) and its managed disks."
echo "Terraform workspace: $VM_WORKSPACE. Unrelated VM workspaces are not touched."
read -rp "Type 'destroy $VM_ID' to continue: " CONFIRM
if [[ "$CONFIRM" != "destroy $VM_ID" ]]; then
    echo "Destruction cancelled."
    exit 0
fi
terraform -chdir="$TF_DIR" apply "$PLAN"
echo "Destroyed VM $VM_ID. Workspace and its variables are retained for safe redeployment."
