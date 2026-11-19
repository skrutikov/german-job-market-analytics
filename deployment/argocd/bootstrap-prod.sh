#!/usr/bin/env bash
# One-time or repeatable production bootstrap; run as the Ubuntu VM user.
# Never replaces the VM or switches the working checkout away from main.
set -euo pipefail

if (( EUID == 0 )); then
    echo "Run as the normal Ubuntu VM user (without sudo)." >&2
    exit 1
fi
for executable in git tar sudo k3s; do
    command -v "$executable" >/dev/null || {
        echo "Missing $executable on this Ubuntu k3s VM." >&2
        exit 1
    }
done
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
if [[ ! -d "$repo_root/.git" ]]; then
    echo "Expected a cloned Git repository at $repo_root." >&2
    exit 1
fi
origin="$(git -C "$repo_root" remote get-url origin)"
case "$origin" in
    https://github.com/skrutikov/german-job-market-analytics.git|https://github.com/skrutikov/german-job-market-analytics|git@github.com:skrutikov/german-job-market-analytics.git) ;;
    *)
        echo "Unexpected Git origin: $origin" >&2
        exit 1
        ;;
esac

# Production branch exists only after the first approved promotion.
git -C "$repo_root" fetch --no-tags origin \
    production:refs/remotes/origin/production
sudo k3s kubectl -n argocd get deployment argocd-server >/dev/null || {
    echo "Bootstrap dev Argo CD first: sudo bash deployment/argocd/bootstrap.sh main" >&2
    exit 1
}
sudo k3s kubectl get namespace prod >/dev/null || {
    echo "Missing prod namespace. Run local ./deploy.sh (Ansible) first." >&2
    exit 1
}

# Deploy exactly the approved branch; never use the mutable main prod overlay.
temporary="$(mktemp -d)"
trap 'rm -rf -- "$temporary"' EXIT
git -C "$repo_root" archive --format=tar refs/remotes/origin/production |
    tar -xf - -C "$temporary"
test -f "$temporary/deployment/argocd/application-prod.yaml" || {
    echo "Production branch lacks the approved Argo CD Application." >&2
    exit 1
}
echo "Deploying approved production branch without touching dev..."
sudo bash "$temporary/deployment/kubernetes/deploy.sh" prod
echo "Registering production GitOps (PVCs protected before auto-pruning)..."
sudo bash "$temporary/deployment/argocd/configure-sync.sh" production prod
sudo k3s kubectl -n argocd get application job-market-prod
sudo k3s kubectl -n prod get pods
echo "Prod tracks the approved production Git branch; later promotions sync automatically."
