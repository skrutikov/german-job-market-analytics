# Job-search SLOs and alerting

This phase introduces **measurable reliability objectives**, Prometheus recording/alerting rules, an eight-panel Grafana dashboard and a safe alert-routing smoke test. The setup runs in the existing k3s `dev` application and uses **no new Pods, PVCs, credentials, or external notification endpoints**.

## Scope and provisional objectives

The measured operation is **GET /api/jobs**, implemented by the monitored FastAPI `/jobs` handler. Its search instrumentation records one success or failure per handler invocation and the handler's execution time.

| Objective | SLI definition | Initial target | Window |
|---|---|---|---|
| Search availability | successful monitored searches / all monitored searches | **≥99%** | Rolling **24h** |
| Search latency | handler calls taking **≤250 ms** / all timed handler calls | **≥95%** | Rolling **24h** |

These are **provisional demonstration SLOs**, not contractual SLAs or evidence of production reliability. Our ramp test baseline was around 856 requests with no recorded failures and low backend latency. The thresholds are deliberately looser than those measurements to avoid false incidents during ordinary variation; refine them after representative, sustained workloads.

The application currently retains **7 days** of Prometheus data, so a 24-hour rolling SLO is practical. Before claiming a 28/30-day monthly SLO, increase retention and storage capacity appropriately.

### Important metric limitations

- This is **not whole-site availability**. Errors in the frontend, Nginx, other API routes, and validation errors rejected before the handler executes are not counted. Exceptions (including raised HTTP 503 responses) within the monitored handler are counted as failures.
- Latency is measured **inside the FastAPI handler**, not total HTTP round-trip latency. Client-side k6 times include Nginx, network and SSH forwarding.
- The latency SLI uses the Python Prometheus histogram's `le="0.25"` bucket directly, **not an estimated p95**. The bucket is cumulative and includes handler calls that raise exceptions.
- No traffic cannot establish reliability: the ratios are undefined when no requests are observed. We don't convert missing traffic into 100% availability.
- Percentage-based SLO breach alerts need **at least 100 searches in the past 24h**; short-window warnings need **at least 20 in the past 15m**. With fewer samples, the dashboard may show a ratio, but the alarms intentionally do not trigger. Five smoke requests are insufficient for these alarms.
- A successful `/health` response and `up=1` confirm reachability/metric scraping, not that PostgreSQL or Elasticsearch queries work. Check search-specific alerts as well.
- The ETL freshness alert from the earlier monitoring phase is kept unchanged.

## Recording rules and alerts

All rules are defined in `kubernetes/base/config/alerts.yml`, packaged into the generated `prometheus-config` ConfigMap, and evaluated by Prometheus every minute.

| Alert | Condition | Hold period | Severity |
|---|---|---|---|
| `JobSearchAvailabilitySLOBreach` | 24h success ratio below 99%, at least 100 searches | 10m | critical |
| `JobSearchLatencySLOBreach` | 24h fraction ≤250 ms below 95%, at least 100 searches | 10m | critical |
| `JobSearchErrorRateHigh` | 15m search failures above 5%, at least 20 searches | 3m | warning |
| `JobSearchLatencyDegrading` | 15m fraction ≤250 ms below 90%, at least 20 searches | 5m | warning |
| `BackendMetricsUnavailable` | `up{job="job-market-backend"} == 0` | 3m | critical |
| `BackendMetricsTargetMissing` | Backend target disappears entirely | 5m | critical |
| `KubernetesMetricsUnavailable` | cAdvisor or kube-state-metrics scrape fails | 5m | warning |
| `AlertingPipelineTest` | Disposable metric `job_market_alert_test == 1` | 1m | info |
| `ETLNotSuccessfulForTooLong` | Previously defined ETL freshness threshold | 30m | error |

`for` hold times avoid reacting to single measurements. The low-traffic thresholds avoid noisy percentage alerts on tiny samples. A monitoring-target alert remains independent of traffic volume.

**Delivery limitation:** Alertmanager groups, displays and deduplicates alerts, and Prometheus forwards firing alerts to it. The default receiver intentionally has **no Slack/email integration**, because no notification destination or credentials have been supplied. Therefore **nothing is sent externally** yet. Open Prometheus → **Alerts** or Alertmanager → **Alerts** using the existing private tunnel. External notifications should be configured with a Kubernetes Secret before relying on unattended paging.

## Deploy the feature branch with Argo CD

Argo CD normally tracks `main`. On the **Proxmox VM**, change only the tracked Git revision to test this branch (do not manually `kubectl apply` the application):

```bash
sudo k3s kubectl -n argocd patch application job-market-dev \
  --type merge -p '{"spec":{"source":{"targetRevision":"slo-alerting"}}}'
sudo k3s kubectl -n argocd get application job-market-dev
```

Argo CD normally notices Git changes after a few minutes. Prometheus, Alertmanager and Grafana may roll out when their generated ConfigMaps change. The underlying PVCs and application data are preserved.

On the **Proxmox VM**, verify:

```bash
sudo k3s kubectl -n dev rollout status deployment/prometheus
sudo k3s kubectl -n dev rollout status deployment/alertmanager
sudo k3s kubectl -n dev rollout status deployment/grafana
sudo k3s kubectl -n argocd get application job-market-dev
```

