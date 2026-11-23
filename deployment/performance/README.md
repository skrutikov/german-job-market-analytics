# Performance testing and Kubernetes monitoring

This phase adds a **Grafana performance dashboard**, Kubernetes container metrics (CPU/memory and current Pod restarts), and **Grafana k6** load scenarios for FastAPI job searches. It builds on the existing Prometheus and Argo CD deployment. No performance limits or service-level objectives (SLOs) have been inferred from unmeasured results.

## What's monitored

The existing FastAPI metrics already expose `job_search_requests_total`, `job_search_duration_seconds_bucket` and `active_database_connections`. The new **Job Market — Performance & Kubernetes** dashboard includes:

| Graph | Source | Meaning |
|---|---|---|
| Throughput (requests/s) | FastAPI / Prometheus | Search requests per second, grouped by status |
| Search errors (%) | FastAPI / Prometheus | Handler-reported exceptions divided by recorded searches |
| Search p50, p95, p99 (seconds) | FastAPI / Prometheus | Backend-side search latency, with a 5-minute window |
| Active database connections | FastAPI / Prometheus | Connections currently observed by app instrumentation |
| Container CPU (cores) | Kubelet cAdvisor / Prometheus | CPU consumption by running container in the selected namespace |
| Container memory (bytes) | Kubelet cAdvisor / Prometheus | Memory working set by container |
| Container restarts | kube-state-metrics / Prometheus | Restarts for currently existing Pods |
| Monitoring targets | Prometheus | Scrape health of backend, cAdvisor and kube-state-metrics |

The dashboard is provisioned alongside the existing ETL dashboard. The `namespace` selector defaults to `dev`; it can be changed to `prod` if that overlay is deployed.

**Metrics limitations:** The current FastAPI search error counter records failures inside the monitored `/jobs` handler; it is not a complete HTTP 4xx/5xx counter for all API routes. The k6 client measures full HTTP round trips, while the FastAPI histogram measures server-side handler execution. The two latency measurements will not exactly match. Restart counts can decrease when old Pods are deleted and replaced. Prometheus data retention remains **7 days**.

## Kubernetes metrics architecture

Prometheus scrapes two extra targets:

- **`kubernetes-cadvisor`** — kubelet `/metrics/cadvisor` via the Kubernetes API server's HTTPS node proxy, using the in-cluster Prometheus service account; read-only `nodes` discovery and `nodes/proxy` access is granted by environment-specific ClusterRoles
- **`kube-state-metrics:8080`** — a lightweight pinned `v2.20.0` exporter, limited to Pod state in its own application namespace and granted only `get/list/watch` on Pods in that namespace

The new exporter adds one small Pod. Container metrics are gathered from Kubernetes, not by installing a privileged exporter on the Proxmox host. The application and its PVCs are unchanged.

## Deploy and test the feature branch through Argo CD

**Prerequisite:** the cluster and existing `dev` stack are running; Argo CD currently tracks `main`. Do not run the load tests until Prometheus targets are healthy.

1. From the **Proxmox VM**, switch the existing Argo CD Application to track `performance-monitoring` for testing (this changes a single Application field, not the application resources manually):

   ```bash
   sudo k3s kubectl -n argocd patch application job-market-dev \
     --type merge \
     -p '{"spec":{"source":{"targetRevision":"performance-monitoring"}}}'
   ```

2. Argo CD will discover the feature branch and apply its Kustomize overlay automatically. Verify rollouts from the **Proxmox VM**:

   ```bash
   sudo k3s kubectl -n dev rollout status deployment/kube-state-metrics
   sudo k3s kubectl -n dev rollout status deployment/prometheus
   sudo k3s kubectl -n dev rollout status deployment/grafana
   sudo k3s kubectl -n argocd get application job-market-dev
   ```

3. From the **local machine**, start/reuse the existing browser tunnel:

   ```bash
   ./kubernetes_start.sh dev
   ```

   Open Grafana at `http://127.0.0.1:13000` and go to **Job Market → Job Market — Performance & Kubernetes**. Prometheus is at `http://127.0.0.1:19090`.

