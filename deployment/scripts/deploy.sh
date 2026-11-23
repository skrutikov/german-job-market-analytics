#!/usr/bin/env bash
# Provision a VM in its own Terraform workspace; then configure k3s via Ansible.
# Usage: bash deployment/scripts/deploy.sh VM_ID LAST_IPV4_OCTET [dev|prod] [--infra-only]
set -euo pipefail

usage() {
    echo "Usage: ./deployment/scripts/deploy.sh VM_ID LAST_IPV4_OCTET [dev|prod] [--infra-only]" >&2
    exit 2
}
(( $# >= 2 && $# <= 4 )) || usage
RUN_APPLICATION=true
DEPLOY_ENV=dev
seen_environment=false
seen_infra_only=false
for argument in "${@:3}"; do
    case "$argument" in
        dev|prod)
            [[ "$seen_environment" == false ]] || usage
            DEPLOY_ENV="$argument"
            seen_environment=true
            ;;
        --infra-only)
            [[ "$seen_infra_only" == false ]] || usage
            RUN_APPLICATION=false
            seen_infra_only=true
            ;;
        *) usage ;;
    esac
done
VM_ID="$1"
LAST_OCTET="$2"
# Validate arguments before reading credentials or touching infrastructure.
if [[ ! "$VM_ID" =~ ^[1-9][0-9]{2,8}$ || ! "$LAST_OCTET" =~ ^(0|[1-9][0-9]{0,2})$ ]] ||
   (( LAST_OCTET < 2 || LAST_OCTET > 254 )); then
    echo "ERROR: VM_ID must be 100–999999999; last IP octet must be 2–254." >&2
    exit 2
fi
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
TF_DIR="$REPO_ROOT/deployment/terraform"
ANSIBLE_DIR="$REPO_ROOT/deployment/ansible"
PLAN="$TF_DIR/vm-$VM_ID.tfplan"
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
[[ -f "$ANSIBLE_DIR/install-k3s.yml" ]] || {
    echo "ERROR: Missing Ansible playbook: $ANSIBLE_DIR/install-k3s.yml" >&2
    exit 1
}

# Bootstrap the same branch that invoked the provisioning command, not an
# unrelated default branch. Validate before provisioning anything remotely.
if [[ "$RUN_APPLICATION" == true ]]; then
    command -v git >/dev/null || {
        echo "ERROR: git is required to bootstrap the application." >&2
        exit 1
    }
    APP_REF="${JOB_MARKET_REF:-$(git -C "$REPO_ROOT" branch --show-current)}"
    if [[ ! "$APP_REF" =~ ^[a-zA-Z0-9][a-zA-Z0-9._/-]*$ ||
          "$APP_REF" == *..* ]]; then
        echo "ERROR: Set JOB_MARKET_REF to a safe existing Git branch name." >&2
        exit 1
    fi
    [[ -f "$REPO_ROOT/deployment/scripts/setup_vm.sh" ]] || {
        echo "ERROR: Missing application bootstrap script." >&2
        exit 1
    }
    if [[ "$DEPLOY_ENV" == dev && "$APP_REF" == production ]]; then
        echo "ERROR: Dev may not track the approved production branch." >&2
        exit 1
    fi
    if [[ "$DEPLOY_ENV" == prod ]]; then
        # The production revision is advanced exclusively by an approved
        # promotion workflow. Check it before provisioning a new VM.
        echo "Checking approved production GitOps revision..."
        git -C "$REPO_ROOT" fetch --no-tags origin production:refs/remotes/origin/production || {
            echo "ERROR: No approved production branch is available." >&2
            exit 1
        }
        for approved_file in \
            deployment/kubernetes/deploy.sh \
            deployment/kubernetes/overlays/prod/kustomization.yaml \
            deployment/argocd/application-prod.yaml \
            deployment/argocd/configure-sync.sh; do
            if ! git -C "$REPO_ROOT" cat-file -e \
                "refs/remotes/origin/production:$approved_file"; then
                echo "ERROR: Approved production branch lacks $approved_file." >&2
                echo "Merge the deployment refactor into main, then promote a tested release." >&2
                echo "No VM has been provisioned." >&2
                exit 1
            fi
        done
    fi
fi


# A per-VM ACL is required by the restricted bootcamp Proxmox token. Unlike
# shared VNet/storage ACLs, Proxmox may remove this ACL with a deleted VM.
print_vm_acl_reminder() {
    cat <<EOF
==================================================
PROXMOX VM PERMISSIONS (before VM creation)
==================================================
For a new or recreated VM, log in to the Proxmox HOST as root
and grant access only to VM $VM_ID:

pveum acl modify /vms/$VM_ID \\
  --roles PVEVMAdmin \\
  --users root1@pve \\
  --tokens 'root1@pve!terraform'

Do this before Terraform apply; otherwise the API may return HTTP 403.
If you use a different Proxmox token, adjust the user/token names.
Do not grant cluster-wide VM permissions.
==================================================

EOF
}

