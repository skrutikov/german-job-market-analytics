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
as in [the infrastructure guide](../deployment/README.md). The SSH
connection uses the Proxmox jump host, not an exposed Kubernetes API. The
remote Ubuntu VM must support `sudo -n k3s kubectl`. Install `age`, `ssh`,
`gzip`, `sha256sum`, and `python3` on the workstation.

On Ubuntu/WSL2, install the required packages (already-installed packages are left in place):

```bash
sudo apt install age openssh-client gzip coreutils python3
```

`sha256sum` is included in `coreutils`; it is not a separate APT package.

Generate an encryption identity **once on the workstation**, and store its
private key separately from archives (an offline copy is recommended):

```bash
umask 077
mkdir -p "$HOME/.config/job-market-dr"
age-keygen -o "$HOME/.config/job-market-dr/identity.txt"
age-keygen -y "$HOME/.config/job-market-dr/identity.txt"
```

The backup script now derives the public recipient automatically from
`$HOME/.config/job-market-dr/identity.txt` using `age-keygen -y`. It also
defaults to `$HOME/job-market-off-vm-backups` as the backup location.
You therefore **do not need to export** `DR_RECIPIENT` or
`DR_BACKUP_ROOT` for a normal run. To override the defaults, set
`DR_IDENTITY=/path/to/identity.txt` and/or
`DR_BACKUP_ROOT=/absolute/destination` in the workstation shell.
The previous four-argument form remains supported, provided its public
recipient matches `DR_IDENTITY`.

The operator workstation is **outside the VM** but is not automatically
a second failure domain. Copy encrypted completed backup directories to
another protected host or external medium, verify checksums there, and keep
the decryption key independent. Never commit archives or private identities,
store unencrypted Secret JSON, or upload real database dumps to GitHub.
Backup artifacts have restrictive local permissions; remember disk encryption
and access control for the destination as well. A public recipient alone
cannot decrypt the backup.

## Create backup (normal operation)

1. Pick `dev` or `prod` and confirm sufficient free space on the
   workstation. **No manual recording of image tags or Git commits is needed.**
   `deployment/scripts/create_backup.sh` queries the actual Kubernetes Deployment images and Argo CD
   and writes `backup-metadata.txt` beside the encrypted backup files.
   For `prod`, Argo CD tracks `production`, which may differ from the
   Git branch checked out on either the workstation or the VM.
2. **Automatic maintenance (with explicit approval):** The script temporarily
   disables the selected Argo CD Application's automatic sync/self-healing,
   scales Airflow and Grafana to zero, waits for their Pods to exit, and
   refuses to start while independent ETL Kubernetes Jobs are active.
   This causes brief downtime for those services, including production.
   The script restores their original replica counts and Argo CD setting
   on successful completion and on ordinary errors/Ctrl+C (best effort).
   A hard termination (`SIGKILL`), workstation power loss, remote SSH
   failure, or a concurrent operator change can prevent recovery:
   verify the workload state and Argo CD auto-sync afterward.
   In interactive use you must type `YES` to authorize the interruption.
   For an approved unattended maintenance window, set
   `DR_CONFIRM_MAINTENANCE=prod` (or `dev`) explicitly.

3. On the **workstation**, execute:

   ```bash
   # Preferred when the VM is managed by a Terraform workspace:
bash deployment/scripts/create_backup.sh 103 prod

# Existing SSH-alias-based form also remains supported:
bash deployment/scripts/create_backup.sh prod k3s-vm
   ```

   The script streams a consistent custom PostgreSQL dump, the namespace
   Secret JSON, and tar/gzip archives of three important PVCs through SSH;
   **age encrypts each stream before writing it on the workstation**.
   For the three file PVCs, it discovers the bound Kubernetes PVs and reads
   the k3s **local-path directories directly on the Ubuntu VM** using
   `sudo -n tar`. The PV backing directory may be stored as either
   `spec.local.path` or `spec.hostPath.path`; both are supported and
   validated against the expected namespace, StorageClass and k3s root.
   Compression happens on the VM before transmission.
   This avoids long-running `kubectl exec` API streams, which can reset
   when copying large ETL files. There is no helper Pod during backup.
   The script verifies the PV claim association, restrictive expected
   k3s storage path, and passwordless sudo access **before** maintenance.
   It intentionally supports this single-node local-path setup, not
   arbitrary CSI/cloud/network-attached volumes. The human-readable, non-secret
   `backup-metadata.txt` records the namespace, start time, live backend,
   frontend and Airflow image references, matching release tag, GitOps branch,
   Argo CD observed Git revision and last successful sync revision, and sync
   and health status. Argo CD may be `OutOfSync` after you intentionally
   scale down workloads for the backup. The script refuses to back up when
   the tags disagree or it cannot determine a valid Argo CD revision.
   `SHA256SUMS` covers both the encrypted archives **and metadata text**;
   it is written only after all steps succeed.
   Backup directory pattern: `$HOME/job-market-off-vm-backups/prod/YYYYMMDDTHHMMSSZ`.

