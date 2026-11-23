#!/usr/bin/env bash
# Install pinned Argo CD and register the existing dev deployment for GitOps.
# Run on the Proxmox VM, not the Proxmox host or local machine.
set -euo pipefail

revision="${1:-main}"
install_only=false
if [[ "$revision" == --install-only ]]; then
    install_only=true
elif [[ ! "$revision" =~ ^[a-zA-Z0-9][a-zA-Z0-9._/-]*$ ||
       "$revision" == *..* || "$revision" == production ]]; then
    echo "Usage: sudo ./deployment/argocd/bootstrap.sh [SAFE_DEV_GIT_BRANCH|--install-only]" >&2
    exit 2
fi
if (( EUID != 0 )); then
    echo "Run as root on the Proxmox VM (k3s kubectl requires cluster access)." >&2
    exit 1
fi
command -v k3s >/dev/null || { echo "k3s is required." >&2; exit 1; }

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
argo_version="v3.6.1"
install_url="https://raw.githubusercontent.com/argoproj/argo-cd/$argo_version/manifests/install.yaml"

# Dev bootstrap still requires an existing dev stack. A production-only VM
# installs Argo CD without coupling it to a development Application.
if [[ "$install_only" == false ]]; then
    k3s kubectl get namespace dev >/dev/null || {
        echo "The dev namespace is missing. Deploy the dev application first." >&2
        exit 1
    }
    k3s kubectl -n dev get deployment/backend deployment/grafana >/dev/null || {
        echo "The dev application stack is missing. Deploy it before enabling GitOps." >&2
        exit 1
    }
fi

echo "Installing/updating Argo CD $argo_version in namespace argocd..."
k3s kubectl create namespace argocd --dry-run=client -o yaml | k3s kubectl apply -f -
k3s kubectl apply --server-side --force-conflicts -n argocd -f "$install_url"
k3s kubectl wait --for=condition=Established --timeout=120s crd/applications.argoproj.io
k3s kubectl -n argocd rollout status deployment/argocd-server --timeout=600s
k3s kubectl -n argocd rollout status deployment/argocd-repo-server --timeout=600s
k3s kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=600s

if [[ "$install_only" == false ]]; then
    # Apply the safe PVC policy before enabling pruning for the dev Application.
    bash "$repo_root/deployment/argocd/configure-sync.sh" "$revision"
else
    echo "Argo CD installed; no Application registered (--install-only)."
fi
echo "Argo CD bootstrap complete."
