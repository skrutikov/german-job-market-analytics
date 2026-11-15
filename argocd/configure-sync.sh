#!/usr/bin/env bash
# Configure Argo CD auto-pruning with protection for persistent storage.
# Run on the Proxmox VM.
set -euo pipefail

revision="${1:-main}"
if [[ "$revision" != "main" && "$revision" != "gitops-pruning" ]]; then
    echo "Usage: sudo ./argocd/configure-sync.sh [main|gitops-pruning]" >&2
    exit 2
fi
if (( EUID != 0 )); then
    echo "Run as root on the Proxmox VM." >&2
    exit 1
fi
command -v k3s >/dev/null || { echo "k3s is required." >&2; exit 1; }
command -v sed >/dev/null || { echo "sed is required." >&2; exit 1; }

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
application="$repo_root/argocd/application-dev.yaml"
protection="Prune=confirm,Delete=false"
pvcs=(
    postgres-data
    elasticsearch-data
    airflow-state
    etl-data
    prometheus-data
    grafana-data
)

# Do not enable auto-pruning on an incomplete or damaged installation.
for name in "${pvcs[@]}"; do
    k3s kubectl -n dev get pvc "$name" >/dev/null || {
        echo "Cannot enable pruning: dev/$name is missing." >&2
        exit 1
    }
done

# Apply live PVC metadata BEFORE updating the Application's prune policy.
# Also protects clusters initially deployed with the previous manifests.
echo "Protecting all ${#pvcs[@]} persistent volume claims..."
for name in "${pvcs[@]}"; do
    k3s kubectl -n dev annotate --overwrite "pvc/$name" \
        "argocd.argoproj.io/sync-options=$protection" >/dev/null
done

for name in "${pvcs[@]}"; do
    actual="$(k3s kubectl -n dev get pvc "$name" \
        -o 'jsonpath={.metadata.annotations.argocd\.argoproj\.io/sync-options}')"
    if [[ "$actual" != "$protection" ]]; then
        echo "PVC protection verification failed for dev/$name." >&2
        exit 1
    fi
done

echo "Configuring job-market-dev with auto-pruning, tracking '$revision'..."
sed "s/targetRevision: main/targetRevision: $revision/" "$application" |
    k3s kubectl -n argocd apply -f -

k3s kubectl -n argocd get application job-market-dev
echo "Auto-prune is enabled. Routine ConfigMaps clean up automatically."
echo "All PVCs require confirmation for pruning and survive Application deletion."
