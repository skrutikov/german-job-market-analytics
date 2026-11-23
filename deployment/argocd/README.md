# Argo CD GitOps deployment

Argo CD normally reconciles `dev` from `main` and, **after explicit release approval and a one-time bootstrap**, `prod` from the independent `production` Git branch. Both Applications live in the `argocd` namespace. This project uses the pinned non-HA Argo CD **v3.6.1** installer, appropriate for a small single-node demonstration cluster. Proxmox infrastructure remains managed by Terraform and Ansible. See the [promotion guide](../../docs/dev-to-prod-promotion.md).

## Bootstrap on the Proxmox VM

During feature-branch deployment, the dev Application tracks the branch
selected by `JOB_MARKET_REF` (for example, `maximize-automation`) instead
of `main`. This is necessary while the refactored Kubernetes paths are not
present on `main`. Production still tracks the separately approved
`production` branch.

For a **fresh Ubuntu VM**, the [`deployment/scripts/setup_vm.sh` bootstrap](../kubernetes/README.md#quick-start-setup_vmsh-recommended-for-a-fresh-vm)
does the application deployment and Argo CD bootstrap in one command.
The following commands remain the manual alternative.

First deploy and verify the application using [the Kubernetes guide](../kubernetes/README.md). Connect to the **Proxmox VM** through the SSH jump account on the **Proxmox host**. On the VM:

```bash
cd ~/german-job-market-analytics
git switch main
git pull
sudo ./argocd/bootstrap.sh main
```

This installs Argo CD into the `argocd` namespace, waits for its components to be ready, and registers the existing `job-market-dev` Application. It requires cluster-admin privileges, access to GitHub and sufficient VM resources. It does **not** create `prod`, reinstall the `dev` application or regenerate its passwords.

### Approved production bootstrap

Production **must not** be deployed from the `main` overlay, because
production tracks the separately approved `production` Git branch.
After a successful [production promotion](../../docs/dev-to-prod-promotion.md)
creates that branch, on the **Ubuntu VM** as the normal account:

```bash
cd ~/german-job-market-analytics
git switch main
git pull --ff-only
bash deployment/argocd/bootstrap-prod.sh
```

This fetches the approved branch into a temporary checkout, runs
`deployment/kubernetes/deploy.sh prod`, applies PVC protection, and creates
`job-market-prod`. It does not change `job-market-dev`.
Subsequent approved promotions are automatically synchronized to prod by
Argo CD. Configure GitHub's `production` environment required reviewers
and protect the `production` Git branch **before** relying on the gate.

### Automatic pruning with persistent-storage protection

The Application automatically synchronizes Git changes and self-heals drift. It also **prunes obsolete resources**, so replaced Kustomize ConfigMaps are cleaned up without manual Kubernetes commands. Pruning happens after the other resources have been deployed and become healthy (`PruneLast=true`). `allowEmpty: false` prevents an accidentally empty Git source from causing wholesale automatic deletion. [Argo CD automatic sync documentation](https://argo-cd.readthedocs.io/en/stable/user-guide/auto_sync/)

Six persistent volume claims—PostgreSQL, Elasticsearch, ETL data, Airflow state, Prometheus and Grafana—carry this resource annotation:

```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-options: Prune=confirm,Delete=false
```

- `Prune=confirm`: removing a PVC from Git requires explicit approval in Argo CD before that PVC is pruned
- `Delete=false`: deleting the Argo CD Application itself does **not** remove these PVCs

An unapproved, intentionally removed PVC may leave the Application OutOfSync until pruning is approved. Neither annotation protects against direct manual `kubectl delete pvc` by a privileged operator. **Keep backups**: local-path volumes and their application data are not replicated.

### Existing installation: one-time configuration update

If Argo CD is **already installed** (as in our deployment), you do not need to reinstall it. Once the protected manifests have been merged to `main`, update the checkout **on the Proxmox VM** and run:

```bash
cd ~/german-job-market-analytics
git switch main
git pull
sudo ./argocd/configure-sync.sh main
```

This single configuration command checks that all six PVCs exist, adds the protection annotation to each live PVC (metadata only), verifies it, and **only then** enables automatic pruning and reconciliation from `main`. It is idempotent. It does not touch the database contents or restart the workloads.

The `job-market-secrets` Secret is managed outside GitOps and is not stored in this repository.

## Access from the local machine

After installation, update the repository on the **local machine**, then restart the existing SSH tunnel so it discovers the new `argocd-server` Service:

```bash
git fetch origin
git switch main
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

To test reconciliation, commit a small, safe, non-secret change under `deployment/kubernetes/overlays/dev` on the branch that the Application tracks. Argo CD periodically detects and applies the desired manifests. Do not manually run `kubectl apply -k` on those resources once Argo CD is managing them.

**Image releases are now GitOps-driven.** After GitHub Actions successfully
builds, scans, and publishes both immutable `sha-<commit>` images, its
`update_dev_gitops` job updates only the dev overlay on `main`. Argo CD
then auto-deploys dev. A separate, manually approved GitHub workflow updates
only the `production` Git branch, triggering production Argo CD. See the
[promotion runbook](../../docs/dev-to-prod-promotion.md).

## Returning to main after feature-branch testing

If the Application temporarily tracks a feature branch, update the **Proxmox VM** checkout after merging and restore the normal revision:

```bash
git switch main
git pull
sudo ./argocd/configure-sync.sh main
```

The update checks PVC protections again and restores the current GitOps sync policy. No restart of Argo CD is necessary.

## Scope and security

- The standard Argo CD installer grants substantial cluster privileges. Restrict Git branch write access, Kubernetes administrators and SSH access.
- The one-node non-HA setup is not high availability. Watch VM CPU, RAM and disk usage.
- Application secrets, VM provisioning, database migrations and image-build automation are not managed by Argo CD.
- Automatic pruning is enabled for ordinary resources; all PVCs require confirmation for pruning and are retained if the Application is deleted. Do not deploy a second complete `prod` stack without considering resource limits and persistent-data backups.
- `job-market-prod` is not bootstrapped by the ordinary dev setup. It tracks only approved changes on the `production` branch; GitHub branch protection and required environment reviewers must be configured separately.