4. Check the exit code and archive sizes:

   ```bash
   cd "$HOME/job-market-off-vm-backups/prod/YYYYMMDDTHHMMSSZ"
   sha256sum -c SHA256SUMS
   cat backup-metadata.txt verification.txt
   ls -lh *.age
   ```

   The metadata is saved **on the workstation next to the backup**, not in
   Git. A checksum validates storage integrity, **not** database restorability.
   An incomplete directory without `SHA256SUMS` is not usable.
   Copy the entire completed encrypted directory to second off-VM storage.
5. The script automatically restores the pre-backup replica counts and
   Argo CD auto-sync policy. Verify the running workloads and Argo CD status
   before considering the maintenance complete. The `verification.txt`
   report is saved beside the backup and included in `SHA256SUMS`.
   During **every backup**, the script checks encrypted archive integrity,
   decryptability, a PostgreSQL `PGDMP` signature with a complete decrypted
   stream, and the structure of all three compressed PVC archives. When a
   **local** PostgreSQL 17+ `pg_restore` or a cached `postgres:17` Docker
   image is available, it also validates the PostgreSQL table of contents
   with `pg_restore --list`. Otherwise, the script clearly reports this
   more limited dump check; run an isolated database restore to establish
   database restorability. **Verification no longer connects to the VM.**

   **Optional real PostgreSQL restore test (recommended for the first backup):**
   Install Docker on the trusted workstation, then run:

   ```bash
   DR_TEST_DB_RESTORE=1 bash deployment/scripts/create_backup.sh prod k3s-vm
   ```

   This restores the actual dump into a temporary, network-isolated local
   PostgreSQL 17 Docker container and verifies the `jobs` table can be
   queried; the container is removed afterward. It does not touch the
   production database but temporarily uses local Docker storage containing
   decrypted data. The command still asks for maintenance approval.
   **The script resumes Airflow/Grafana and Argo CD immediately after all
   source volumes are copied, before time-consuming verification.**
   Without `DR_TEST_DB_RESTORE=1`, the automatic checks validate archive
   integrity and format but **not** the ability to restore the entire DB.

**Scheduling:** For a recurring workstation cron/systemd timer, provide
`DR_CONFIRM_MAINTENANCE=prod` only in an approved maintenance window,
avoid overlapping the 06:00 ETL, and monitor failures and missing backups.
No recurring timer is installed by this branch. Periodically repeat a
full isolated restore drill.

## Finalize a fully copied backup after a verification-only failure

If `deployment/scripts/create_backup.sh` has already copied all encrypted files but failed **only
at the verification step** (for example because an older verifier expected
five instead of four arguments), the source PVCs do **not** need to be copied
again. This avoids another Airflow/Grafana maintenance interruption.

The workstation directory must have all five nonempty `.age` archives and
`backup-metadata.txt`, and **no** `.partial` files. It must have no usable
`SHA256SUMS` file. After pulling the latest `disaster-recovery` branch,
run the following **on the trusted workstation**:

```bash
bash deployment/dr/finalize_backup.sh prod k3s-vm \
  "$HOME/job-market-off-vm-backups/prod/20261118T165839Z"
```

The script checks the expected files, namespace, SSH host and timestamp,
recalculates archive checksums, decrypts and parses the Kubernetes Secret,
fully reads the encrypted PostgreSQL dump and checks its `PGDMP` header,
and fully reads all three compressed tar archives. If a local PostgreSQL
17+ client or a previously pulled `postgres:17` Docker image is available,
it also checks the dump's table of contents using `pg_restore --list`.
**No SSH or live Kubernetes connection is needed.** The source SSH alias
argument is retained for compatibility and metadata checks only.
**It prints the current verification stage live** while saving the
same output to `verification.txt.partial`; after success, this becomes
`verification.txt`, and `SHA256SUMS` is finalized. It does not pause Argo
CD, restart Pods or write to the production database.
`DR_VERIFY_TIMEOUT_SECONDS` defaults to **900 seconds (15 minutes) per
validation pipeline**, not 900 milliseconds. For troubleshooting, set
`DR_VERIFY_TIMEOUT_SECONDS=120` to limit each validation pipeline to
2 minutes (shorter limits may reject legitimate large archives). The timeout
now covers the entire local decryption-and-check pipeline, rather than only
a remote SSH subprocess. Optional `DR_TEST_DB_RESTORE=1` performs a real
restore in a disposable local Docker container. Without it, an archive
format check is **not proof of database restorability**. Failure leaves the directory unmarked,
and it must not be used as a backup. An earlier version redirected
verification output to a file without showing it; in a second terminal,
run `tail -f /path/to/backup/verification.txt.partial` to inspect progress.

