#!/usr/bin/env bash
set -euo pipefail

environment="${1:-}"
if [[ "$environment" != "dev" && "$environment" != "prod" ]]; then
    echo "Usage: sudo bash kubernetes/deploy.sh dev|prod" >&2
    exit 2
fi
if (( EUID != 0 )); then
    echo "Run as root so k3s kubectl can access the cluster." >&2
    exit 1
fi

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
bash "$repo_root/kubernetes/bootstrap-secrets.sh" "$environment"
k3s kubectl apply -k "$repo_root/kubernetes/overlays/$environment"

for name in postgres elasticsearch backend frontend nginx \
            prometheus pushgateway alertmanager grafana airflow; do
    if ! k3s kubectl -n "$environment" rollout status "deployment/$name" --timeout=600s; then
        echo "Deployment/$name is not ready. Review pods and events:" >&2
        k3s kubectl -n "$environment" get pods -o wide >&2
        k3s kubectl -n "$environment" get events --sort-by=.lastTimestamp >&2
        exit 1
    fi
done

echo "Deployment complete in namespace $environment."
k3s kubectl -n "$environment" get pods
k3s kubectl -n "$environment" get ingress
