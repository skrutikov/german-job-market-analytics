#!/usr/bin/env bash
# Run on an operator workstation, never on the Proxmox/k3s VM.
# Usage: bash dr/backup.sh dev k3s-vm AGE_RECIPIENT /safe/off-vm/backups
set -euo pipefail
source "$(dirname "$0")/common.sh"

(( $# == 4 )) || die "Usage: bash dr/backup.sh dev|prod SSH_HOST AGE_RECIPIENT LOCAL_BACKUP_ROOT"
ns="$1"; validate_namespace "$ns"
check_host "$2"
recipient="$3"
root="$4"
[[ "$recipient" == age1* || "$recipient" == ssh-* ]] ||
  die "Supply a valid age recipient (age1... or SSH public key)"
[[ -n "$root" && "$root" == /* ]] || die "Backup root must be an absolute local path"
require_tools
command -v python3 >/dev/null || die "python3 is required"
umask 077

# Airflow SQLite and Grafana data must be quiescent for consistent volume copies.
# Pause Argo CD automated reconciliation and both Deployments beforehand.
check_quiesced "$ns"
remote "sudo -n k3s kubectl -n $ns rollout status deployment/postgres --timeout=120s" >/dev/null

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
output="$root/$ns/$stamp"
[[ ! -e "$output" ]] || die "Backup already exists: $output"
mkdir -p "$output"
active_helper=false
complete=false
cleanup() {
  if "$active_helper"; then delete_helper "$ns" || true; fi
  if ! "$complete"; then
    rm -f "$output"/*.partial
    printf 'Backup incomplete: %s (do NOT restore this directory)\n' "$output" >&2
  fi
}
trap cleanup EXIT

save_stream() {
  local name="$1" tmp="$output/$1.partial"
  # Files are encrypted before being written to the off-VM workstation disk.
  age -r "$recipient" -o "$tmp"
  mv "$tmp" "$output/$name"
}

printf 'Backing up %s from %s to %s\n' "$ns" "$DR_SSH_HOST" "$output"
remote "sudo -n k3s kubectl -n $ns get secret job-market-secrets -o json" |
  python3 -c 'import json,sys; x=json.load(sys.stdin); print(json.dumps({"apiVersion":"v1","kind":"Secret","metadata":{"name":"job-market-secrets","namespace":x["metadata"]["namespace"]},"type":x.get("type","Opaque"),"data":x["data"]}))' |
  save_stream "secret.json.age"

# Custom-format pg_dump is transactionally consistent while PostgreSQL runs.
remote "sudo -n k3s kubectl -n $ns exec deployment/postgres -- sh -c 'export PGPASSWORD=\"\$POSTGRES_PASSWORD\"; exec pg_dump -U job_market -d job_market -Fc --no-owner --no-privileges'" |
  save_stream "postgres.dump.age"

for claim in airflow-state etl-data grafana-data; do
  create_helper "$ns" "$claim"
  active_helper=true
  remote "sudo -n k3s kubectl -n $ns exec dr-volume-helper -- tar -C /backup -cf - ." |
    gzip -1 | save_stream "$claim.tar.gz.age"
  delete_helper "$ns"
  active_helper=false
done

(
  cd "$output"
  sha256sum *.age > SHA256SUMS
)
cat > "$output/README.txt" <<EOF
Encrypted disaster-recovery backup
Namespace: $ns
Created UTC: $stamp
Source SSH host: $DR_SSH_HOST
PostgreSQL: custom pg_dump (PostgreSQL 17)
Archives: airflow-state, etl-data, grafana-data
Verify with: (cd "$output" && sha256sum -c SHA256SUMS)
Restore using the matching namespace and the age identity.
These artifacts contain sensitive data; protect encryption keys separately.
EOF
complete=true
printf 'Backup completed and checksummed outside the VM: %s\n' "$output"
