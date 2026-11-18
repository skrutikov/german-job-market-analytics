# Disaster recovery — Proxmox / single-node k3s

This implements Liora section 9: database and important persistent-storage
backups, node/container recovery, IaC recreation, and immutable-image rollback.
**It is a lab DR plan, not high availability or point-in-time recovery.**
The primary failure scenario is accidental destruction of the Ubuntu/k3s VM.

## Recovery targets and coverage

| State | Backup | Recovery |
| --- | --- | --- |
| PostgreSQL `job_market` | Online `pg_dump -Fc` (PostgreSQL 17) | `pg_restore --single-transaction --clean --if-exists` |
| `job-market-secrets` in **each** namespace | Minimal Secret JSON (encrypted at rest) | Apply **before** the PostgreSQL Deployment |
| `airflow-state` PVC | Quiesced tar/gzip (includes Airflow SQLite DB and auth state) | Restore to empty PVC before starting Airflow |
| `etl-data` PVC | Quiesced tar/gzip (raw and intermediate ETL files) | Restore to empty PVC |
| `grafana-data` PVC | Quiesced tar/gzip (local dashboards/settings) | Restore to empty PVC before starting Grafana |
| Elasticsearch `elasticsearch-data` PVC | Not copied; search index is **derived** from PostgreSQL | Rebuild with `sync_jobs_index()` (see below) |
| Prometheus `prometheus-data` PVC | Not copied; historical 7-day metrics are intentionally forfeited | Prometheus recreates timeseries and resumes scraping |
| Git manifests, Terraform, Ansible, configuration | Versioned in Git; no secrets committed | Reprovision and deploy the recorded revision |
| Terraform state, Proxmox API token, VM SSH keys | **Operator-managed separately**; not captured by these scripts | Restore from protected off-VM operator storage |

Each environment has **separate** credentials, databases, and PVCs. Run one
backup per namespace. Do not mistakenly use dev secrets with prod data.

Suggested lab objectives: **RPO 24 hours** with one successful backup daily,
**RTO 2 hours (target, unverified)** after access to Proxmox is restored.
Backups are **manual** in this version: the RPO goal is achieved only when
scheduled externally and monitored. A test on another VM is needed to measure
the real RTO. Retain at least 7 daily successful backups per namespace;
implement operator-side retention and capacity checks. No backup lives on the
original VM. The operator must independently back up the age identity and
Terraform state; without them encrypted archives/VM recreation may be unusable.

## Threat model and prerequisites

Run the scripts from a **trusted workstation**, with `ssh k3s-vm` configured
as in [the infrastructure guide](../infrastructure/README.md). The SSH
connection uses the Proxmox jump host, not an exposed Kubernetes API. The
remote Ubuntu VM must support `sudo -n k3s kubectl`. Install `age`, `ssh`,
`gzip`, `sha256sum`, and `python3` on the workstation.

Generate an encryption identity **once on the workstation**, and store its
private key separately from archives (an offline copy is recommended):

```bash
umask 077
mkdir -p "$HOME/.config/job-market-dr"
age-keygen -o "$HOME/.config/job-market-dr/identity.txt"
age-keygen -y "$HOME/.config/job-market-dr/identity.txt"
```

Copy the printed `age1...` public recipient into your shell:

```bash
export DR_RECIPIENT='age1REPLACE_WITH_YOUR_PUBLIC_RECIPIENT'
export DR_BACKUP_ROOT="$HOME/job-market-off-vm-backups"
```

The operator workstation is **outside the VM** but is not automatically
a second failure domain. Copy encrypted completed backup directories to
another protected host or external medium, verify checksums there, and keep
the decryption key independent. Never commit archives or private identities,
store unencrypted Secret JSON, or upload real database dumps to GitHub.
Backup artifacts have restrictive local permissions; remember disk encryption
and access control for the destination as well. A public recipient alone
cannot decrypt the backup.

## Create backup (normal operation)

1. Pick `dev` or `prod`. Record the current matching image tags in
   `kubernetes/overlays/<namespace>/kustomization.yaml` and the Git commit;
   note the `production` branch for prod. Confirm sufficient free space.
2. **Pause that Argo CD Application's automatic sync/self-healing** in the UI
   (job-market-dev or job-market-prod), and prevent new ETL runs. Check no
   active ETL Jobs; Airflow must not launch another DAG. In the VM, quiesce
   SQLite-writing workloads. This causes downtime for Airflow/Grafana:

   ```bash
   sudo k3s kubectl -n dev scale deployment/airflow deployment/grafana --replicas=0
   sudo k3s kubectl -n dev get jobs
   sudo k3s kubectl -n dev get deployments airflow grafana
   ```

   Replace `dev` with `prod` as needed. Wait for Pods to terminate.
   Do **not** turn automatic Argo synchronization back on during copying.
   The scripts check replicas and active Jobs but **cannot verify** that
   other manually launched writers are absent. Coordinate with operators.

