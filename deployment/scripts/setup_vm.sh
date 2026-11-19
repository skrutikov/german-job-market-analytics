#!/usr/bin/env bash
# Bootstrap Job Market Analytics inside an existing Ubuntu k3s VM.
# Run as the Ubuntu user, not on the Proxmox host or local workstation.
set -euo pipefail

if (( EUID == 0 )); then
    echo "Run as the Ubuntu VM user (without sudo). This script invokes sudo where needed." >&2
    exit 1
fi
command -v sudo >/dev/null || { echo "sudo is required." >&2; exit 1; }
command -v k3s >/dev/null || {
    echo "k3s is missing. First create the VM with ./deployment/scripts/deploy.sh on the local machine." >&2
    exit 1
}

repo_url="https://github.com/skrutikov/german-job-market-analytics.git"
repo_dir="${JOB_MARKET_REPO_DIR:-$HOME/german-job-market-analytics}"
repo_ref="${JOB_MARKET_REF:-main}"

# Fail early if this is not the k3s VM or sudo cannot access the cluster.
sudo k3s kubectl get nodes
sudo k3s kubectl get storageclass
df -h /

echo "Installing guest prerequisites..."
sudo apt-get update
sudo apt-get install -y git openssl

if [[ -e "$repo_dir" ]]; then
    if [[ ! -d "$repo_dir/.git" ]]; then
        echo "Refusing to replace an existing non-Git directory: $repo_dir" >&2
        exit 1
    fi

    origin="$(git -C "$repo_dir" remote get-url origin)"
    case "$origin" in
        "$repo_url"|"https://github.com/skrutikov/german-job-market-analytics"|"git@github.com:skrutikov/german-job-market-analytics.git") ;;
        *)
            echo "Unexpected Git origin: $origin. Refusing to update $repo_dir." >&2
            exit 1
            ;;
    esac

    current_ref="$(git -C "$repo_dir" branch --show-current)"
    if [[ "$current_ref" != "$repo_ref" ]]; then
        echo "Repository is on '$current_ref', expected '$repo_ref'. Switch branches deliberately." >&2
        exit 1
    fi
    if ! git -C "$repo_dir" diff --quiet || ! git -C "$repo_dir" diff --cached --quiet; then
        echo "Repository has local tracked changes; refusing to pull over them." >&2
        exit 1
    fi
    echo "Updating existing $repo_ref checkout (fast-forward only)..."
    git -C "$repo_dir" pull --ff-only origin "$repo_ref"
else
    echo "Cloning $repo_ref into $repo_dir..."
    git clone --branch "$repo_ref" --single-branch "$repo_url" "$repo_dir"
fi

echo "Configuring Elasticsearch vm.max_map_count..."
sudo sysctl -w vm.max_map_count=262144
printf 'vm.max_map_count=262144\n' |
    sudo tee /etc/sysctl.d/99-elasticsearch.conf >/dev/null

echo "Deploying the dev Kubernetes application..."
sudo bash "$repo_dir/deployment/kubernetes/deploy.sh" dev

echo "Installing and configuring Argo CD..."
sudo bash "$repo_dir/deployment/argocd/bootstrap.sh" "$repo_ref"

echo "Checking the final cluster state..."
sudo k3s kubectl get nodes
sudo k3s kubectl -n dev get pods
sudo k3s kubectl -n argocd get application job-market-dev

echo "VM application setup complete."
echo "To start the first ETL run, execute: bash $repo_dir/deployment/scripts/init_airflow.sh"