print_ssh_host_key_recovery() {
    cat >&2 <<EOF

==================================================
SSH HOST KEY CHANGED — STOP AND VERIFY
==================================================
VM $VM_ID may have been recreated at $VM_IP.
If the warning refers to the Proxmox jump host instead,
verify THAT host's identity; do not blindly delete any key.

1. In Proxmox, open VM $VM_ID -> Console and independently
   verify the guest's ED25519 SSH fingerprint:

   ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub

2. ONLY after verifying the new guest key, run on the
   workstation (the same user running deploy.sh):

   ssh-keygen -R $VM_IP

3. Reconnect and compare the fingerprint before accepting:

   ssh -J "$JUMP_USER@$PROXMOX_HOST" "$VM_USER@$VM_IP"

4. Then rerun deployment using the same workspace:

   ./deployment/scripts/deploy.sh $VM_ID $LAST_OCTET $DEPLOY_ENV

Never disable host-key checking or remove keys without
verification. If console login is unavailable, consult
deployment/README.md for the Proxmox-host cross-check.
The VM is already Terraform-managed; do not recreate it.
==================================================
EOF
}

# Show the ACL instructions before any Terraform operation that may create a VM.
print_vm_acl_reminder
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
# Read the network from Terraform's own defaults (or an optional override);
# no manually created terraform.tfvars or generated instance files are needed.
TEMPLATE_CIDR="$(terraform -chdir="$TF_DIR" console <<< 'var.vm_ipv4_cidr')"
GATEWAY="$(terraform -chdir="$TF_DIR" console <<< 'var.vm_gateway')"
TEMPLATE_CIDR="${TEMPLATE_CIDR#\"}"
TEMPLATE_CIDR="${TEMPLATE_CIDR%\"}"
GATEWAY="${GATEWAY#\"}"
GATEWAY="${GATEWAY%\"}"
if [[ ! "$TEMPLATE_CIDR" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/24$ ||
      ! "$GATEWAY" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo "ERROR: Default Terraform network must be IPv4 with /24 mask." >&2
    exit 1
fi
VM_PREFIX="${TEMPLATE_CIDR%.*}"
VM_CIDR="$VM_PREFIX.$LAST_OCTET/24"
if [[ "$GATEWAY" == "${VM_CIDR%/*}" ]]; then
    echo "ERROR: Requested VM IP is the network gateway." >&2
    exit 1
fi
echo "Target VM $VM_ID: $VM_CIDR, Terraform workspace $VM_WORKSPACE"
# A rerun must not silently reassign a workspace's existing VM or IP.
if terraform -chdir="$TF_DIR" state list | grep -Fxq 'proxmox_virtual_environment_vm.k3s[0]'; then
    STATE_VM_ID="$(terraform -chdir="$TF_DIR" output -raw managed_vm_id)"
    STATE_VM_CIDR="$(terraform -chdir="$TF_DIR" output -raw managed_vm_ipv4)"
    if [[ "$STATE_VM_ID" != "$VM_ID" || "$STATE_VM_CIDR" != "$VM_CIDR" ]]; then
        echo "ERROR: $VM_WORKSPACE already manages VM $STATE_VM_ID ($STATE_VM_CIDR)." >&2
        exit 1
    fi
fi
terraform -chdir="$TF_DIR" validate
terraform -chdir="$TF_DIR" plan -input=false \
    -var="create_vm=true" -var="vm_id=$VM_ID" \
    -var="vm_name=job-market-ubuntu-$VM_ID" \
    -var="vm_ipv4_cidr=$VM_CIDR" -out="$PLAN"

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
    exit 1
fi
terraform -chdir="$TF_DIR" apply "$PLAN"

# Use Terraform outputs so the VM address, username and SSH key cannot drift
# from the chosen workspace state. The private key is the sibling of the .pub key.
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
# Preserve SSH diagnostics and stop immediately on a changed host key:
# retrying cannot fix a trust failure, and must not bypass host verification.
SSH_ERROR_LOG="$(mktemp)"
trap 'rm -f -- "$SSH_ERROR_LOG" "${INVENTORY:-}"' EXIT
SSH_READY=false
for attempt in {1..18}; do
    if ssh "${SSH_OPTS[@]}" "$VM_USER@$VM_IP" true 2>"$SSH_ERROR_LOG"; then
        SSH_READY=true
        break
    fi
    cat "$SSH_ERROR_LOG" >&2
    if grep -Fq 'REMOTE HOST IDENTIFICATION HAS CHANGED' "$SSH_ERROR_LOG" ||
       grep -Fq 'POSSIBLE DNS SPOOFING DETECTED' "$SSH_ERROR_LOG"; then
        print_ssh_host_key_recovery
        exit 1
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
# The EXIT trap already cleans up both the inventory and the SSH error log.
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
echo "VM $VM_ID ($VM_CIDR) is running k3s in $VM_WORKSPACE."
if [[ "$RUN_APPLICATION" == true ]]; then
    echo "Bootstrapping $DEPLOY_ENV environment (installer branch: '$APP_REF')..."
    ssh "${SSH_OPTS[@]}" "$VM_USER@$VM_IP" \
        "JOB_MARKET_REF='$APP_REF' bash -s -- '$DEPLOY_ENV'" \
        < "$REPO_ROOT/deployment/scripts/setup_vm.sh"
    echo "VM $VM_ID: $DEPLOY_ENV application and Argo CD bootstrap complete."
else
    echo "Application bootstrap skipped (--infra-only)."
fi
cat <<EOF

==================================================
DEPLOYMENT COMPLETE
==================================================
VM ID:       $VM_ID
IP address:  $VM_IP
Environment: $DEPLOY_ENV
Workspace:   $VM_WORKSPACE
Application: $([[ "$RUN_APPLICATION" == true ]] && echo installed || echo "skipped (--infra-only)")
==================================================
EOF


