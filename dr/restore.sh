#!/usr/bin/env bash
# Run on the operator workstation against a disposable/rebuilt k3s VM.
# Usage: CONFIRM_RESTORE=dev bash dr/restore.sh dev k3s-vm /backups/dev/TIMESTAMP /path/key.txt prepare|secrets|volumes|postgres
set -euo pipefail
source "$(dirname "$0")/common.sh"

(( $# == 5 )) ||
  die "Usage: CONFIRM_RESTORE=dev bash dr/restore.sh dev|prod SSH_HOST BACKUP_DIR AGE_IDENTITY prepare|secrets|volumes|postgres"
ns="$1"; validate_namespace "$ns"
[[ "${CONFIRM_RESTORE:-}" == "$ns" ]] ||
  die "Set CONFIRM_RESTORE=$ns to acknowledge that this overwrites live state"
check_host "$2"
backup="$3"; identity="$4"; stage="$5"
[[ "$stage" == prepare || "$stage" == secrets || "$stage" == volumes || "$stage" == postgres ]] || die "Stage must be prepare, secrets, volumes or postgres"
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

if [[ "$stage" == prepare ]]; then
  # Fresh PVCs only; must run BEFORE deploying stateful applications.
  remote "sudo -n k3s kubectl create namespace $ns --dry-run=client -o yaml | sudo -n k3s kubectl apply -f -" >/dev/null
  remote "sudo -n k3s kubectl -n $ns apply -f -" <<YAML
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-data
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 4Gi
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: airflow-state
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 2Gi
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: etl-data
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 4Gi
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: grafana-data
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
YAML
  echo "Prepared fresh PVCs. Restore secrets and volumes before deploying apps."
  exit 0
fi

if [[ "$stage" == secrets ]]; then
  remote "sudo -n k3s kubectl create namespace $ns --dry-run=client -o yaml | sudo -n k3s kubectl apply -f -" >/dev/null
  decrypt "secret.json.age" |
    remote "sudo -n k3s kubectl -n $ns apply -f -"
  printf 'Restored %s Secret. Do not regenerate credentials during VM bootstrap.\n' "$ns"
  exit 0
fi

if [[ "$stage" == volumes ]]; then
  # App workloads must NOT be running: use fresh/empty claims.
  for deployment in airflow grafana; do
    replicas="$(remote "sudo -n k3s kubectl -n $ns get deployment $deployment -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0")"
    [[ "$replicas" == 0 ]] || die "$deployment must be stopped"
  done
  for claim in airflow-state etl-data grafana-data; do
    create_helper "$ns" "$claim"
    active_helper=true
    if remote "sudo -n k3s kubectl -n $ns exec dr-volume-helper -- sh -c 'test -z \"\$(ls -A /backup)\"'"; then
      decrypt "$claim.tar.gz.age" | gzip -dc |
        remote "sudo -n k3s kubectl -n $ns exec -i dr-volume-helper -- tar -C /backup -xf -"
    else
      die "$claim is not empty; use fresh PVCs, do not overwrite existing data"
    fi
    delete_helper "$ns"
    active_helper=false
  done
  echo "Restored file volumes. Deploy PostgreSQL alone next."
  exit 0
fi

# PostgreSQL-only stage: postgres.yaml must be deployed, but application and
# ETL writers must not have been started yet on the new VM.
for deployment in backend airflow; do
  replicas="$(remote "sudo -n k3s kubectl -n $ns get deployment $deployment -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0")"
  [[ "$replicas" == 0 ]] || die "$deployment must be stopped for DB restoration"
done
active_jobs="$(remote "sudo -n k3s kubectl -n $ns get jobs -o json" |
  python3 -c 'import json,sys; print(sum(j.get("status",{}).get("active",0) for j in json.load(sys.stdin)["items"]))')"
[[ "$active_jobs" == 0 ]] || die "$active_jobs ETL Jobs are active"
remote "sudo -n k3s kubectl -n $ns rollout status deployment/postgres --timeout=180s" >/dev/null

# Validate backup format before destructive pg_restore.
decrypt "postgres.dump.age" |
  remote "sudo -n k3s kubectl -n $ns exec -i deployment/postgres -- pg_restore --list" >/dev/null

decrypt "postgres.dump.age" |
  remote "sudo -n k3s kubectl -n $ns exec -i deployment/postgres -- sh -c 'export PGPASSWORD=\"\$POSTGRES_PASSWORD\"; exec pg_restore -U job_market -d job_market --clean --if-exists --no-owner --no-privileges --exit-on-error --single-transaction'"

printf 'PostgreSQL restored in %s. Complete deployment and verify before restarting ETL.\n' "$ns"