4. In Prometheus (or Grafana Explore), verify:

   ```promql
   up{job="job-market-backend"}
   ```

   ```promql
   up{job="kubernetes-cadvisor"}
   ```

   ```promql
   up{job="kube-state-metrics"}
   ```

   All should return **1**. Then check `container_memory_working_set_bytes{namespace="dev",container="backend"}` and `kube_pod_container_status_restarts_total{namespace="dev"}`. If the k6 script generates requests but the graph stays empty, examine **Status → Targets** in Prometheus before modifying any manifests. The first container CPU datapoints require more than one scrape.

**Safety:** Argo CD auto-syncs and self-heals with automatic pruning enabled; persistent-volume claims have resource-specific pruning protection. Switching its tracked branch may roll out Prometheus/Grafana because their generated ConfigMaps change. The old metrics dashboard is preserved, and state is held on persistent volumes.

## Run k6 from the local machine

Install k6 on the **local machine**, not the Proxmox VM, so the load generator doesn't compete with PostgreSQL, Elasticsearch and FastAPI for the VM's 4 CPU cores. Use the platform-appropriate install instructions at [Grafana k6](https://grafana.com/docs/k6/latest/set-up/install-k6/).

The local SSH tunnel must be active. Confirm the target manually:

```bash
curl -fsS http://127.0.0.1:8088/api/health
```

**Smoke test** — 1 virtual user, 5 iterations:

```bash
k6 run -e BASE_URL=http://127.0.0.1:8088 -e PROFILE=smoke deployment/performance/k6/job-search.js
```

**Ramping test** — gradual increases through 1, 5, 10 and 20 virtual users, followed by ramp-down:

```bash
k6 run -e BASE_URL=http://127.0.0.1:8088 -e PROFILE=ramp deployment/performance/k6/job-search.js
```

The script randomly mixes keyword searches (`Data Engineer`, `Python`, `AI Engineer`) and unfiltered listings. It checks for HTTP 200 and a JSON-array response, with short pauses between requests. It never writes application data.

**Provisional test guardrails:** the script fails if more than 5% of HTTP requests fail or more than 5% of response checks fail. These are initial test-health gates, **not production SLOs**. We will choose a sensible p95 latency threshold only after gathering baseline measurements.

To save the k6 summary locally:

```bash
mkdir -p deployment/performance/results
k6 run -e BASE_URL=http://127.0.0.1:8088 -e PROFILE=ramp \
  --summary-export deployment/performance/results/ramp-summary.json \
  deployment/performance/k6/job-search.js
```

`deployment/performance/results/` is Git-ignored. Observe the same test interval in Grafana (last 15–30 minutes; 10-second refresh) and compare **k6 throughput/p95/errors** with **FastAPI CPU/memory/p95**. When testing the small VM, prefer the smoke profile first and do not run multiple ramp tests or ETL updates concurrently. Stop if services become unhealthy.

## Restore main after the feature branch is merged

Once the branch is squash-merged, use the **Proxmox VM** to tell Argo CD to follow `main` again:

```bash
sudo k3s kubectl -n argocd patch application job-market-dev \
  --type merge \
  -p '{"spec":{"source":{"targetRevision":"main"}}}'
```

Check `sudo k3s kubectl -n argocd get application job-market-dev`. The local Git checkout on the VM does **not** control Argo CD's Git revision; no `git pull` is required for automatic sync.

## Later milestones

1. Record baseline latency, throughput and resource use under the same k6 profile.
2. Decide application-specific SLOs and add alerts only after measuring realistic performance.
3. Add Trivy image/dependency scanning to CI and review probe/resource settings.
4. Consider immutable image digests for GitOps releases and k6 output integration after the basic observations are reliable.

Sources: [k6 scenarios](https://grafana.com/docs/k6/latest/using-k6/scenarios/), [k6 thresholds](https://grafana.com/docs/k6/latest/using-k6/thresholds/), [Kubernetes metrics endpoints](https://kubernetes.io/docs/concepts/cluster-administration/system-metrics/), [kube-state-metrics](https://github.com/kubernetes/kube-state-metrics).

The next phase now lives in [SLOs and alerting](../slo/README.md), including the latency/success targets and alert validation workflow.
