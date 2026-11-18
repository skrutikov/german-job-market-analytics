#!/usr/bin/env bash
# Safely finalize an already copied but incompletely verified backup.
# Does NOT pause workloads, change Argo CD, or copy any source volumes.
# Usage: bash dr/finalize_backup.sh prod k3s-vm /abs/path/prod/TIMESTAMP
set -euo pipefail
source "$(dirname -- "$0")/common.sh"

(( $# == 3 || $# == 4 )) ||
  die "Usage: bash dr/finalize_backup.sh dev|prod SSH_HOST BACKUP_DIR [AGE_IDENTITY]"
ns="$1"; validate_namespace "$ns"
host="$2"; backup="$3"
identity="${4:-${DR_IDENTITY:-$HOME/.config/job-market-dr/identity.txt}}"
[[ "$backup" == /* && -d "$backup" ]] ||
  die "Backup directory must exist and be an absolute workstation path"
[[ -f "$identity" ]] || die "Private age identity not found"
[[ ! -e "$backup/SHA256SUMS" && ! -e "$backup/verification.txt" ]] ||
  die "Backup already finalized or has a checksum manifest; inspect before proceeding"
require_tools
command -v python3 >/dev/null || die "python3 is required"
command -v tar >/dev/null || die "tar is required"
umask 077

for name in secret.json.age postgres.dump.age airflow-state.tar.gz.age \
            etl-data.tar.gz.age grafana-data.tar.gz.age backup-metadata.txt; do
  [[ -s "$backup/$name" ]] || die "Required backup artifact missing or empty: $name"
done
if compgen -G "$backup/*.partial" >/dev/null; then
  die "Incomplete .partial files remain; investigate before finalization"
fi

grep -Fxq "Namespace: $ns" "$backup/backup-metadata.txt" ||
  die "Backup namespace metadata does not match $ns"
grep -Fxq "Source SSH host: $host" "$backup/backup-metadata.txt" ||
  die "Source SSH host metadata does not match $host"
stamp="${backup##*/}"
grep -Fxq "Backup started (UTC): $stamp" "$backup/backup-metadata.txt" ||
  die "Backup metadata timestamp does not match the directory name"

complete=false
cleanup() {
  local rc=$?
  trap - EXIT
  if ! "$complete"; then
    rm -f "$backup/SHA256SUMS" "$backup/verification.txt.partial"
    echo "Finalization failed; backup is NOT marked complete: $backup" >&2
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

(
  cd "$backup"
  sha256sum secret.json.age postgres.dump.age airflow-state.tar.gz.age \
            etl-data.tar.gz.age grafana-data.tar.gz.age backup-metadata.txt \
    > SHA256SUMS
)
if bash "$(dirname -- "$0")/verify_backup.sh" "$ns" "$host" "$backup" "$identity" \
    > "$backup/verification.txt.partial" 2>&1; then
  mv "$backup/verification.txt.partial" "$backup/verification.txt"
else
  cat "$backup/verification.txt.partial" >&2
  die "Backup archive verification failed"
fi

(
  cd "$backup"
  sha256sum secret.json.age postgres.dump.age airflow-state.tar.gz.age \
            etl-data.tar.gz.age grafana-data.tar.gz.age \
            backup-metadata.txt verification.txt > SHA256SUMS
  sha256sum -c SHA256SUMS
)
cat > "$backup/README.txt" <<EOF
Verified disaster-recovery backup (finalized after an interrupted verification).
Namespace: $ns
Created UTC: $stamp
Source SSH host: $host
Encrypted PostgreSQL, Secret and three PVC archives.
Deployment metadata: backup-metadata.txt
Verification report: verification.txt
Verify with: (cd "$backup" && sha256sum -c SHA256SUMS)
Protect the age private identity independently from archives.
EOF
complete=true
printf 'Backup finalized, verified and checksummed: %s\n' "$backup"
