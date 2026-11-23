# Kubernetes application deployment

Kustomize deploys Job Market Analytics to the single-node k3s cluster provisioned by [Terraform and Ansible](../README.md). The Docker Compose deployment is unchanged. For GitOps synchronization, see the [Argo CD guide](../argocd/README.md). For Prometheus container monitoring and k6 load tests, see the [performance guide](../performance/README.md). For repository and container vulnerability scanning in CI, see the [Trivy security guide](../security/README.md).

## Components

| Service | Kubernetes deployment |
|---|---|
| PostgreSQL | Deployment + Service + persistent volume claim |
| Elasticsearch | Deployment + Service + persistent volume claim |
| FastAPI backend | Deployment + Service |
| Dash frontend | Deployment + Service |
| Nginx gateway | Deployment + Service + Traefik Ingress |
| Airflow | Deployment + Service + persistent volume claim |
| Data update | Suspended CronJob for on-demand ETL |
| Prometheus | Deployment + Service + persistent volume claim |
| Pushgateway | Deployment + Service |
| Alertmanager | Deployment + Service |
| Grafana | Deployment + Service + persistent volume claim |
| kube-state-metrics | Deployment + Service; namespace-scoped Pod restart/health metrics |

The overlays in `deployment/kubernetes/overlays/dev` and `deployment/kubernetes/overlays/prod` isolate the environments into their respective namespaces. Each environment uses its own Services, PVCs and credentials.

### Environment-specific configuration

The base Kustomize `job-market-settings` ConfigMap contains shared values,
such as private service URLs, `FRONTEND_PORT=8050`, and `DASH_DEBUG=false`.
Each environment overlay **merges** its own `DEPLOYMENT_ENV` value into
that ConfigMap without duplicating or modifying the common settings:

| Setting | Dev | Prod |
|---|---|---|
| `DEPLOYMENT_ENV` | `development` | `production` |
| Namespace | `dev` | `prod` |
| Ingress host | `job-market-dev.test` | `job-market.test` |
| Application/Airflow image tags | Automatic tested SHA | Approved promotion SHA |
| PostgreSQL/Grafana credentials and PVCs | Separate | Separate |

`DEPLOYMENT_ENV` is a **configuration marker** available to the backend,
frontend and Airflow containers through their existing `envFrom` references.
It currently does not change application behavior. We intentionally leave
`DASH_DEBUG=false` in both environments; enabling development debug mode
could expose debugging information and is not needed to show separation.

Argo CD tracks `main` for dev but the separate, approved `production`
branch for prod. Merging a change to `main` updates **dev only** until
the next approved production promotion. Don't manually apply the prod
overlay from `main`, because that would bypass the release process.

To inspect the applied configuration on the **Ubuntu VM** after deployment,
without reading any secrets:

```bash
sudo k3s kubectl -n dev exec deployment/backend -- printenv DEPLOYMENT_ENV
sudo k3s kubectl -n prod exec deployment/backend -- printenv DEPLOYMENT_ENV
```

Expected values after **both** revisions have deployed: `development`
and `production`. The production value will only appear after an approved
promotion, because production intentionally stays on its own Git branch.

**Security and scope:** The current Airflow configuration uses `airflow standalone` (SQLite metadata database), intended for development and demonstration, not production-grade Airflow. Elasticsearch's security is disabled for its private cluster Service, as in Docker Compose. The example Ingress is plain HTTP. Do **not** expose this setup to the public internet without authentication, TLS and network restrictions. Single-node k3s and local-path storage are not highly available.

## 1. CI images, automatic dev deployment and production promotion

[GitHub Actions](../../.github/workflows/kubernetes.yml) validates both
Kustomize overlays, scans source and containers with Trivy, and builds/publishes
both application and Airflow images to GHCR.

Each successful `main` publication creates an **immutable**
`sha-<full-main-commit>` tag for both images. The
`update_dev_gitops` job automatically updates the dev overlay in `main`;
Argo CD watches `main` and deploys the new dev version. Production
**never tracks `main` directly**: after manual and (when configured) reviewer
approval, the [promotion workflow](../../.github/workflows/promote-production.yml)
updates a separate `production` branch that prod Argo CD watches.

Both environments use the same two image repositories, but **can run
different immutable image versions**:

