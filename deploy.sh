#!/usr/bin/env bash
set -euo pipefail

# Provision the Ubuntu VM with Terraform, then install/configure k3s with Ansible.
# Proxmox bootstrap and the restricted SSH jump account must be prepared first
# as documented in infrastructure/README.md. App deployment is a later step.
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$REPO_ROOT/infrastructure/terraform"
ANSIBLE_DIR="$REPO_ROOT/infrastructure/ansible"

# Non-secret defaults for the current bootcamp environment; override with
# PROXMOX_HOST=... ./deploy.sh on other installations.
PROXMOX_HOST="${PROXMOX_HOST:-195.154.103.231}"
JUMP_USER="${JUMP_USER:-jumpuser}"
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

# Check Ansible prerequisites before provisioning; avoid leaving a newly created
# VM when the controller is missing required local tools.
for program in ssh ansible ansible-playbook; do
    if ! command -v "$program" >/dev/null 2>&1; then
        echo "ERROR: $program is required to install k3s. See infrastructure/README.md." >&2
        exit 1
    fi
done
if [[ ! -f "$ANSIBLE_DIR/install-k3s.yml" ]]; then
    echo "ERROR: Missing $ANSIBLE_DIR/install-k3s.yml" >&2
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
    echo "The VM is already managed by Terraform; rerun ./deploy.sh after fixing SSH." >&2
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
echo "Deployment complete: VM $VM_ID is running k3s."

