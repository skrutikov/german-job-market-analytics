#!/usr/bin/env bash
# Run on an operator workstation, never on the Proxmox/k3s VM.
# Usage: bash deployment/scripts/create_backup.sh prod k3s-vm (or specify recipient and backup root)
set -euo pipefail
source "$(dirname "$0")/../dr/common.sh"
source "$(dirname "$0")/../dr/maintenance.sh"

(( $# == 2 || $# == 4 )) ||
  die "Usage: bash deployment/scripts/create_backup.sh dev|prod SSH_HOST [AGE_RECIPIENT LOCAL_BACKUP_ROOT]"
ns="$1"; validate_namespace "$ns"
require_tools
command -v python3 >/dev/null || die "python3 is required"
command -v tar >/dev/null || die "tar is required"
identity="${DR_IDENTITY:-$HOME/.config/job-market-dr/identity.txt}"
[[ -f "$identity" ]] || die "Missing age identity: $identity (see runbook)"
if (( $# == 4 )); then
  recipient="$3"; root="$4"
else
  command -v age-keygen >/dev/null || die "age-keygen is required"
  recipient="$(age-keygen -y "$identity")"
  root="${DR_BACKUP_ROOT:-$HOME/job-market-off-vm-backups}"
fi
[[ "$recipient" == age1* || "$recipient" == ssh-* ]] ||
  die "Supply an age recipient (age1... or SSH public key)"
[[ "$root" == /* ]] || die "Backup root must be an absolute local path"
printf 'key check' | age -r "$recipient" |
  age -d -i "$identity" | grep -Fxq 'key check' ||
  die "Selected age recipient and identity do not match"
check_host "$2"
umask 077

remote "sudo -n k3s kubectl -n $ns rollout status deployment/postgres --timeout=120s" >/dev/null

# Preflight k3s local-path volumes *before* stopping production workloads.
# Stream compressed tar from the VM over SSH, without kubectl exec.
declare -A dr_volume_paths
for claim in airflow-state etl-data grafana-data; do
  path="$(local_pv_path "$ns" "$claim")"
  # Test sudo permission and the path without reading file data.
  remote "sudo -n tar -C $path -czf - --files-from /dev/null >/dev/null" ||
    die "Cannot archive $path using passwordless sudo tar on VM"
  dr_volume_paths["$claim"]="$path"
done

# Request downtime approval only after every read-only storage preflight passes.
# Confirm a short maintenance interruption before stopping production writers.
if [[ "${DR_CONFIRM_MAINTENANCE:-}" != "$ns" ]]; then
  [[ -t 0 ]] || die "Set DR_CONFIRM_MAINTENANCE=$ns for noninteractive use"
  printf 'Pause %s Argo auto-sync and Airflow/Grafana briefly? Type YES: ' "$ns"
  read -r answer
  [[ "$answer" == YES ]] || die "Backup cancelled"
fi

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
output="$root/$ns/$stamp"
[[ ! -e "$output" ]] || die "Backup already exists: $output"
mkdir -p "$output"
complete=false
cleanup() {
  local rc=$?
  trap - EXIT
  set +e
  end_maintenance "$ns" || rc=1
  if ! "$complete"; then
    rm -f "$output"/*.partial "$output/SHA256SUMS"
    printf 'Backup incomplete: %s (do NOT restore this directory)\n' "$output" >&2
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Automatically stop SQLite writers, preserving the previous workload
# replicas and GitOps auto-sync setting for trap-based recovery.
begin_maintenance "$ns"

save_stream() {
  local name="$1" tmp="$output/$1.partial"
  # Files are encrypted before being written to the off-VM workstation disk.
  age -r "$recipient" -o "$tmp"
  mv "$tmp" "$output/$name"
}

printf 'Backing up %s from %s to %s\n' "$ns" "$DR_SSH_HOST" "$output"
# Record deployed images and the Argo CD Git revision from the live cluster.
# The VM/workstation Git checkout may be on a different branch.
repo_root="$(cd -- "$(dirname -- "$0")/../.." && pwd)"
remote "sudo -n k3s kubectl -n $ns get deployments backend frontend airflow -o json" \
  > "$output/deployments.json.partial"
remote "sudo -n k3s kubectl -n argocd get application job-market-$ns -o json" \
  > "$output/argocd.json.partial"
python3 "$repo_root/deployment/dr/record_metadata.py" \
  --namespace "$ns" --timestamp "$stamp" --ssh-host "$DR_SSH_HOST" \
  --deployments "$output/deployments.json.partial" \
  --application "$output/argocd.json.partial" \
  > "$output/backup-metadata.txt.partial"
mv "$output/backup-metadata.txt.partial" "$output/backup-metadata.txt"
rm -f "$output/deployments.json.partial" "$output/argocd.json.partial"
remote "sudo -n k3s kubectl -n $ns get secret job-market-secrets -o json" |
  python3 -c 'import json,sys; x=json.load(sys.stdin); print(json.dumps({"apiVersion":"v1","kind":"Secret","metadata":{"name":"job-market-secrets","namespace":x["metadata"]["namespace"]},"type":x.get("type","Opaque"),"data":x["data"]}))' |
  save_stream "secret.json.age"

# Custom-format pg_dump is transactionally consistent while PostgreSQL runs.
remote "sudo -n k3s kubectl -n $ns exec deployment/postgres -- sh -c 'export PGPASSWORD=\"\$POSTGRES_PASSWORD\"; exec pg_dump -U job_market -d job_market -Fc --no-owner --no-privileges'" |
  save_stream "postgres.dump.age"

for claim in airflow-state etl-data grafana-data; do
  echo "Copying encrypted PVC archive: $claim"
  # Compress on the VM and stream via SSH, bypassing Kubernetes API exec.
  remote "sudo -n tar -C ${dr_volume_paths[$claim]} -czf - ." |
    save_stream "$claim.tar.gz.age"
done

# Data capture is complete. Resume production *before* time-consuming
# checksum and archive verification, which operate on saved copies.
echo "All volumes copied; restoring Airflow/Grafana and Argo CD state..."
end_maintenance "$ns"
echo "Production maintenance finished; verifying the saved backup..."

(
  cd "$output"
  sha256sum *.age backup-metadata.txt > SHA256SUMS
)
# Integrity validation is automatic; real DB restore can be enabled with
# DR_TEST_DB_RESTORE=1 to use an isolated LOCAL postgres:17 Docker container.
if bash "$repo_root/deployment/dr/verify_backup.sh" "$ns" "$DR_SSH_HOST" "$output" "$identity" \
    2>&1 | tee "$output/verification.txt.partial"; then
  mv "$output/verification.txt.partial" "$output/verification.txt"
else
  die "Archive verification failed; see the verification output above"
fi
(
  cd "$output"
  sha256sum *.age backup-metadata.txt verification.txt > SHA256SUMS
  sha256sum -c SHA256SUMS
)
cat > "$output/README.txt" <<EOF
Encrypted disaster-recovery backup
Namespace: $ns
Created UTC: $stamp
Source SSH host: $DR_SSH_HOST
PostgreSQL: custom pg_dump (PostgreSQL 17)
Archives: airflow-state, etl-data, grafana-data
Deployment version and timestamp: backup-metadata.txt
Verification results: verification.txt
Verify with: (cd "$output" && sha256sum -c SHA256SUMS)
Restore using the matching namespace and the age identity.
These artifacts contain sensitive data; protect encryption keys separately.
EOF
complete=true
printf 'Backup completed and checksummed outside the VM: %s\n' "$output"