3. On the **workstation**, execute:

   ```bash
   bash dr/backup.sh dev k3s-vm "$DR_RECIPIENT" "$DR_BACKUP_ROOT"
   ```

   The script streams a consistent custom PostgreSQL dump, the namespace
   Secret JSON, and tar/gzip archives of three important PVCs through SSH;
   **age encrypts each stream before writing it on the workstation**.
   Temporary BusyBox reader Pods mount one PVC at a time and are deleted
   after each copy. `SHA256SUMS` is written only after all steps succeed.
   Backup directory pattern: `$DR_BACKUP_ROOT/dev/YYYYMMDDTHHMMSSZ`.

4. Check the exit code and archive sizes:

   ```bash
   cd "$DR_BACKUP_ROOT/dev/YYYYMMDDTHHMMSSZ"
   sha256sum -c SHA256SUMS
   ls -lh *.age
   ```

   A checksum validates storage integrity, **not** database restorability.
   An incomplete directory without `SHA256SUMS` is not usable.
   Copy the entire completed encrypted directory to second off-VM storage.
5. Resume Airflow/Grafana replicas to 1 and restore Argo CD auto-sync.
   Confirm Pods are healthy. If a helper Pod remains from an interrupted
   backup, inspect it, then delete with
   `sudo k3s kubectl -n dev delete pod dr-volume-helper`.
   Never leave an inconsistent, failed copy marked as successful.

**Automation:** the shell script can be invoked by a workstation cron/systemd
timer *only* with a safe coordinated maintenance window that pauses Argo and
the two writers, resumes them even on failure, verifies backup success, and
alerts on missing daily backups. The repository does **not** ship such a timer
or automatically disable GitOps; installing a naive nightly cron would make
Airflow SQLite backups inconsistent.

## Destructive restore drill — fresh VM, not the original production VM

**Practice first on a disposable Proxmox VM with a different VM ID/IP.** The
commands below are an operator runbook, not a claim that a live disaster was
already simulated. No step in these scripts invokes `terraform destroy`.
The workstation initiates all recovery actions via SSH, and every restore
stage requires `CONFIRM_RESTORE=<namespace>`.

1. **Recreate infrastructure** from the workstation using the documented
   [Terraform/Ansible `./deploy.sh`](../infrastructure/README.md).
   Restore/provide Terraform state and the required Proxmox API token/ACLs.
   Use a *different test VM* to avoid destroying source data. On the new
   Ubuntu VM, install `git`, clone the repository and select the **same
   recorded Git revision**, but **do not run `setup_vm.sh` or
   `kubernetes/deploy.sh` yet**: they start writers too early for a
   restore into empty volumes. Set up Elasticsearch's required
   `vm.max_map_count=262144` before final deployment.

2. **Prepare fresh PVCs and restore credentials and archives**. On the
   workstation, point `BACKUP` to the **complete local backup directory**:

   ```bash
   export BACKUP="$HOME/job-market-off-vm-backups/dev/YYYYMMDDTHHMMSSZ"
   export AGE_IDENTITY="$HOME/.config/job-market-dr/identity.txt"
   export CONFIRM_RESTORE=dev

   bash dr/restore.sh dev k3s-vm "$BACKUP" "$AGE_IDENTITY" prepare
   bash dr/restore.sh dev k3s-vm "$BACKUP" "$AGE_IDENTITY" secrets
   bash dr/restore.sh dev k3s-vm "$BACKUP" "$AGE_IDENTITY" volumes
   ```

   `prepare` creates the namespace and four PVCs; `secrets` reinstalls the
   saved PostgreSQL/Grafana credentials; `volumes` copies files into **empty**
   PVCs. The script refuses to replace nonempty file volumes. All files are
   checked against SHA-256 digests before any stage. The backing image is
   pinned to BusyBox 1.36; ensure the cluster can pull it.

3. **Start PostgreSQL alone** on the new VM. The checkout must match the
   recorded revision (for prod, the approved `production` revision):

   ```bash
   cd ~/german-job-market-analytics
   sudo k3s kubectl -n dev apply -f kubernetes/base/postgres.yaml
   sudo k3s kubectl -n dev rollout status deployment/postgres --timeout=180s
   ```

   Then restore PostgreSQL from the workstation:

   ```bash
   bash dr/restore.sh dev k3s-vm "$BACKUP" "$AGE_IDENTITY" postgres
   ```

   The restore verifies the `pg_restore` table of contents, then uses
   `--clean --if-exists --exit-on-error --single-transaction`. Existing
   PostgreSQL schema and rows **will be overwritten**. This is not an
   incremental merge. The dump captures only `job_market`, not server-global
   roles beyond the initial container user. Same PostgreSQL major version
   (17) is the safest recovery target.

4. **Deploy application** on the VM from the chosen recorded Git revision:

   ```bash
   sudo k3s kubectl apply -k kubernetes/overlays/dev
   sudo k3s kubectl -n dev rollout status deployment/backend --timeout=600s
   sudo k3s kubectl -n dev rollout status deployment/airflow --timeout=600s
   ```

   For prod, use the `production` checkout/overlay and `prod` namespace.
   Airflow SQLite and Grafana data were restored *before* their Pods start.
   In a new cluster, install/restore Argo CD separately as per
   [Argo bootstrap](../argocd/README.md), **after** validating recovered
   state; ensure its Application points to `main` for dev or
   `production` for prod. Enable automated sync only after checks.