This procedure is appropriate only if the data-copy phase finished
successfully; it cannot repair missing or truncated archived data.
A full disaster-recovery validation still requires a separate test VM.

## Troubleshooting an older verification hang

A prior `verify_backup.sh` streamed the encrypted PostgreSQL dump back
through `ssh ... kubectl exec -i ... pg_restore --list`. On this cluster,
the Kubernetes API streaming connection may stall. Its 900-second timeout
applied only to the SSH part of a pipeline; it did not eliminate the
unnecessary cluster dependency.

The updated verifier validates saved files **entirely on the workstation**.
If an old finalization process is still stuck, press Ctrl+C, update the
`disaster-recovery` checkout and retry finalization of the **same**
incomplete directory:

```bash
git pull --ff-only
DR_VERIFY_TIMEOUT_SECONDS=120 bash deployment/dr/finalize_backup.sh prod k3s-vm \
  "$HOME/job-market-off-vm-backups/prod/20261118T165839Z"
```

Do not run two finalization processes concurrently. If `verification.txt`
and a complete `SHA256SUMS` already exist, verify their checksums rather
than running finalization again. Do not repeat production maintenance
merely to resolve a local archive-verification issue.

## Troubleshooting interrupted volume transfers

An earlier backup version copied uncompressed PVC tar streams through
`kubectl exec dr-volume-helper`. Large streams could fail with
`Copying stdout failed ... 127.0.0.1:6443 ... connection reset by peer`
because port 6443 is the Kubernetes API server. The updated script copies
**compressed** files straight from the Ubuntu node via SSH instead, after
verifying the local-path PV ownership and sudo tar permissions.

After a failure, on the Ubuntu VM verify that `airflow` and `grafana`
replicas were restored, and check Argo CD:

```bash
sudo k3s kubectl -n prod get deployments airflow grafana
sudo k3s kubectl -n argocd get application job-market-prod
```

On the workstation, an incomplete backup directory **without a valid
`SHA256SUMS`** must not be used for recovery. Rerun
`bash deployment/scripts/create_backup.sh prod k3s-vm` from an updated
`disaster-recovery` checkout. It creates a new timestamped directory.
If the node-path preflight fails, check the PVC/PV storage layout and
passwordless sudo permissions rather than disabling the safety check.
If it reports a blank volume path, a prior script version may be querying
only `spec.hostPath.path` even though that PV uses `spec.local.path`.
The updated resolver handles both. On the Ubuntu VM, inspect this
non-secret, read-only PV description without modifying storage:

```bash
PV=$(sudo k3s kubectl -n prod get pvc airflow-state -o jsonpath='{.spec.volumeName}')
sudo k3s kubectl get pv "$PV" -o jsonpath='{.spec.storageClassName}{"\n"}{.spec.local.path}{"\n"}{.spec.hostPath.path}{"\n"}'
```

The k3s default local-path storage root is expected to be
`/var/lib/rancher/k3s/storage`.

## Automated VM-ID recovery (recommended for disposable test VMs)

From the repository root on the operator workstation:

```bash
# Verify VM 104's Proxmox ACL, create VM 104 at ...29/24, install k3s only,
# then restore the latest verified production backup into its empty prod namespace.
./deployment/scripts/restore_backup.sh 104 29 prod

# If the recovery VM already exists and its vm-104 Terraform workspace is valid:
./deployment/scripts/restore_backup.sh 104

# After reviewing the recovery result and confirming the VM can be deleted:
./deployment/scripts/destroy.sh 104
```

The three-argument restore command **does not run a normal production deployment**:
it calls `deploy.sh 104 29 prod --infra-only` so Terraform provisions the VM
and Ansible installs k3s, but no production workloads or persistent volumes are
created before restoration. The second argument is the final IPv4 octet, **not a
port**. Both commands select the isolated Terraform workspace `vm-104`.

