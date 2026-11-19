#!/usr/bin/env bash
# Integration test: finalize synthetic encrypted backup with no reachable VM.
set -euo pipefail
(( $# == 1 )) || { echo "Usage: bash dr/test_offline_finalize.sh /tmp/dr-test.dump" >&2; exit 2; }
source_dump="$1"
[[ -s "$source_dump" ]] || { echo "Synthetic PostgreSQL dump missing" >&2; exit 1; }
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
identity="$tmp/identity.txt"
age-keygen -o "$identity" >/dev/null
recipient="$(age-keygen -y "$identity")"
stamp="20261118T165839Z"
backup="$tmp/backups/prod/$stamp"
mkdir -p "$backup"
age -r "$recipient" -o "$backup/postgres.dump.age" "$source_dump"
printf '%s\n' '{"apiVersion":"v1","kind":"Secret","metadata":{"name":"job-market-secrets","namespace":"prod"},"data":{"test":"c2VjcmV0"}}' |
  age -r "$recipient" -o "$backup/secret.json.age"
for claim in airflow-state etl-data grafana-data; do
  printf '%s\n' "$claim sample file" > "$tmp/sample.txt"
  tar -C "$tmp" -czf - sample.txt |
    age -r "$recipient" -o "$backup/$claim.tar.gz.age"
done
cat > "$backup/backup-metadata.txt" <<EOF
Job Market Analytics — disaster-recovery backup metadata
Namespace: prod
Backup started (UTC): $stamp
Source SSH host: no-such-host
EOF

# Validation must succeed despite no Kubernetes or SSH target existing.
bash "$(dirname -- "$0")/finalize_backup.sh" prod no-such-host "$backup" "$identity"
(cd "$backup" && sha256sum -c SHA256SUMS)
grep -Fq "Backup verification PASSED" "$backup/verification.txt"
echo "Offline encrypted-backup finalization integration test PASSED"