- Application: `ghcr.io/skrutikov/german-job-market-analytics:sha-<commit>`
- Airflow: `ghcr.io/skrutikov/german-job-market-analytics-airflow:sha-<commit>`

For step-by-step reviewer setup, dev verification, first production bootstrap,
and recovery instructions, see the [dev-to-prod promotion runbook](../../docs/dev-to-prod-promotion.md).

GitHub Actions does **not** SSH into the private Proxmox VM. GHCR packages must
be accessible to k3s (public or authenticated via a namespace imagePullSecret).
Do not commit credentials. Wait for `publish` and `update_dev_gitops` to
complete before verifying or promoting a release.

## 2. Prepare the Proxmox VM

### Quick start: `deployment/scripts/setup_vm.sh` (recommended for a fresh VM)

After `./deploy.sh` on the **local machine** has provisioned the VM and
installed k3s with Ansible, SSH into the **Ubuntu VM as the regular user**
(not the Proxmox host and not root). Since the repository does not exist on a
fresh VM yet, download just the bootstrap script from `main`:

```bash
sudo apt-get update
sudo apt-get install -y curl
curl -fsSLo /tmp/job-market-setup-vm.sh \
  https://raw.githubusercontent.com/skrutikov/german-job-market-analytics/refactoring/deployment/scripts/setup_vm.sh
bash /tmp/job-market-setup-vm.sh
```

Inspect the downloaded script before executing it if desired. It checks k3s,
installs `git` and `openssl`, clones or fast-forward-updates the `main`
checkout at `~/german-job-market-analytics`, persists Elasticsearch's
`vm.max_map_count`, runs `deployment/kubernetes/deploy.sh dev`, bootstraps Argo CD
tracking `main`, and displays node/Pod/Application status. It does
**not** modify the Proxmox VM or reinstall k3s.

The script is safe to rerun on the same Git branch: it will not delete the
repository or overwrite tracked local edits, and existing Kubernetes Secrets
and PVCs are retained. Re-running the deployment may still reconcile/restart
workloads as needed. It rejects an unrelated Git origin or existing
non-repository directory. A separate `deployment/scripts/init_airflow.sh` command starts the
first ETL; it is **not** triggered automatically by VM setup.