**Before provisioning**, the automated restore script asks you to check the
Proxmox API token's permissions for `/vms/104` on the trusted Proxmox root
console. Check for `VM.Allocate` and `VM.Config.*` privileges; **nonempty output
alone is not sufficient**. If they are missing, it prints the VM-specific
`pveum acl modify` command. Type exactly `YES` to acknowledge the check
before the VM is created. `deploy.sh` separately shows the ACL reminder
before Terraform and asks you to type `apply 104`.

The restore still verifies the SSH host and Kubernetes node against the
Terraform state, refuses VM 100, rejects any pre-existing prod workloads or
PVCs, and requires the exact `RESTORE 104` confirmation before modifying
backup data. The backup comes from
`$HOME/job-market-off-vm-backups/prod/<timestamp>` unless an absolute path
is supplied as **argument 4**; for an already-provisioned VM, the path is
**argument 2**.

The recovery script checks backup integrity and metadata, restores Secrets
and persistent volumes, starts PostgreSQL alone to restore the database,
then deploys the exact production version recorded by the backup. Airflow
and Alertmanager remain disabled, and the ETL CronJob stays suspended.
**Argo CD auto-sync is not bootstrapped** for a recovery rehearsal.

**Compatibility requirement:** The backup's recorded GitOps revision must
contain the new `deployment/kubernetes/` layout. A backup from the older
root-level `kubernetes/` layout cannot be restored automatically with this
version. Verify compatibility before provisioning a disposable VM.

If SSH reports a changed host key after VM recreation, `deploy.sh` stops
and prints the steps to verify the new fingerprint independently before
updating the workstation's `known_hosts` entry. Do not disable host-key
checking. Rerun the same restore command after fixing SSH.

For resumed or partially completed restores, **do not rerun the entire
recovery blindly**: this command intentionally refuses nonempty prod workloads
and restored PVCs. Inspect the state and resume the appropriate lower-level
`deployment/dr/restore.sh` stage, or recreate the disposable VM with a
matching isolated Terraform workspace. Never copy production Terraform
state into a recovery workspace.

## Destructive restore drill — fresh VM, not the original production VM

**Practice first on a disposable Proxmox VM with a different VM ID/IP.** The
commands below are an operator runbook, not a claim that a live disaster was
already simulated. No step in these scripts invokes `terraform destroy`.
The workstation initiates all recovery actions via SSH. **Every restore
stage now requires two independent safeguards**:
`CONFIRM_RESTORE=<namespace>` and
`DR_EXPECTED_NODE_NAME=<exact recovery Kubernetes node name>`. Before
modifying the destination, `deployment/dr/restore.sh` queries the Kubernetes node
through the provided SSH alias and refuses a mismatch. This prevents a
mistyped SSH alias from accidentally restoring production backups into the
original production VM (for example, `job-market-ubuntu-100` instead of
`job-market-dr-test`). These checks complement, rather than replace,
verification of the SSH host key and the isolated Terraform state.

1. **Recreate infrastructure** from the workstation using the documented
   [Terraform/Ansible `./deploy.sh`](../deployment/README.md).
   Restore/provide Terraform state and the required Proxmox API token/ACLs.
   Use a *different test VM* to avoid destroying source data. On the new
   Ubuntu VM, install `git`, clone the repository and select the **same
   recorded Git revision**, but **do not run `deployment/scripts/setup_vm.sh` or
   `deployment/kubernetes/deploy.sh` yet**: they start writers too early for a
   restore into empty volumes. Set up Elasticsearch's required
   `vm.max_map_count=262144` before final deployment.

**Current temporary-VM DR exercise:** The independently managed
Proxmox VM **101** uses `10.10.10.21`, Kubernetes node
`job-market-dr-test`, and its own SSH alias `k3s-dr-test`.
Production remains VM **100** (`10.10.10.20`). The saved backup is from
the **`prod`** namespace, so use `prod` on the test cluster as well,
not `dev`. Before running any restore stage on the workstation:

```bash
# The alias must connect to VM 101, NOT the production VM.
ssh -T k3s-dr-test \
  'hostname; sudo -n k3s kubectl get nodes -o wide; sudo -n k3s kubectl -n prod get deployments,cronjobs,pvc'

export BACKUP="$HOME/job-market-off-vm-backups/prod/20261118T165839Z"
export AGE_IDENTITY="$HOME/.config/job-market-dr/identity.txt"
export CONFIRM_RESTORE=prod
export DR_EXPECTED_NODE_NAME=job-market-dr-test

# Start with preparation of empty PVCs only, on the verified replacement VM.
bash deployment/dr/restore.sh prod k3s-dr-test "$BACKUP" "$AGE_IDENTITY" prepare
```

