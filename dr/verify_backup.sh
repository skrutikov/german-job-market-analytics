#!/usr/bin/env bash
# Validates a backup without modifying the production cluster.
# Optional DR_TEST_DB_RESTORE=1 runs an actual restore inside local Docker.
set -euo pipefail
source "$(dirname -- "$0")/common.sh"
(( $# == 4 )) ||
  die "Usage: bash dr/verify_backup.sh dev|prod SSH_HOST BACKUP_DIR AGE_IDENTITY"
ns="$1"; validate_namespace "$ns"
host="$2"; backup="$3"; identity="$4"
[[ -n "$host" && "$host" =~ ^[a-zA-Z0-9_.@-]+$ ]] ||
  die "Invalid source SSH host in metadata"
require_tools
command -v tar >/dev/null || die "tar is required"
command -v python3 >/dev/null || die "python3 is required"
command -v timeout >/dev/null || die "timeout is required (coreutils)"
verify_timeout="${DR_VERIFY_TIMEOUT_SECONDS:-900}"
[[ "$verify_timeout" =~ ^[0-9]+$ ]] && (( verify_timeout >= 60 )) ||
  die "DR_VERIFY_TIMEOUT_SECONDS must be an integer >= 60"
[[ -d "$backup" && -f "$backup/SHA256SUMS" && -f "$identity" ]] ||
  die "Backup, checksums or private age identity missing"
script_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
echo "Verifying backup locally; no SSH or Kubernetes connection needed."
(cd "$backup" && sha256sum -c SHA256SUMS)

# Apply one timeout to the WHOLE decryption + validation pipeline, not just
# its last command. On expiration, timeout signals the entire process group.
verify_stream() {
  local file="$1"; shift
  timeout --kill-after=5s "$verify_timeout" \
    bash -o pipefail -c 'age -d -i "$1" "$2" | "${@:3}"' \
    dr-verify "$identity" "$backup/$file" "$@"
}

echo "Validating encrypted Kubernetes Secret and namespace..."
verify_stream secret.json.age python3 -c '
import json, sys
data = json.load(sys.stdin)
expected = sys.argv[1]
assert data.get("kind") == "Secret"
assert data.get("metadata", {}).get("namespace") == expected
assert data.get("metadata", {}).get("name") == "job-market-secrets"
assert isinstance(data.get("data"), dict) and data["data"]
' "$ns"

echo "Authenticating entire PostgreSQL dump and checking PGDMP header..."
verify_stream postgres.dump.age python3 "$script_dir/check_pg_dump.py"

# A real pg_restore --list is useful, but NEVER send the dump through the
# Kubernetes API. Prefer a local PostgreSQL 17+ client, then an existing
# network-isolated postgres:17 Docker image. A full restore still requires
# the separate optional DR_TEST_DB_RESTORE=1 drill.
pg_list_checked=false
if command -v pg_restore >/dev/null 2>&1; then
  version="$(pg_restore --version)"
  if [[ "$version" =~ PostgreSQL[[:space:]]([0-9]+) ]] &&
     (( ${BASH_REMATCH[1]} >= 17 )); then
    echo "Checking PostgreSQL dump TOC with local $version..."
    verify_stream postgres.dump.age pg_restore --list >/dev/null
    pg_list_checked=true
  fi
fi
if ! "$pg_list_checked" && command -v docker >/dev/null 2>&1 &&
   timeout 5s docker info >/dev/null 2>&1 &&
   timeout 5s docker image inspect postgres:17 >/dev/null 2>&1; then
  echo "Checking PostgreSQL dump TOC with local postgres:17 Docker image..."
  verify_stream postgres.dump.age docker run --rm -i --pull=never \
    --network none postgres:17 pg_restore --list >/dev/null
  pg_list_checked=true
fi
if "$pg_list_checked"; then
  echo "PostgreSQL custom dump TOC: OK"
else
  echo "NOTE: No local PostgreSQL 17+ pg_restore or cached postgres:17 Docker image."
  echo "PGDMP signature and complete authenticated stream checked; PostgreSQL TOC"
  echo "and actual database restorability NOT verified. Run an isolated restore test."
fi

for name in airflow-state etl-data grafana-data; do
  echo "Validating encrypted compressed volume archive: $name..."
  verify_stream "$name.tar.gz.age" tar -tzf - >/dev/null
  echo "$name archive: OK"
done
echo "All encrypted archives passed decryption/integrity checks."

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
