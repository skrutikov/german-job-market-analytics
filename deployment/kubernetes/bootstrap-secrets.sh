#!/usr/bin/env bash
set -euo pipefail

# Run on the k3s node as root. Credentials are generated locally and loaded
# into a namespace-scoped Secret; they are never written to the repository.
namespace="${1:-}"
if [[ "$namespace" != "dev" && "$namespace" != "prod" ]]; then
    echo "Usage: sudo bash kubernetes/bootstrap-secrets.sh dev|prod" >&2
    exit 2
fi

command -v openssl >/dev/null || { echo "openssl is required" >&2; exit 1; }
command -v k3s >/dev/null || { echo "k3s is required" >&2; exit 1; }

k3s kubectl get namespace "$namespace" >/dev/null

if k3s kubectl -n "$namespace" get secret job-market-secrets >/dev/null 2>&1; then
    echo "Secret job-market-secrets already exists in $namespace; leaving it unchanged."
    exit 0
fi

umask 077
secret_file="$(mktemp)"
trap 'rm -f "$secret_file"' EXIT
db_password="$(openssl rand -hex 24)"
grafana_password="$(openssl rand -hex 24)"
{
    printf 'POSTGRES_PASSWORD=%s\n' "$db_password"
    printf 'DATABASE_URL=postgresql+psycopg://job_market:%s@postgres:5432/job_market\n' "$db_password"
    printf 'GRAFANA_ADMIN_PASSWORD=%s\n' "$grafana_password"
} > "$secret_file"

k3s kubectl -n "$namespace" create secret generic job-market-secrets \
    --from-env-file="$secret_file"
unset db_password grafana_password
echo "Created namespace-scoped credentials for $namespace. Back up this Secret securely."