For a new lab environment, once this completes, skip directly to
[Section 4 (local access)](#4-access-from-the-local-machine-one-background-ssh-tunnel)
and [Section 5 (ETL)](#5-run-etl).

### Manual equivalent (for troubleshooting)

Run these commands **on the Proxmox VM**, reached through the restricted SSH
jump account on the Proxmox host:

```bash
sudo k3s kubectl get nodes
sudo k3s kubectl get storageclass
df -h /
sudo apt-get update
sudo apt-get install -y git openssl
git clone https://github.com/skrutikov/german-job-market-analytics.git
cd german-job-market-analytics
```

If this repository is already cloned on the Proxmox VM, switch to the intended branch and pull instead.

Elasticsearch on Linux may require the following kernel setting **on the Proxmox VM, not the Proxmox host**:

```bash
sudo sysctl -w vm.max_map_count=262144
echo 'vm.max_map_count=262144' | sudo tee /etc/sysctl.d/99-elasticsearch.conf
```

k3s normally includes the `local-path` default StorageClass. PVCs are stored on the VM filesystem, so monitor its free space and back up stateful workloads.

## 3. Deploy to dev

Inside the repository on the VM:

```bash
sudo bash deployment/kubernetes/deploy.sh dev
```

The script generates a namespace-scoped `job-market-secrets` Secret once, containing random PostgreSQL and Grafana credentials (with the database connection URL). It applies the dev overlay and waits for the ten Deployments.

Equivalent manual steps:

```bash
sudo bash deployment/kubernetes/bootstrap-secrets.sh dev
sudo k3s kubectl apply -k deployment/kubernetes/overlays/dev
sudo k3s kubectl -n dev get deployments,pods,services,pvc,ingress
```

**Back up the generated Secret securely.** Keeping a database PVC but losing its password can make restoration difficult. An existing Secret is not regenerated on repeat runs.

For troubleshooting:

```bash
sudo k3s kubectl -n dev get pods -o wide
sudo k3s kubectl -n dev describe pod POD_NAME
sudo k3s kubectl -n dev logs deployment/airflow
sudo k3s kubectl -n dev get events --sort-by=.lastTimestamp
```

## 4. Access from the local machine (one background SSH tunnel)

The cluster runs on a Proxmox VM with a private IP address. Run the root-level **`deployment/scripts/kubernetes_start.sh`** utility from the **local machine**, using a Bash-compatible shell—not from the Proxmox VM or the Proxmox host. Configure the `k3s-vm` SSH alias as shown in [the infrastructure SSH instructions](../README.md#4-optional-ssh-alias-for-interactive-vm-access), so SSH reaches the Proxmox VM through the Proxmox host's restricted jump account. The local machine needs OpenSSH, Python 3, and curl.

```bash
cd ~/german-job-market-analytics
git fetch origin
git switch main
git pull

./kubernetes_start.sh dev
```

The script discovers the Kubernetes Service ClusterIPs through SSH, establishes **one detached SSH tunnel** with several localhost-only port forwards, verifies the Nginx endpoint, and prints URLs and the current Grafana, Airflow and PostgreSQL credentials. The script **does not deploy, restart, or expose any pods publicly**; the cluster must already have been deployed by `deployment/kubernetes/deploy.sh` on the Proxmox VM.

| Service | Local URL for dev |
|---|---|
| Dash | `http://127.0.0.1:8088/` |
| FastAPI Swagger | `http://127.0.0.1:8088/api/docs` |
| Airflow | `http://127.0.0.1:18080/` |
| Grafana | `http://127.0.0.1:13000/` |
| Prometheus | `http://127.0.0.1:19090/` |
| Alertmanager | `http://127.0.0.1:19093/` |
| Elasticsearch | `http://127.0.0.1:19200/` |
| Pushgateway | `http://127.0.0.1:19091/` |

The script retrieves credentials from the running cluster via `sudo -n k3s kubectl`. This requires the VM user to have **passwordless sudo for kubectl**, as configured by Cloud-Init in our deployment. Airflow's default Simple Auth Manager stores its generated password in its Airflow state PVC; Grafana and PostgreSQL passwords are in the namespace-scoped `job-market-secrets` Secret.

**Keep the terminal output private:** the generated passwords appear on screen but are not written to a local file. Do not paste or capture that output in logs. The script never prints the database URL containing the password.

Tunnel management from the local machine:

```bash
./kubernetes_start.sh dev          # Start, or reuse an existing tunnel, and show URLs/passwords
./kubernetes_start.sh dev status   # Check tunnel status
./kubernetes_stop.sh dev           # Stop just this tunnel
```

The background SSH process remains alive when the starting terminal closes, **as long as the local SSH environment remains running**. After restarting the local machine or its shell environment, run the start command again. If you previously opened `ssh -N -L ...` manually using the same local ports, stop it with Ctrl+C first. You can also stop old `kubectl port-forward` commands on the Proxmox VM; the new script does not use them.

This approach forwards through the Proxmox VM directly to its Kubernetes ClusterIP Services, avoiding long-running `kubectl port-forward` terminals. It depends on Service IPs being reachable from the k3s node, which is supported by this cluster's networking setup. If networking changes, stop and restart the tunnel to discover the current Service IPs. All locally exposed ports are explicitly bound to `127.0.0.1`.

You can override the SSH destination (default `k3s-vm`) using `JOB_MARKET_VM_SSH_HOST=your-ssh-alias ./kubernetes_start.sh dev`.

The `prod` overlay, if deployed, can be accessed separately using `./kubernetes_start.sh prod`; it uses different local ports to avoid collisions. Do not deploy both full environments on this VM unless its capacity permits it.

### Manual fallback

If the single SSH tunnel cannot reach the ClusterIP Services, the older two-hop method remains available. On the **Proxmox VM**:

```bash
sudo k3s kubectl -n dev port-forward svc/nginx 8088:80
```

Then from a separate terminal on the **local machine**:

```bash
ssh -N -L 8088:127.0.0.1:8088 k3s-vm
```

The manual forwarding processes must remain running. This fallback is separate from `deployment/scripts/kubernetes_start.sh`.

The optional Traefik Ingress hosts (`job-market-dev.test` and `job-market.test`) are example names, not public DNS records; they require suitable routing and DNS. After installing Argo CD, the local access script also provides its HTTPS UI; see the [Argo CD access guide](../argocd/README.md#access-from-the-local-machine).

## 5. Run ETL

### Quick start: `deployment/scripts/init_airflow.sh`

On the **Ubuntu VM**, after `deployment/scripts/setup_vm.sh` or manual deployment has succeeded:

```bash
cd ~/german-job-market-analytics
bash deployment/scripts/init_airflow.sh
```

The script checks the Airflow deployment and DAG, enables scheduling if
the DAG was paused, and **checks for any queued/running ETL run before
triggering another**. If a run is already queued or running, it skips the
manual trigger. If the DAG was initially paused, it unpauses scheduling but
does **not** also create a manual run: the scheduler may immediately create
a scheduled run itself. This avoids the double initialization we saw in prod.

If the DAG was already unpaused and has no active runs, `deployment/scripts/init_airflow.sh`
triggers one manual run. The script checks the complete DAG-run state list
using Airflow 3.4's structured JSON output (rather than only the five most
recent rows). If a status command or JSON parsing fails, it **refuses to
trigger**. This is a best-effort safeguard, not an atomic lock against a
second operator triggering a run at exactly the same moment.

For a **read-only status check** that never triggers another ETL:

```bash
bash deployment/scripts/check_airflow_state.sh dev
bash deployment/scripts/check_airflow_state.sh prod
```

The status script prints the five latest DAG runs for the selected namespace;
the default is `dev`. These are equivalent to:

```bash
sudo k3s kubectl -n prod exec deployment/airflow -- \
  airflow dags list-runs job_market_etl --limit 5
```

Don't rerun `deployment/scripts/init_airflow.sh` just to check progress. After the active run
finishes, a subsequent invocation can trigger another ETL. These scripts
don't detect independently launched `data-update` Kubernetes Jobs.

Airflow's DAG schedules the daily ETL at **06:00**, writing to PostgreSQL and Elasticsearch and publishing ETL metrics to Pushgateway. Airflow's `/opt/airflow/data` and the manual ETL runner's `/app/data` share a PVC.

The Kubernetes `data-update` CronJob is intentionally **suspended** to avoid triggering the ETL twice each day. Start an initial import or manual refresh with:

```bash
sudo k3s kubectl -n dev create job \
  --from=cronjob/data-update "data-update-$(date +%s)"
sudo k3s kubectl -n dev get jobs
sudo k3s kubectl -n dev logs job/JOB_NAME --follow
```

Replace `JOB_NAME` with the created Job name. Avoid overlapping manual updates with an Airflow ETL run, since both modify the same database and search index. The scheduled DAG can be managed from Airflow's UI.

## 6. Production deployment and resource limits

The production overlay is pinned to the **approved** immutable image tag
on the separate `production` Git branch. It should not be deployed directly
from `main`: that bypasses the approved production configuration.

After the first production promotion completes in GitHub Actions, on the
**Ubuntu VM** (normal account, repository on `main`):

```bash
cd ~/german-job-market-analytics
git switch main
git pull --ff-only
bash deployment/argocd/bootstrap-prod.sh
```

The bootstrap creates isolated prod Secrets, PVCs and Deployments, then
registers the prod Argo CD Application. Later approved promotions automatically
sync through Argo CD. See the [promotion guide](../../docs/dev-to-prod-promotion.md).

A VM with **4 vCPUs, 16 GiB RAM and a 30 GiB disk** may support both stacks
when idle, but Airflow/Elasticsearch and image layers can consume substantial
resources. Monitor `df -h /`, `sudo k3s kubectl top nodes`, and Pod memory,
and do not overlap both ETL pipelines until proven safe.

To inspect rendered configurations:

```bash
sudo k3s kubectl kustomize deployment/kubernetes/overlays/dev
sudo k3s kubectl kustomize deployment/kubernetes/overlays/prod
```

Keep backups of PostgreSQL, Airflow state, ETL files and credentials:
local-path PVCs are **not** a disaster-recovery solution.

## Disaster recovery

See [the disaster-recovery runbook](../../docs/disaster-recovery.md) for encrypted off-VM PostgreSQL and important PVC/Secret backups, ordered restoration to a new k3s VM, and immutable image rollback. The cluster's local-path PVCs are **not** backups.
