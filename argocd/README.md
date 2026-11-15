# Argo CD GitOps deployment

Argo CD reconciles the existing `dev` Kubernetes application from `kubernetes/overlays/dev`. It runs in its own `argocd` namespace. This project uses the pinned official non-HA Argo CD **v3.6.1** installer, appropriate for a small single-node demonstration cluster. Neither the `prod` application nor the Proxmox infrastructure is managed by Argo CD.

## Bootstrap on the Proxmox VM

First deploy and verify the application using [the Kubernetes guide](../kubernetes/README.md). Connect to the **Proxmox VM** through the SSH jump account on the **Proxmox host**. Then, on the VM:

```bash
cd ~/german-job-market-analytics
git fetch origin
git switch gitops
git pull
sudo bash argocd/bootstrap.sh gitops
```

This installs Argo CD in the `argocd` namespace, waits for the server, repository server and application controller to be ready, and creates the `job-market-dev` Application tracking the `gitops` branch. The script is repeatable; it uses the pinned upstream installation manifest and requires cluster-admin privileges, GitHub access and sufficient VM resources. It does **not** run the `prod` overlay, recreate the `dev` stack or regenerate application passwords.

The Application automatically synchronizes and self-heals tracked resources, but **automatic pruning is disabled**. Removing a manifest from Git does not automatically delete a Kubernetes resource. Existing PostgreSQL, Elasticsearch, Grafana and Airflow PVCs remain in place. The `job-market-secrets` Secret is created outside GitOps and is not committed to this repository. Back up stateful data before experimenting.

## Access from the local machine

After installation, update the repository on the **local machine** to this feature branch, then restart the existing SSH tunnel so it discovers the new `argocd-server` Service:

```bash
git fetch origin
git switch gitops
git pull
./kubernetes_stop.sh dev
./kubernetes_start.sh dev
```

The script includes **Argo CD: https://127.0.0.1:18443/** (self-signed TLS certificate) and prints the **initial** admin password if the `argocd-initial-admin-secret` still exists. Alternatively retrieve it from the **Proxmox VM**:

```bash
sudo k3s kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' | base64 -d
echo
```

Log in with username `admin`, change the default-generated password, and delete the initial-password Secret after rotating it (on the Proxmox VM: `sudo k3s kubectl -n argocd delete secret argocd-initial-admin-secret`). The access script cannot display your changed password. Keep Argo CD accessible only through your private SSH tunnel, not a public Ingress.

## Verify and test GitOps

On the Proxmox VM:

```bash
sudo k3s kubectl -n argocd get applications
sudo k3s kubectl -n argocd describe application job-market-dev
sudo k3s kubectl -n dev get pods
```

In the Argo CD web UI, inspect the `job-market-dev` resource tree and its **Sync** and **Health** status. Argo CD adopts the existing Kubernetes resources; its first sync may update resource metadata or trigger rollout. No separate deployment is created.

To test reconciliation, commit a small, safe, non-secret change under `kubernetes/overlays/dev` on the `gitops` branch. Argo CD periodically detects and applies the desired manifests. Do not manually run `kubectl apply -k` on those resources once Argo CD is managing them.

**Container images are a separate step.** GitHub Actions publishes `:dev` images for the `gitops` branch, but Argo CD does not detect when a mutable image tag is simply republished. For a new image release, update an overlay's `newTag` to the already-published immutable `sha-<commit>` tag and push that manifest change. We can automate that image-tag update later.

## After merging to main

The checked-in `argocd/application-dev.yaml` defaults to tracking `main`; the bootstrap command selects the temporary `gitops` branch for testing. After squash-merging `gitops` into `main`, update the VM checkout and switch the existing Application to `main`:

```bash
cd ~/german-job-market-analytics
git fetch origin
git switch main
git pull
sudo bash argocd/bootstrap.sh main
```

The command reuses the existing Application and namespace; it does not enable pruning. Afterward, changes committed to `main` under `kubernetes/overlays/dev` are synchronized into the existing `dev` namespace.

## Scope and security

- The standard Argo CD installer grants substantial cluster privileges. Restrict Git branch write access, Kubernetes administrators and SSH access.
- The one-node non-HA setup is not high availability. Watch VM CPU, RAM and disk usage.
- Application secrets, VM provisioning, database migrations and image-build automation are not managed by Argo CD.
- Do not enable automated pruning or deploy a second complete `prod` stack without considering resource limits and persistent-data backups.