The named node must be `job-market-dr-test`; the `prod` namespace on
that VM must have no existing production deployments or data. Do not apply
the full application overlay, `deployment/scripts/setup_vm.sh`, or bootstrap automatic
GitOps/ETL before restoring volumes and PostgreSQL. A restored Airflow
scheduler may initiate external work; isolate or disable its execution and
external endpoints before eventually starting it. Monitor the limited
Proxmox host disk space during the drill and destroy only the separate
Terraform-managed VM 101 after capturing results.

2. **Prepare fresh PVCs and restore credentials and archives**. On the
   workstation, point `BACKUP` to the **complete local backup directory**:

   ```bash
   export BACKUP="$HOME/job-market-off-vm-backups/dev/YYYYMMDDTHHMMSSZ"
   export AGE_IDENTITY="$HOME/.config/job-market-dr/identity.txt"
   export CONFIRM_RESTORE=dev
   export DR_EXPECTED_NODE_NAME="REPLACEMENT_K3S_NODE_NAME"

   bash deployment/dr/restore.sh dev k3s-vm "$BACKUP" "$AGE_IDENTITY" prepare
   bash deployment/dr/restore.sh dev k3s-vm "$BACKUP" "$AGE_IDENTITY" secrets
   bash deployment/dr/restore.sh dev k3s-vm "$BACKUP" "$AGE_IDENTITY" volumes
   ```

   `prepare` creates the namespace and four PVCs; `secrets` reinstalls the
   saved PostgreSQL/Grafana credentials; `volumes` restores files into
   **empty** PVCs. The script refuses to replace nonempty file volumes.
   A temporary BusyBox Pod creates/binds each fresh local-path PVC and checks
   emptiness, then is removed. The actual data transfer/extraction takes
   place via `sudo -n tar` over SSH directly on the replacement node, not
   through a long `kubectl exec` stream. This requires the expected k3s
   local-path provisioner directories and passwordless `sudo tar` access.
   All files are checked against SHA-256 digests before any stage. The
   helper image uses BusyBox 1.36; ensure the cluster can pull it.

3. **Start PostgreSQL alone** on the new VM. The checkout must match the
   recorded revision (for prod, the approved `production` revision):

   ```bash
   cd ~/german-job-market-analytics
   sudo k3s kubectl -n dev apply -f deployment/kubernetes/base/postgres.yaml
   sudo k3s kubectl -n dev rollout status deployment/postgres --timeout=180s
   ```

   Then restore PostgreSQL from the workstation:

   ```bash
   bash deployment/dr/restore.sh dev k3s-vm "$BACKUP" "$AGE_IDENTITY" postgres
   ```

   The restore verifies the `pg_restore` table of contents, then uses
   `--clean --if-exists --exit-on-error --single-transaction`. Existing
   PostgreSQL schema and rows **will be overwritten**. This is not an
   incremental merge. The dump captures only `job_market`, not server-global
   roles beyond the initial container user. Same PostgreSQL major version
   (17) is the safest recovery target.

4. **Deploy application** on the VM from the chosen recorded Git revision:

   ```bash
   sudo k3s kubectl apply -k deployment/kubernetes/overlays/dev
   sudo k3s kubectl -n dev rollout status deployment/backend --timeout=600s
   sudo k3s kubectl -n dev rollout status deployment/airflow --timeout=600s
   ```

   For prod, use the `production` checkout/overlay and `prod` namespace.
   Airflow SQLite and Grafana data were restored *before* their Pods start.
   In a new cluster, install/restore Argo CD separately as per
   [Argo bootstrap](../deployment/argocd/README.md), **after** validating recovered
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
   Do not trigger an unnecessary `deployment/scripts/init_airflow.sh` initial import before
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
`deployment/kubernetes/overlays/dev/kustomization.yaml` or `.../prod/kustomization.yaml`
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
3. Validate `kubectl kustomize deployment/kubernetes/overlays/<env>` and CI tests,
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

- Each backup automatically verifies encrypted-file checksums, archive
  decryption, PostgreSQL dump parsing and compressed-tar validity.
  `DR_TEST_DB_RESTORE=1` additionally checks a true restore to a disposable
  local PostgreSQL container. Neither check reconstructs a failed VM.
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