On the **local machine**, start the existing private tunnel if needed:

```bash
./kubernetes_start.sh dev
```

Then inspect:

- **Grafana:** http://127.0.0.1:13000 — **Job Market → Job Market — SLOs & Alerts** (eight panels)
- **Prometheus:** http://127.0.0.1:19090 — **Status → Rules**, **Alerts**, **Status → Targets**
- **Alertmanager:** http://127.0.0.1:19093 — active alerts and silences

Prometheus queries to verify:

```promql
job_market:search_requests:count24h
```

```promql
100 * job_market:search_availability:ratio24h
```

```promql
100 * job_market:search_latency_under_250ms:ratio24h
```

```promql
up{job=~"job-market-backend|kubernetes-cadvisor|kube-state-metrics"}
```

The `up` series should each be `1`. The SLO ratios may initially be absent or NaN until searches have been measured. Optionally run the existing **k6 ramp** profile from the local machine to generate more than 100 real requests:

```bash
k6 run -e BASE_URL=http://127.0.0.1:8088 -e PROFILE=ramp performance/k6/job-search.js
```

Avoid testing concurrently with ETL. The k6 **smoke** profile (five requests) is useful for checking the endpoint but insufficient to test SLO alert volumes.

## Safe live alert test

This uses a **disposable Pushgateway group** to exercise the real Prometheus → Alertmanager path. It does not change job-search metrics, overload containers or break dependencies.

On the **Proxmox VM** (where the k3s Service ClusterIP is reachable), run:

```bash
PUSHGATEWAY_IP="$(sudo k3s kubectl -n dev get svc pushgateway -o jsonpath='{.spec.clusterIP}')"
printf 'job_market_alert_test 1\n' |
  curl -fsS --data-binary @- "http://$PUSHGATEWAY_IP:9091/metrics/job/slo-alert-test"
```

Prometheus scrapes Pushgateway every 15s and evaluates alert rules every minute. After the test condition has held for one minute, `AlertingPipelineTest` should enter **Firing** in **Prometheus → Alerts** and appear in **Alertmanager**. The Grafana **Firing alerts** statistic should increase. This confirms the alerts are working **inside the cluster**, but does not test email or Slack (none configured).

**Always clean up the test metric**, even if you do not see the alert:

```bash
curl -fsS -X DELETE "http://$PUSHGATEWAY_IP:9091/metrics/job/slo-alert-test"
```

After the next scrape/evaluation, the alert resolves and Grafana returns to its previous firing count. The metric won't reappear because the test group is removed from Pushgateway.

If the VM cannot reach the Service ClusterIP, inspect cluster networking first; do not expose Pushgateway publicly.

## Troubleshooting

1. **Application status:** `sudo k3s kubectl -n argocd get application job-market-dev`; check whether it is **Synced / Healthy**, and inspect deployment rollouts under `dev`.
2. **Target unavailable:** in Prometheus **Status → Targets**, inspect `job-market-backend`, `kubernetes-cadvisor`, `kube-state-metrics` and `job-market-etl`. Verify `/metrics/` (trailing slash) for the FastAPI scrape target.
3. **Search errors:** run `sudo k3s kubectl -n dev logs deployment/backend --tail=200`. Investigate PostgreSQL or Elasticsearch readiness, timeouts and error responses.
4. **Slow searches:** correlate the new SLO dashboard with **Job Market — Performance & Kubernetes**. Examine backend/Elasticsearch CPU, memory, request throughput and server-side latency; compare k6 full HTTP latency.
5. **No SLO samples:** make some valid `GET /api/jobs` requests, then check `job_search_requests_total` and `job_search_duration_seconds_bucket` directly in Prometheus. The recording rules require enough raw samples to calculate `increase()`.
6. **Alertmanager empty:** no alerts could simply be firing. For a functional test, use the disposable Pushgateway metric above. Without external receivers, an alert never produces an outside notification.

## Tests and promotion to main

CI uses pinned Prometheus and Alertmanager images to run:

```bash
promtool check rules kubernetes/base/config/alerts.yml
promtool test rules kubernetes/tests/slo-alerts.test.yml
amtool check-config kubernetes/base/config/alertmanager.yml
```

The synthetic tests cover healthy searches, high failures, high latency, low-traffic suppression, unavailable/missing metrics and the disposable alert signal. They do not depend on a live cluster.

After the live dashboard and alert test pass, **squash-merge** `slo-alerting` into `main`. Restore Argo CD to `main` on the Proxmox VM:

```bash
sudo k3s kubectl -n argocd patch application job-market-dev \
  --type merge -p '{"spec":{"source":{"targetRevision":"main"}}}'
sudo k3s kubectl -n argocd get application job-market-dev
```

No `git pull` on the VM is required for Argo CD to fetch manifests from GitHub. If `argocd/configure-sync.sh` is needed later for PVC protection, update the local checkout to `main` first.

## Next steps

- Add an explicitly configured external receiver (e.g., Slack) using a Kubernetes Secret; avoid committing webhook tokens.
- Build a longer history and revisit provisional SLO targets using regular representative tests.
- Consider a broader end-to-end HTTP SLI and synthetic checks so gateway/front-end failures also affect availability.
- Implement Trivy vulnerability scanning on a **separate** `trivy-scanning` branch.
