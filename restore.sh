#!/usr/bin/env bash
# Recover a VERIFIED prod backup onto an already provisioned, disposable VM.
# Run on the workstation: ./restore.sh 101 [BACKUP_DIRECTORY]
# VM ID is an assertion against the CURRENT independent Terraform state.
set -euo pipefail

usage() {
  echo "Usage: ./restore.sh VM_ID [VERIFIED_PROD_BACKUP_DIR]" >&2
  echo "Requires a separate VM-specific Terraform state (e.g. the DR worktree)." >&2
  exit 2
}
(( $# == 1 || $# == 2 )) || usage
vm_id="$1"
[[ "$vm_id" =~ ^[0-9]+$ ]] && (( vm_id > 100 )) ||
  { echo "ERROR: Refusing recovery into VM 100 or invalid VM ID." >&2; exit 1; }

repo_root="$(cd -- "$(dirname -- "$0")" && pwd)"
tf_dir="$repo_root/infrastructure/terraform"
source "$repo_root/dr/common.sh"
for program in terraform git tar python3 timeout age sha256sum; do
  command -v "$program" >/dev/null || die "Missing program: $program"
done
[[ -s "$tf_dir/terraform.tfstate" && -f "$tf_dir/terraform.tfvars" ]] ||
  die "No local VM-specific Terraform state/config. Use your existing DR worktree; never copy production state."

# Do not allow the VM ID argument to select or overwrite another Terraform
# state. The local state and tfvars must ALREADY identify exactly this VM.
terraform -chdir="$tf_dir" state list |
  grep -Fxq 'proxmox_virtual_environment_vm.k3s[0]' ||
  die "Terraform does not track a VM in this working directory"
state_id="$(terraform -chdir="$tf_dir" output -raw managed_vm_id)"
state_name="$(terraform -chdir="$tf_dir" output -raw managed_vm_name)"
state_cidr="$(terraform -chdir="$tf_dir" output -raw managed_vm_ipv4)"
state_user="$(terraform -chdir="$tf_dir" output -raw managed_vm_username)"
ssh_pub="$(terraform -chdir="$tf_dir" output -raw managed_vm_ssh_public_key_path)"
configured_id="$(awk -F= '$1 ~ /^[[:space:]]*vm_id[[:space:]]*$/ { x=$2; sub(/#.*/, "", x); gsub(/[[:space:]]/, "", x); print x }' "$tf_dir/terraform.tfvars")"
[[ "$vm_id" == "$state_id" && "$vm_id" == "$configured_id" ]] ||
  die "VM ID $vm_id does not match Terraform state ($state_id) and tfvars ($configured_id); refusing."
[[ "$state_name" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ &&
   "$state_user" =~ ^[a-z_][a-z0-9_-]*$ &&
   "$state_cidr" =~ ^[0-9]+(\.[0-9]+){3}/[0-9]+$ &&
   "$ssh_pub" == *.pub ]] ||
  die "Invalid VM network, hostname, username or SSH key in Terraform state"
vm_ip="${state_cidr%%/*}"
[[ "$ssh_pub" == /* ]] || die "Terraform SSH public key must be an absolute path"
export DR_SSH_IDENTITY="${ssh_pub%.pub}"
[[ -r "$DR_SSH_IDENTITY" ]] || die "Cannot read the VM SSH private key"
export DR_SSH_JUMP="${DR_SSH_JUMP:-${JUMP_USER:-jumpuser}${PROXMOX_HOST:-195.154.103.231}}"
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
[[ -z "$(remote "sudo -n k3s kubectl -n prod get deployments -o name")" &&
   -z "$(remote "sudo -n k3s kubectl -n prod get pvc -o name")" &&
   -z "$(remote "sudo -n k3s kubectl -n prod get jobs -o name")" ]] ||
  die "The target prod namespace already has deployments, PVCs, or jobs. Refusing automatic overwrite; inspect before resuming manually."

# Select newest COMPLETED prod backup unless a specific path was supplied.
backup="${2:-${DR_BACKUP_DIR:-}}"
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
  die "No verified prod backup found. Supply its absolute path as argument 2."
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
  local stage="$1"
  echo "=== Recovering stage: $stage ==="
  timeout --kill-after=15s "${DR_STAGE_TIMEOUT_SECONDS:-1200}" \
    bash "$repo_root/dr/restore.sh" prod "$target" "$backup" "$identity" "$stage"
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
git -C "$repo_root" archive "$gitops_sha" kubernetes |
  tar -xf - -C "$tmp"
echo "=== Starting PostgreSQL alone on the recovery VM ==="
remote "sudo -n k3s kubectl -n prod apply -f -" < "$tmp/kubernetes/base/postgres.yaml"
remote "sudo -n k3s kubectl -n prod rollout status deployment/postgres --timeout=600s"
run_stage postgres
restored_rows="$(remote 'sudo -n k3s kubectl -n prod exec deployment/postgres -- sh -c '"'"'PGPASSWORD="$POSTGRES_PASSWORD" psql -U job_market -d job_market -Atqc "SELECT count(*) FROM jobs"'"'"'')"
[[ "$restored_rows" =~ ^[0-9]+$ ]] || die "Cannot query recovered PostgreSQL jobs table"
printf 'Recovered PostgreSQL jobs: %s\n' "$restored_rows"

# Deployment manifests are read from the BACKUP-RECORDED revision, not from
# whatever branch the workstation happens to have checked out.
overlay="$tmp/kubernetes/overlays/prod/kustomization.yaml"
[[ -f "$overlay" ]] || die "Recorded production revision has no prod overlay"
[[ "$(grep -c 'newTag: sha-' "$overlay")" == 2 ]] ||
  die "Expected two immutable SHA-tagged application images"
sed -i -E "s/newTag: sha-[a-f0-9]{40}/newTag: $release_tag/" "$overlay"
[[ "$(grep -Fc "newTag: $release_tag" "$overlay")" == 2 ]] ||
  die "Failed to pin both restored images"
if grep -q '^patches:' "$overlay"; then
  die "Production overlay already declares patches; inspect before adding DR isolation patches"
fi
cat >> "$overlay" <<'PATCHES'
# DR-only safety overrides. Never enable automated ingestion or notifications.
patches:
  - target:
      kind: Deployment
      name: airflow
    patch: |-
      - op: replace
        path: /spec/replicas
        value: 0
  - target:
      kind: Deployment
      name: alertmanager
    patch: |-
      - op: replace
        path: /spec/replicas
        value: 0
  - target:
      kind: CronJob
      name: data-update
    patch: |-
      - op: replace
        path: /spec/suspend
        value: true
PATCHES
echo "=== Deploying recovered application (Airflow/alerts disabled) ==="
remote "sudo -n sysctl -w vm.max_map_count=262144" >/dev/null
remote_tmp="$(remote 'mktemp -d -t job-market-dr-manifests.XXXXXXXX')"
[[ "$remote_tmp" =~ ^/tmp/job-market-dr-manifests\.[a-zA-Z0-9]+$ ]] ||
  die "Unsafe temporary path returned by VM"
tar -C "$tmp" -czf - kubernetes |
  remote "tar -C '$remote_tmp' -xzf -"
remote "sudo -n k3s kubectl apply -k '$remote_tmp/kubernetes/overlays/prod'"

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
echo "After documenting DR results, destroy only VM $vm_id from this same Terraform state with ./destroy.sh $vm_id."
