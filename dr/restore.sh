#!/usr/bin/env bash
# Run on the operator workstation against a disposable/rebuilt k3s VM.
# Usage: CONFIRM_RESTORE=dev bash dr/restore.sh dev k3s-vm /backups/dev/TIMESTAMP /path/key.txt secrets|data
set -euo pipefail
source "$(dirname "$0")/common.sh"

(( $# == 5 )) ||
  die "Usage: CONFIRM_RESTORE=dev bash dr/restore.sh dev|prod SSH_HOST BACKUP_DIR AGE_IDENTITY secrets|data"
ns="$1"; validate_namespace "$ns"
[[ "${CONFIRM_RESTORE:-}" == "$ns" ]] ||
  die "Set CONFIRM_RESTORE=$ns to acknowledge that this overwrites live state"
check_host "$2"
backup="$3"; identity="$4"; stage="$5"
[[ "$stage" == secrets || "$stage" == data ]] || die "Stage must be secrets or data"
[[ -d "$backup" && -f "$backup/SHA256SUMS" && -f "$identity" ]] ||
  die "Backup, checksums, or age private key missing"
require_tools
command -v python3 >/dev/null || die "python3 is required"

(
  cd "$backup"
  sha256sum -c SHA256SUMS
) || die "Backup checksum verification failed"

decrypt() { age -d -i "$identity" "$backup/$1"; }
active_helper=false
cleanup() {
  if "$active_helper"; then delete_helper "$ns" || true; fi
}
trap cleanup EXIT

if [[ "$stage" == secrets ]]; then
  # Execute this first on the new cluster, before running kubernetes/deploy.sh.
  remote "sudo -n k3s kubectl create namespace $ns --dry-run=client -o yaml | sudo -n k3s kubectl apply -f -" >/dev/null
  decrypt "secret.json.age" |
    remote "sudo -n k3s kubectl -n $ns apply -f -"
  printf 'Restored %s Secret. Deploy the matching GitOps revision next.\n' "$ns"
  exit 0
fi

# Database recovery requires a running PostgreSQL deployment with the old
# restored Secret. Both application writers and PVC owners must be stopped;
# disable Argo auto-sync for the duration (see runbook).
check_quiesced "$ns"
for deployment in backend; do
  replicas="$(remote "sudo -n k3s kubectl -n $ns get deployment $deployment -o jsonpath='{.spec.replicas}'")"
  [[ "$replicas" == 0 ]] || die "$deployment must be scaled to zero for DB recovery"
done
remote "sudo -n k3s kubectl -n $ns rollout status deployment/postgres --timeout=120s" >/dev/null

# Validate backup format before performing destructive pg_restore.
decrypt "postgres.dump.age" |
  remote "sudo -n k3s kubectl -n $ns exec -i deployment/postgres -- pg_restore --list" >/dev/null

# Restore the PostgreSQL schema and rows as one transaction.
decrypt "postgres.dump.age" |
  remote "sudo -n k3s kubectl -n $ns exec -i deployment/postgres -- sh -c 'export PGPASSWORD=\"\$POSTGRES_PASSWORD\"; exec pg_restore -U job_market -d job_market --clean --if-exists --no-owner --no-privileges --exit-on-error --single-transaction'"

for claim in airflow-state etl-data grafana-data; do
  create_helper "$ns" "$claim"
  active_helper=true
  # Deliberately refuse to overlay possibly unrelated data. Restore to
  # freshly provisioned empty PVCs, not existing populated volumes.
  if remote "sudo -n k3s kubectl -n $ns exec dr-volume-helper -- sh -c 'test -z \"\$(ls -A /backup)\"'"; then
    decrypt "$claim.tar.gz.age" | gzip -dc |
      remote "sudo -n k3s kubectl -n $ns exec -i dr-volume-helper -- tar -C /backup -xf -"
  else
    die "$claim is not empty; use fresh PVCs, do not overwrite existing data"
  fi
  delete_helper "$ns"
  active_helper=false
done

printf 'Data restored to %s. Re-enable workloads/Argo only after validation.\n' "$ns"