5. **Rebuild Elasticsearch from restored PostgreSQL** (the search index
   is derived; do not restore raw Elasticsearch files or assume it exists):

   ```bash
   sudo k3s kubectl -n dev exec deployment/backend -- python -c \
     'from job_market.elasticsearch.elasticsearch import sync_jobs_index; print(sync_jobs_index())'
   ```

   Wait for Elasticsearch readiness first. The reindexer replaces the current
   jobs index with records from PostgreSQL. Run it **once**, then resume
   scheduled ingestion. For application and DB smoke checks:

   ```bash
   sudo k3s kubectl -n dev exec deployment/postgres -- sh -c \
     'PGPASSWORD="$POSTGRES_PASSWORD" psql -U job_market -d job_market -Atqc "SELECT count(*) FROM jobs"'
   sudo k3s kubectl -n dev rollout status deployment/frontend
   sudo k3s kubectl -n dev rollout status deployment/nginx
   sudo k3s kubectl -n dev get pods,pvc
   ```

   Record a known count from the source backup/test dataset, compare it,
   check `/api/health` through the existing tunnel, verify job search,
   Grafana and Airflow DAG state, and confirm the correct image SHA.
   Verify that a new ETL run does not duplicate/corrupt restored data.
   Do not trigger an unnecessary `init_airflow.sh` initial import before
   checking the restored scheduler and tables.

## Container, node, and VM failures

- **Container crash:** Kubernetes restart policy and readiness/liveness
  probes restart unhealthy Pods; check `kubectl -n dev get pods`,
  `describe pod`, and `logs`. Do not restore a DB for a transient crash.
- **k3s node/VM reboot:** check k3s, Pods and PVC mounts; if the VM disk
  survives, PVCs and Secrets should survive a normal reboot. Restart
  missing Deployments through GitOps; use backups only if storage is lost.
- **Single-node VM or disk loss:** there is no second node to reschedule
  stateful Pods. Recreate VM via Terraform/Ansible and follow the staged
  restore above. Default k3s local-path storage and SQLite are not HA.
- **Proxmox host failure:** requires host/storage recovery by the operator;
  these scripts cannot recreate Proxmox itself.

## Rollback to a previous immutable release (without reverting data)

Two application images (backend/frontend/ETL and Airflow) are pinned in
`kubernetes/overlays/dev/kustomization.yaml` or `.../prod/kustomization.yaml`
using `sha-<40-character-commit>` tags, for example
`ghcr.io/skrutikov/german-job-market-analytics:sha-...`. These are stable
release identifiers, unlike moving `:dev`/`:main` tags.

1. Identify a **previously published and tested** SHA for **both** images
   from GHCR/CI and verify both exist. Back up database/state first if a
   rollback may involve schema compatibility.
2. Change **both** Kustomize `images[].newTag` values to that same old
   `sha-...` tag on the **branch watched by Argo CD**: `main` for dev or
   `production` for prod. Use a review/approval for production and
   follow the branch rules. Do not push an unreviewed override to prod.
3. Validate `kubectl kustomize kubernetes/overlays/<env>` and CI tests,
   commit the change, let Argo CD sync, then inspect:
   `kubectl -n <env> rollout status deployment/backend`,
   `deployment/airflow`, and running images. Ensure CI's dev image-tag
   updater will not immediately replace the chosen rollback release.
4. If the new release also modified the PostgreSQL schema, **image rollback
   alone does not undo database migrations**; evaluate compatibility or use
   a separate, explicitly authorized database restore with data-loss impact.
   Never delete a PVC or run `kubectl rollout undo` as the sole persistent
   GitOps rollback, because Argo may immediately reconcile it away.

For approval and branch controls, also see
[dev-to-prod promotion](dev-to-prod-promotion.md).

## Validation and limits

- The [CI DR smoke test](../.github/workflows/disaster-recovery.yml) uses a
  real PostgreSQL 17 container to create a table, `pg_dump -Fc`, mutate the
  row, `pg_restore --clean --single-transaction`, and assert the old
  value returns. It also checks Bash syntax.
- This **does not test** SSH, Proxmox, volume helper Pods, encrypted transfers,
  the live cluster, or application end-to-end recovery. Run and record at
  least one **isolated VM restore drill** before claiming the Liora DR
  requirement is fully tested. Record the timestamp, SHA-256 verification,
  source/recovered row counts, Airflow/Grafana checks, data age, and downtime.
- With daily dumps the latest writes after the snapshot can be lost (RPO).
  There is no PostgreSQL WAL archive, PITR, automated offsite scheduler,
  S3 replication, or multi-node failover. Grafana/SQLite consistency depends
  on pausing writers and Argo reconciliation.
