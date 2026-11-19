#!/usr/bin/env bash
# Recover a VERIFIED prod backup onto a disposable VM, optionally provisioning it first.
# Usage (automated): ./deployment/scripts/restore_backup.sh 104 29 prod [BACKUP_DIRECTORY]
# Usage (existing VM): ./deployment/scripts/restore_backup.sh 104 [BACKUP_DIRECTORY]
# The VM ID must match its isolated Terraform workspace.
set -euo pipefail

usage() {
  echo "Usage: ./deployment/scripts/restore_backup.sh VM_ID IP_OCTET prod [VERIFIED_PROD_BACKUP_DIR]" >&2
  echo "   or: ./deployment/scripts/restore_backup.sh VM_ID [VERIFIED_PROD_BACKUP_DIR]  # existing VM" >&2
  exit 2
}
(( $# >= 1 && $# <= 4 )) || usage
vm_id="$1"
[[ "$vm_id" =~ ^[1-9][0-9]{2,8}$ ]] && (( vm_id > 100 )) ||
  { echo "ERROR: Refusing recovery into VM 100 or invalid VM ID." >&2; exit 1; }
auto_provision=false
backup_arg=""
if (( $# >= 3 )); then
  ip_octet="$2"
  restore_environment="$3"
  [[ "$restore_environment" == prod ]] ||
    { echo "ERROR: Automated restore currently supports only prod." >&2; exit 2; }
  [[ "$ip_octet" =~ ^(0|[1-9][0-9]{0,2})$ ]] &&
    (( ip_octet >= 2 && ip_octet <= 254 )) || usage
  backup_arg="${4:-}"
  auto_provision=true
else
  backup_arg="${2:-}"
fi

repo_root="$(cd -- "$(dirname -- "$0")/../.." && pwd)"
tf_dir="$repo_root/deployment/terraform"
source "$repo_root/deployment/dr/common.sh"

if [[ "$auto_provision" == true ]]; then
  echo "=================================================="
  echo "BEFORE PROVISIONING RECOVERY VM $vm_id"
  echo "=================================================="
  echo "On the Proxmox HOST as root, verify the API token's VM permissions:"
  echo
  printf 'pveum user token permissions root1@pve terraform --path /vms/%s\n' "$vm_id"
  echo
  echo "Check for VM.Allocate and VM.Config.* privileges; nonempty output"
  echo "alone is NOT sufficient. If missing, grant this VM's ACL:"
  printf 'pveum acl modify /vms/%s --roles PVEVMAdmin --users root1@pve --tokens %s\n' \
    "$vm_id" "'root1@pve!terraform'"
  echo
  echo "Use only an approved, unused recovery VM ID. Never grant cluster-wide permissions."
  [[ -t 0 ]] || die "Interactive VM-permissions confirmation is required"
  read -rp "After verifying the VM $vm_id permissions on Proxmox, type YES: " answer
  [[ "$answer" == YES ]] || die "Recovery cancelled before VM provisioning"
  echo "Provisioning VM $vm_id at host octet $ip_octet (k3s only; NO production application)..."
  bash "$repo_root/deployment/scripts/deploy.sh" "$vm_id" "$ip_octet" prod --infra-only ||
    die "VM provisioning failed or was cancelled; not restoring any data"
  echo "Infrastructure is ready; now verifying the recovery target and backup."
fi

for program in terraform git tar python3 timeout age sha256sum; do
  command -v "$program" >/dev/null || die "Missing program: $program"
done
VM_ID="$vm_id"
TF_DIR="$tf_dir"
source "$repo_root/deployment/scripts/terraform_vm_workspace.sh"
terraform_vm_workspace existing

# Never use the default workspace or another VM's state for recovery.
terraform -chdir="$tf_dir" state list |
  grep -Fxq 'proxmox_virtual_environment_vm.k3s[0]' ||
  die "Terraform does not track a VM in this working directory"
state_id="$(terraform -chdir="$tf_dir" output -raw managed_vm_id)"
state_name="$(terraform -chdir="$tf_dir" output -raw managed_vm_name)"
state_cidr="$(terraform -chdir="$tf_dir" output -raw managed_vm_ipv4)"
state_user="$(terraform -chdir="$tf_dir" output -raw managed_vm_username)"
ssh_pub="$(terraform -chdir="$tf_dir" output -raw managed_vm_ssh_public_key_path)"
[[ "$vm_id" == "$state_id" ]] ||
  die "VM ID $vm_id does not match Terraform state ($state_id); refusing."
[[ "$state_name" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ &&
   "$state_user" =~ ^[a-z_][a-z0-9_-]*$ &&
   "$state_cidr" =~ ^[0-9]+(\.[0-9]+){3}/[0-9]+$ &&
   "$ssh_pub" == *.pub ]] ||
  die "Invalid VM network, hostname, username or SSH key in Terraform state"
vm_ip="${state_cidr%%/*}"
[[ "$ssh_pub" == /* ]] || die "Terraform SSH public key must be an absolute path"
export DR_SSH_IDENTITY="${ssh_pub%.pub}"
[[ -r "$DR_SSH_IDENTITY" ]] || die "Cannot read the VM SSH private key"
export DR_SSH_JUMP="${DR_SSH_JUMP:-${JUMP_USER:-jumpuser}@${PROXMOX_HOST:-195.154.103.231}}"
target="$state_user@$vm_ip"
[[ "$target" != *"10.10.10.20" ]] ||
  die "Refusing to connect to the original production IP address"

# Read-only identity checks before touching Kubernetes state.
check_host "$target"
actual_node="$(remote "sudo -n k3s kubectl get nodes -o jsonpath='{.items[0].metadata.name}'")"
actual_host="$(remote "hostname")"
[[ "$actual_node" == "$state_name" && "$actual_host" == "$state_name" ]] ||
  die "Wrong destination: Terraform expects '$state_name'; SSH reports hostname '$actual_host', k3s node '$actual_node'."
export DR_EXPECTED_NODE_NAME="$state_name"
export CONFIRM_RESTORE=prod
# A failed Kubernetes GET is NOT evidence that a namespace is empty.
# Fail closed if any read fails, before restoring production data.
for kind in deployments pvc jobs cronjobs; do
  existing="$(remote "sudo -n k3s kubectl -n prod get $kind -o name")" ||
    die "Unable to inspect target $kind; refusing recovery"
  [[ -z "$existing" ]] ||
    die "The target prod namespace already has $kind: $existing. Refusing automatic overwrite."
done

# Select newest COMPLETED prod backup unless a specific path was supplied.
backup="${backup_arg:-${DR_BACKUP_DIR:-}}"
if [[ -z "$backup" ]]; then
  for candidate in "$HOME/job-market-off-vm-backups/prod"/*; do
    [[ -d "$candidate" && -s "$candidate/SHA256SUMS" ]] || continue
    if [[ -z "$backup" || "$candidate" > "$backup" ]]; then
      backup="$candidate"
    fi
  done
fi
[[ -n "$backup" && "$backup" == /* && -d "$backup" &&
   -s "$backup/SHA256SUMS" && -s "$backup/verification.txt" ]] ||
  die "No verified prod backup found. Supply its absolute path as the last argument."
identity="${DR_IDENTITY:-$HOME/.config/job-market-dr/identity.txt}"
[[ -r "$identity" ]] || die "Missing age private identity"
grep -Fxq "Namespace: prod" "$backup/backup-metadata.txt" ||
  die "Selected backup is not from namespace prod"
(cd "$backup" && sha256sum -c SHA256SUMS) ||
  die "Backup checksums failed; refusing recovery"

gitops_branch="$(sed -n 's/^GitOps branch: //p' "$backup/backup-metadata.txt")"
gitops_sha="$(sed -n 's/^Argo CD observed Git commit: //p' "$backup/backup-metadata.txt")"
release_tag="$(sed -n 's/^Container release tag: //p' "$backup/backup-metadata.txt")"
[[ "$gitops_branch" == production &&
   "$gitops_sha" =~ ^[a-f0-9]{40}$ &&
   "$release_tag" =~ ^sha-[a-f0-9]{40}$ ]] ||
  die "Invalid production commit or release tag in verified backup metadata"

# Use the exact approved GitOps revision; no clone is required on the VM.
if ! git -C "$repo_root" cat-file -e "$gitops_sha^{commit}" 2>/dev/null; then
  echo "Fetching the recorded production GitOps revision..."
  git -C "$repo_root" fetch --no-tags origin production
fi
git -C "$repo_root" cat-file -e "$gitops_sha^{commit}" 2>/dev/null ||
  die "Recorded GitOps revision $gitops_sha is unavailable locally"
if ! git -C "$repo_root" show-ref --verify --quiet refs/remotes/origin/production; then
  git -C "$repo_root" fetch --no-tags origin production
fi
git -C "$repo_root" merge-base --is-ancestor "$gitops_sha" refs/remotes/origin/production ||
  die "The recorded GitOps revision is not on the expected production branch"

printf '\nRECOVERY TARGET: VM %s, %s (%s)\n' "$vm_id" "$state_name" "$vm_ip"
printf 'SOURCE BACKUP:   %s\n' "$backup"
printf 'GITOPS REVISION: %s\n' "$gitops_sha"
printf 'RELEASE IMAGE:   %s\n' "$release_tag"
echo "Airflow, Alertmanager and ETL CronJobs will remain stopped/suspended."
echo "Original production VM 100 is not a recovery target."
if [[ "${DR_CONFIRM_RECOVERY:-}" != "$vm_id" ]]; then
  [[ -t 0 ]] || die "Interactive approval required (or DR_CONFIRM_RECOVERY=$vm_id)"
  read -rp "To restore this backup onto VM $vm_id, type 'RESTORE $vm_id': " answer
  [[ "$answer" == "RESTORE $vm_id" ]] || die "Recovery cancelled"
fi

export DR_IDENTITY="$identity"
run_stage() {
  local stage="$1" max_seconds="${DR_STAGE_TIMEOUT_SECONDS:-1200}"
  if [[ "$stage" == postgres ]]; then
    max_seconds="${DR_POSTGRES_RESTORE_TIMEOUT_SECONDS:-240}"
  fi
  [[ "$max_seconds" =~ ^[0-9]+$ ]] && (( max_seconds >= 30 )) ||
    die "Recovery stage timeout must be an integer >= 30 seconds"
  echo "=== Recovering stage: $stage (timeout: ${max_seconds}s) ==="
  timeout --kill-after=15s "$max_seconds" \
    bash "$repo_root/deployment/dr/restore.sh" prod "$target" "$backup" "$identity" "$stage"
}

run_stage prepare
run_stage secrets
run_stage volumes

# Render only the Postgres resource from version-pinned source, locally.
tmp="$(mktemp -d)"
remote_tmp=""
cleanup() {
  local status=$?
  trap - EXIT
  if [[ -n "$remote_tmp" ]]; then
    remote "rm -rf -- '$remote_tmp'" >/dev/null 2>&1 || true
  fi
  rm -rf -- "$tmp"
  exit "$status"
}
trap cleanup EXIT
git -C "$repo_root" archive "$gitops_sha" deployment/kubernetes |
  tar -xf - -C "$tmp"
echo "=== Starting PostgreSQL alone on the recovery VM ==="
remote "sudo -n k3s kubectl -n prod apply -f -" < "$tmp/deployment/kubernetes/base/postgres.yaml"
remote "sudo -n k3s kubectl -n prod rollout status deployment/postgres --timeout=600s"
run_stage postgres
restored_rows="$(remote 'sudo -n k3s kubectl -n prod exec deployment/postgres -- sh -c '"'"'PGPASSWORD="$POSTGRES_PASSWORD" psql -U job_market -d job_market -Atqc "SELECT count(*) FROM jobs"'"'"'')"
[[ "$restored_rows" =~ ^[0-9]+$ ]] || die "Cannot query recovered PostgreSQL jobs table"
printf 'Recovered PostgreSQL jobs: %s\n' "$restored_rows"

# Deployment manifests are read from the BACKUP-RECORDED revision, not from
# whatever branch the workstation happens to have checked out.
overlay="$tmp/deployment/kubernetes/overlays/prod/kustomization.yaml"
bash "$repo_root/deployment/dr/sanitize_overlay.sh" "$overlay" "$release_tag"
echo "=== Deploying recovered application (Airflow/alerts disabled) ==="
remote "sudo -n sysctl -w vm.max_map_count=262144" >/dev/null
remote_tmp="$(remote 'mktemp -d -t job-market-dr-manifests.XXXXXXXX')"
[[ "$remote_tmp" =~ ^/tmp/job-market-dr-manifests\.[a-zA-Z0-9]+$ ]] ||
  die "Unsafe temporary path returned by VM"
tar -C "$tmp" -czf - deployment/kubernetes |
  remote "tar -C '$remote_tmp' -xzf -"
remote "sudo -n k3s kubectl apply -k '$remote_tmp/deployment/kubernetes/overlays/prod'"

# Verify isolation policy BEFORE checking application functionality.
airflow_replicas="$(remote "sudo -n k3s kubectl -n prod get deployment airflow -o jsonpath='{.spec.replicas}'")"
alerts_replicas="$(remote "sudo -n k3s kubectl -n prod get deployment alertmanager -o jsonpath='{.spec.replicas}'")"
cron_suspended="$(remote "sudo -n k3s kubectl -n prod get cronjob data-update -o jsonpath='{.spec.suspend}'")"
[[ "$airflow_replicas" == 0 && "$alerts_replicas" == 0 &&
   "$cron_suspended" == true ]] ||
  die "Recovered ETL/notification isolation checks failed; inspect VM 101 immediately"

for deployment in backend frontend elasticsearch grafana nginx; do
  echo "Waiting for recovered $deployment..."
  remote "sudo -n k3s kubectl -n prod rollout status deployment/$deployment --timeout=600s"
done

echo "=== Rebuilding Elasticsearch derived index ==="
remote "sudo -n k3s kubectl -n prod exec deployment/backend -- python -c \
  'from job_market.elasticsearch.elasticsearch import sync_jobs_index; print(sync_jobs_index())'"
remote "sudo -n k3s kubectl -n prod get deployments,pods,pvc,cronjobs"
echo "RECOVERY CHECKS PASSED: VM $vm_id, restored jobs $restored_rows."
echo "Airflow and Alertmanager are deliberately NOT running; validate their restored state in a controlled follow-up."
echo "After documenting DR results, destroy only VM $vm_id from this same Terraform state with ./deployment/scripts/destroy.sh $vm_id."
