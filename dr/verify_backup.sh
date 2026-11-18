#!/usr/bin/env bash
# Validates a backup without modifying the production cluster.
# Optional DR_TEST_DB_RESTORE=1 runs an actual restore inside local Docker.
set -euo pipefail
source "$(dirname -- "$0")/common.sh"
(( $# == 4 )) ||
  die "Usage: bash dr/verify_backup.sh dev|prod SSH_HOST BACKUP_DIR AGE_IDENTITY"
ns="$1"; validate_namespace "$ns"
host="$2"; backup="$3"; identity="$4"
require_tools
command -v tar >/dev/null || die "tar is required"
command -v python3 >/dev/null || die "python3 is required"
command -v timeout >/dev/null || die "timeout is required (coreutils)"
verify_timeout="${DR_VERIFY_TIMEOUT_SECONDS:-900}"
[[ "$verify_timeout" =~ ^[0-9]+$ ]] && (( verify_timeout >= 60 )) ||
  die "DR_VERIFY_TIMEOUT_SECONDS must be an integer >= 60"
[[ -d "$backup" && -f "$backup/SHA256SUMS" && -f "$identity" ]] ||
  die "Backup, checksums or private age identity missing"
echo "Checking cluster connection and checksums..."
check_host "$host"
(cd "$backup" && sha256sum -c SHA256SUMS)
decrypt() { age -d -i "$identity" "$backup/$1"; }

echo "Validating encrypted Kubernetes Secret and namespace"
decrypt secret.json.age | python3 -c '
import json, sys
data = json.load(sys.stdin)
expected = sys.argv[1]
assert data.get("kind") == "Secret"
assert data.get("metadata", {}).get("namespace") == expected
assert data.get("metadata", {}).get("name") == "job-market-secrets"
assert isinstance(data.get("data"), dict) and data["data"]
' "$ns"

echo "Read-only PostgreSQL dump format check (timeout: ${verify_timeout}s)..."
# Unlike the previous unbounded kubectl exec, timeout prevents an API stream
# that has stopped responding from hanging verification indefinitely.
decrypt postgres.dump.age |
  timeout "$verify_timeout" ssh -T -o BatchMode=yes -o ConnectTimeout=15 \
    -o ServerAliveInterval=15 -o ServerAliveCountMax=3 "$DR_SSH_HOST" \
    "sudo -n k3s kubectl -n $ns exec -i deployment/postgres -- pg_restore --list" >/dev/null
echo "PostgreSQL archive format: OK"

for name in airflow-state etl-data grafana-data; do
  echo "Validating encrypted compressed volume archive: $name"
  decrypt "$name.tar.gz.age" | timeout "$verify_timeout" tar -tzf - >/dev/null
  echo "$name archive: OK"
done
echo "All encrypted backup archives passed format and decryption checks."

if [[ "${DR_TEST_DB_RESTORE:-0}" == 1 ]]; then
  command -v docker >/dev/null || die "Local Docker is required for DR_TEST_DB_RESTORE=1"
  docker info >/dev/null 2>&1 || die "Local Docker daemon is unavailable"
  container="job-market-dr-verify-$$"
  docker run --rm -d --network none --name "$container" \
    -e POSTGRES_USER=job_market -e POSTGRES_DB=job_market \
    -e POSTGRES_PASSWORD=local-test-only postgres:17 >/dev/null
  cleanup_docker() { docker rm -f "$container" >/dev/null 2>&1 || true; }
  trap cleanup_docker EXIT
  ready=false
  for ((i=1; i<=60; i++)); do
    if docker exec "$container" pg_isready -U job_market >/dev/null 2>&1; then
      ready=true
      break
    fi
    sleep 1
  done
  "$ready" || die "Disposable PostgreSQL 17 failed to start"
  decrypt postgres.dump.age |
    docker exec -i "$container" pg_restore -U job_market -d job_market \
      --no-owner --no-privileges --exit-on-error --single-transaction
  rows="$(docker exec "$container" psql -U job_market -d job_market -Atqc \
    'SELECT count(*) FROM jobs')"
  [[ "$rows" =~ ^[0-9]+$ ]] || die "Restored jobs table cannot be queried"
  echo "Disposable PostgreSQL restore succeeded; jobs rows: $rows"
  cleanup_docker
  trap - EXIT
else
  echo "Full disposable PostgreSQL restore not requested (DR_TEST_DB_RESTORE=1 to enable)."
fi
echo "Backup verification PASSED"
