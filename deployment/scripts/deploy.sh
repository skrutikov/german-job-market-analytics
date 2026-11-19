#!/usr/bin/env bash
# Provision a VM in its own Terraform workspace; then configure k3s via Ansible.
# Usage: bash deployment/scripts/deploy.sh VM_ID LAST_IPV4_OCTET
set -euo pipefail

if (( $# != 2 )); then
    echo "Usage: ./deployment/scripts/deploy.sh VM_ID LAST_IPV4_OCTET" >&2
    exit 2
fi
VM_ID="$1"
LAST_OCTET="$2"
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
TF_DIR="$REPO_ROOT/deployment/terraform"
ANSIBLE_DIR="$REPO_ROOT/deployment/ansible"
TFVARS="$TF_DIR/instances/vm-$VM_ID.tfvars.json"
PLAN="$TF_DIR/instances/vm-$VM_ID.tfplan"
source "$REPO_ROOT/deployment/scripts/terraform_vm_workspace.sh"

PROXMOX_HOST="${PROXMOX_HOST:-195.154.103.231}"
JUMP_USER="${JUMP_USER:-jumpuser}"
export PROXMOX_VE_ENDPOINT="${PROXMOX_VE_ENDPOINT:-https://${PROXMOX_HOST}:8006/}"
export SSL_CERT_FILE="${SSL_CERT_FILE:-$HOME/.config/proxmox/pve-root-ca.pem}"

# Fail before touching Proxmox when the local prerequisites are incomplete.
for program in terraform ssh ansible ansible-playbook python3; do
    command -v "$program" >/dev/null 2>&1 || {
        echo "ERROR: Missing required program: $program" >&2
        exit 1
    }
done
[[ -r "$SSL_CERT_FILE" ]] || {
    echo "ERROR: Proxmox CA certificate not readable: $SSL_CERT_FILE" >&2
    exit 1
}
[[ -f "$TF_DIR/terraform.tfvars" ]] || {
    echo "ERROR: Copy deployment/terraform/terraform.tfvars.example to terraform.tfvars first." >&2
    exit 1
}
[[ -f "$ANSIBLE_DIR/install-k3s.yml" ]] || {
    echo "ERROR: Missing Ansible playbook: $ANSIBLE_DIR/install-k3s.yml" >&2
    exit 1
}

# Shared settings (Proxmox node, storage, subnet, gateway) stay in terraform.tfvars.
# The generated Git-ignored per-VM file overrides ID, name, IP and create_vm.
CONFIG_PREEXISTED=false
[[ -e "$TFVARS" ]] && CONFIG_PREEXISTED=true
VM_CIDR="$(python3 "$REPO_ROOT/deployment/scripts/vm_instance_config.py" \
    prepare "$TF_DIR" "$VM_ID" "$LAST_OCTET")" || exit 1
echo "Target VM $VM_ID: $VM_CIDR, Terraform workspace vm-$VM_ID"

if [[ -z "${PROXMOX_VE_API_TOKEN:-}" ]]; then
    read -rsp "Enter full Proxmox API token (ID=secret): " PROXMOX_VE_API_TOKEN
    echo
fi
[[ -n "${PROXMOX_VE_API_TOKEN:-}" && "$PROXMOX_VE_API_TOKEN" == *=* ]] || {
    echo "ERROR: Expected full Proxmox token in USER@REALM!TOKEN=SECRET format." >&2
    exit 1
}
export PROXMOX_VE_API_TOKEN

terraform_vm_workspace create
# Never attach a newly generated config to an already populated workspace.
if [[ "$WORKSPACE_ALREADY_EXISTED" == true && "$CONFIG_PREEXISTED" == false ]]; then
    if [[ -n "$(terraform -chdir="$TF_DIR" state list)" ]]; then
        echo "ERROR: Existing workspace $VM_WORKSPACE has state but no instance config." >&2
        exit 1
    fi
fi
terraform -chdir="$TF_DIR" validate
terraform -chdir="$TF_DIR" plan -var-file="$TFVARS" -out="$PLAN" -input=false

# Reject destruction/replacement and verify BOTH VM ID and IP in the saved plan.
if ! TARGET_VM_ID="$(terraform -chdir="$TF_DIR" show -json "$PLAN" |
    EXPECTED_VM_ID="$VM_ID" EXPECTED_VM_CIDR="$VM_CIDR" python3 -c '
import json, os, sys
plan = json.load(sys.stdin)
changes = plan.get("resource_changes", [])
danger = [c["address"] for c in changes if "delete" in c.get("change", {}).get("actions", [])]
if danger:
    sys.exit("Refusing deletion/replacement: " + ", ".join(danger))
targets = [c for c in changes if c.get("address") == "proxmox_virtual_environment_vm.k3s[0]"]
if len(targets) != 1:
    sys.exit("Expected exactly one managed VM. Check per-VM configuration.")
vm_id = targets[0].get("change", {}).get("after", {}).get("vm_id")
cidr = (plan.get("planned_values", {}).get("outputs", {})
    .get("managed_vm_ipv4", {}).get("value"))
if vm_id != int(os.environ["EXPECTED_VM_ID"]) or cidr != os.environ["EXPECTED_VM_CIDR"]:
    sys.exit("Plan targets unexpected VM ID or guest IPv4 address")
print(vm_id)
')"; then
    echo "ERROR: Unsafe Terraform plan; no changes were applied." >&2
    exit 1
fi

echo "Review the plan for VM $TARGET_VM_ID ($VM_CIDR) in workspace $VM_WORKSPACE."
read -rp "Type 'apply $TARGET_VM_ID' to apply the saved plan: " CONFIRM
if [[ "$CONFIRM" != "apply $TARGET_VM_ID" ]]; then
    echo "Deployment cancelled; no Terraform changes applied."
    exit 0
fi
terraform -chdir="$TF_DIR" apply "$PLAN"

# Use Terraform outputs so the VM address, username and SSH key cannot drift
# from terraform.tfvars. The private key is the sibling of the .pub key.
VM_ID="$(terraform -chdir="$TF_DIR" output -raw managed_vm_id)"
VM_CIDR="$(terraform -chdir="$TF_DIR" output -raw managed_vm_ipv4)"
VM_IP="${VM_CIDR%%/*}"
VM_USER="$(terraform -chdir="$TF_DIR" output -raw managed_vm_username)"
SSH_PUBLIC_KEY="$(terraform -chdir="$TF_DIR" output -raw managed_vm_ssh_public_key_path)"
if [[ "$SSH_PUBLIC_KEY" != *.pub ]]; then
    echo "ERROR: Public SSH key path must end in .pub: $SSH_PUBLIC_KEY" >&2
    exit 1
fi
SSH_PRIVATE_KEY="${SSH_PUBLIC_KEY%.pub}"
if [[ ! -r "$SSH_PRIVATE_KEY" ]]; then
    echo "ERROR: Matching SSH private key not found: $SSH_PRIVATE_KEY" >&2
    exit 1
fi
if [[ ! "$VM_IP" =~ ^[0-9]+(\.[0-9]+){3}$ ||
      ! "$VM_USER" =~ ^[a-z_][a-z0-9_-]*$ ||
      ! "$JUMP_USER" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
    echo "ERROR: Unexpected IP or SSH username in Terraform configuration." >&2
    exit 1
fi

echo "Waiting for SSH to VM $VM_ID ($VM_USER@$VM_IP) through $JUMP_USER@$PROXMOX_HOST..."
echo "On first connection, verify host-key fingerprints against the trusted Proxmox and VM consoles."
SSH_OPTS=(
    -i "$SSH_PRIVATE_KEY"
    -o IdentitiesOnly=yes
    -o ConnectTimeout=10
    -o ConnectionAttempts=1
    -o StrictHostKeyChecking=ask
    -o PasswordAuthentication=no
    -o KbdInteractiveAuthentication=no
    -J "$JUMP_USER@$PROXMOX_HOST"
)
SSH_READY=false
for attempt in {1..18}; do
    if ssh "${SSH_OPTS[@]}" "$VM_USER@$VM_IP" true; then
        SSH_READY=true
        break
    fi
    echo "SSH not ready (attempt $attempt/18). Retrying..."
    sleep 5
done
if [[ "$SSH_READY" != true ]]; then
    echo "ERROR: Cannot reach VM $VM_ID through the SSH jump account." >&2
    echo "Verify jumpuser forwarding, port 22, SSH keys and host-key fingerprints (README Section 4)." >&2
    echo "The VM is already managed by Terraform; rerun ./deployment/scripts/deploy.sh after fixing SSH." >&2
    exit 1
fi

echo "Waiting for Ubuntu Cloud-Init to finish..."
# Exit code 2 means Cloud-Init completed with recoverable errors. Do not let
# set -e silently end deployment; report the error before deciding whether
# k3s installation can continue. Exit codes 1/255 are fatal here.
if ssh "${SSH_OPTS[@]}" "$VM_USER@$VM_IP" "cloud-init status --wait"; then
    echo "Cloud-Init completed successfully."
else
    CLOUD_INIT_RC=$?
    echo "Cloud-Init status returned exit code $CLOUD_INIT_RC."
    ssh "${SSH_OPTS[@]}" "$VM_USER@$VM_IP" "cloud-init status --long" || true
    if [[ "$CLOUD_INIT_RC" == 2 ]]; then
        echo "WARNING: Cloud-Init completed with recoverable errors (exit 2)."
        echo "Review the details above; proceeding to the Ansible readiness check."
    else
        echo "ERROR: Cloud-Init did not complete successfully; not starting Ansible." >&2
        exit "$CLOUD_INIT_RC"
    fi
fi

# Temporary inventory: no duplicate VM IP/user settings or committed credentials.
INVENTORY="$(mktemp)"
trap 'rm -f "$INVENTORY"' EXIT
cat > "$INVENTORY" <<EOF
[k3s_servers]
k3s-vm ansible_host=$VM_IP ansible_user=$VM_USER ansible_python_interpreter=/usr/bin/python3 ansible_ssh_common_args='-o ProxyJump=$JUMP_USER@$PROXMOX_HOST'
EOF

export ANSIBLE_HOST_KEY_CHECKING=True
echo "Checking Ansible connectivity..."
ansible -i "$INVENTORY" k3s_servers --private-key "$SSH_PRIVATE_KEY" -m ping

echo "Installing/configuring k3s on VM $VM_ID with Ansible..."
ansible-playbook -i "$INVENTORY" --private-key "$SSH_PRIVATE_KEY" "$ANSIBLE_DIR/install-k3s.yml"

echo "Verifying k3s node and namespaces..."
ssh "${SSH_OPTS[@]}" "$VM_USER@$VM_IP" "sudo -n k3s kubectl get nodes && sudo -n k3s kubectl get namespaces"
echo "Deployment complete: VM $VM_ID ($VM_CIDR) is running k3s in $VM_WORKSPACE."

