# Kubernetes application deployment

Kustomize deploys Job Market Analytics to the single-node k3s cluster provisioned by [Terraform and Ansible](../infrastructure/README.md). The Docker Compose deployment is unchanged.

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

The overlays in `kubernetes/overlays/dev` and `kubernetes/overlays/prod` isolate the environments into their respective namespaces. Each environment uses its own Services, PVCs and credentials.

**Security and scope:** The current Airflow configuration uses `airflow standalone` (SQLite metadata database), intended for development and demonstration, not production-grade Airflow. Elasticsearch's security is disabled for its private cluster Service, as in Docker Compose. The example Ingress is plain HTTP. Do **not** expose this setup to the public internet without authentication, TLS and network restrictions. Single-node k3s and local-path storage are not highly available.

## 1. Publish container images

[GitHub Actions](../.github/workflows/kubernetes.yml) validates both Kustomize overlays and builds/pushes the application and Airflow Docker images to GitHub Container Registry (GHCR):

| Branch | Application image | Airflow image |
|---|---|---|
| `kubernetes-deployment` | `ghcr.io/skrutikov/german-job-market-analytics:dev` | `ghcr.io/skrutikov/german-job-market-analytics-airflow:dev` |
| `main` | `ghcr.io/skrutikov/german-job-market-analytics:main` | `ghcr.io/skrutikov/german-job-market-analytics-airflow:main` |

Wait for the **publish** workflow to finish before deploying. GitHub may initially make new packages private. Either change their visibility to public or configure an authorized GHCR `imagePullSecret` in the target namespace before applying resources. For private packages, a token with `read:packages` is required. Credentials must never be committed to the repository.

GitHub Actions does **not** deploy automatically to the private Proxmox VM.

## 2. Prepare the Ubuntu VM

Run these commands **inside VM 100**, reached through the existing SSH jump host:

```bash
sudo k3s kubectl get nodes
sudo k3s kubectl get storageclass
df -h /
sudo apt-get update
sudo apt-get install -y git openssl
git clone --branch kubernetes-deployment https://github.com/skrutikov/german-job-market-analytics.git
cd german-job-market-analytics
```

If this repository is already cloned on the VM, switch to `kubernetes-deployment` and pull instead.

Elasticsearch on Linux may require the following kernel setting **on the Ubuntu VM, not the Proxmox host**:

```bash
sudo sysctl -w vm.max_map_count=262144
echo 'vm.max_map_count=262144' | sudo tee /etc/sysctl.d/99-elasticsearch.conf
```

k3s normally includes the `local-path` default StorageClass. PVCs are stored on the VM filesystem, so monitor its free space and back up stateful workloads.

## 3. Deploy to dev

Inside the repository on the VM:

```bash
sudo bash kubernetes/deploy.sh dev
```

The script generates a namespace-scoped `job-market-secrets` Secret once, containing random PostgreSQL and Grafana credentials (with the database connection URL). It applies the dev overlay and waits for the ten Deployments.

Equivalent manual steps:

```bash
sudo bash kubernetes/bootstrap-secrets.sh dev
sudo k3s kubectl apply -k kubernetes/overlays/dev
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

## 4. Access from local WSL (one background SSH tunnel)

The cluster runs on a private VM. Use the root-level **`kubernetes_start.sh`** utility from your **local WSL shell** (e.g. `root@Seryoga-MC`), **not inside the Ubuntu VM**. It uses your existing `liora-vm100` SSH alias and the restricted Proxmox jump host.

```bash
cd ~/german-job-market-analytics
git fetch origin
git switch kubernetes-deployment
git pull

./kubernetes_start.sh dev
```

The script discovers the Kubernetes Service ClusterIPs through SSH, establishes **one detached SSH tunnel** with several localhost-only port forwards, verifies the Nginx endpoint, and prints URLs and the current Grafana, Airflow and PostgreSQL credentials. The script **does not deploy, restart, or expose any pods publicly**; the cluster must already have been deployed by `kubernetes/deploy.sh` on the VM.

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

Tunnel management from WSL:

```bash
./kubernetes_start.sh dev          # Start, or reuse an existing tunnel, and show URLs/passwords
./kubernetes_start.sh dev status   # Check tunnel status
./kubernetes_stop.sh dev           # Stop just this tunnel
```

The background SSH process remains alive when the starting terminal closes, **as long as the local WSL instance continues running**. After restarting WSL or rebooting, run the start command again. If you previously opened `ssh -N -L ...` manually using the same WSL ports, stop it with Ctrl+C first. You can also stop old `kubectl port-forward` commands on the VM; the new script does not use them.

This approach forwards directly from the Ubuntu VM to its Kubernetes ClusterIP Services, avoiding long-running `kubectl port-forward` terminals. It depends on Service IPs being reachable from the k3s node, which is supported by this cluster's networking setup. If networking changes, stop and restart the tunnel to discover the current Service IPs. All locally exposed ports are explicitly bound to `127.0.0.1`.

You can override the SSH destination (default `liora-vm100`) using `JOB_MARKET_VM_SSH_HOST=your-ssh-alias ./kubernetes_start.sh dev`.

The `prod` overlay, if deployed, can be accessed separately using `./kubernetes_start.sh prod`; it uses different local ports to avoid collisions. Do not deploy both full environments on this VM unless its capacity permits it.

### Manual fallback

If the single SSH tunnel cannot reach the ClusterIP Services, the older two-hop method remains available. On the **VM**:

```bash
sudo k3s kubectl -n dev port-forward svc/nginx 8088:80
```

Then from a separate **local WSL** terminal:

```bash
ssh -N -L 8088:127.0.0.1:8088 liora-vm100
```

The manual forwarding processes must remain running. This fallback is separate from `kubernetes_start.sh`.

The optional Traefik Ingress hosts (`job-market-dev.test` and `job-market.test`) are example names, not public DNS records; they require suitable routing and DNS.

## 5. Run ETL

Airflow's DAG schedules the daily ETL at **06:00**, writing to PostgreSQL and Elasticsearch and publishing ETL metrics to Pushgateway. Airflow's `/opt/airflow/data` and the manual ETL runner's `/app/data` share a PVC.

The Kubernetes `data-update` CronJob is intentionally **suspended** to avoid triggering the ETL twice each day. Start an initial import or manual refresh with:

```bash
sudo k3s kubectl -n dev create job \
  --from=cronjob/data-update "data-update-$(date +%s)"
sudo k3s kubectl -n dev get jobs
sudo k3s kubectl -n dev logs job/JOB_NAME --follow
```

Replace `JOB_NAME` with the created Job name. Avoid overlapping manual updates with an Airflow ETL run, since both modify the same database and search index. The scheduled DAG can be managed from Airflow's UI.

## 6. Production overlay and resource limits

The `prod` namespace uses `:main` images. Once the main-branch images have been published and its registry access is ready:

```bash
sudo bash kubernetes/deploy.sh prod
```

A VM with **4 vCPUs, 16 GiB RAM and a 30 GiB disk** may not have enough capacity for two complete stacks simultaneously. Prefer **one environment at a time** on this node, or increase capacity. A `prod` namespace does not make this setup production-grade.

For manifest previews:

```bash
sudo k3s kubectl kustomize kubernetes/overlays/dev
sudo k3s kubectl kustomize kubernetes/overlays/prod
```

After changing images, redeploy and restart workloads if necessary; Kubernetes does not automatically restart pods when a moving GHCR tag is republished. For reproducible releases, prefer immutable `sha-<commit>` image tags. Back up PostgreSQL, Airflow state, ETL files and relevant credentials; local-path PVCs are not a disaster-recovery solution.
