# Dev → production promotion (GitOps)

This runbook implements Liora's requirement to **deploy dev automatically** and
deploy a **stable production release only after approval**. It uses the existing
single-node Proxmox/k3s environment; no Kubernetes cluster or additional VM
is created. The two complete application stacks may run concurrently only
while VM CPU, RAM and disk capacity permit.

## Architecture and trust boundaries

\`\`\`text
feature PR → main → CI manifest/tests + Trivy security gate
                            ↓
                 build and publish *both* GHCR images
                 tagged sha-<full source commit SHA>
                            ↓
                 CI writes dev image tags to main
                            ↓
                 Argo CD job-market-dev (tracks main)
                            ↓
           operator checks dev Synced/Healthy and ETL
                            ↓
 GitHub Actions "Promote tested dev release to production"
      → explicit candidate SHA + notes + typed PROMOTE
      → GitHub Environment production reviewer approval
                            ↓
     workflow merges approved main into production branch
     and pins both prod images to the selected dev SHA
                            ↓
           Argo CD job-market-prod (tracks production)
                            ↓
               stable production rollout
\`\`\`

**Critical isolation:** The production Application watches \`production\`, NOT
\`main\`. A normal merge to \`main\`, including changes to Kubernetes base
manifests, does not alter the deployed production manifests. The promotion
workflow is the only *intended* writer to \`production\`; configure repository
branch rules to restrict unauthorized direct pushes to that branch as well.

All GHCR application and Airflow image tags in both overlays use the
**same immutable** \`sha-<40-character commit SHA>\` within one environment.
The two environments can be on different releases. Shared third-party
images are managed separately by the base manifests.

The CI GitHub Actions runner cannot contact the private Proxmox VM. Argo CD
pulls Git directly inside k3s; GitHub Actions never connects to the cluster.

## One-time GitHub configuration (required before the first promotion)

1. Under **Settings → Environments**, create an environment named exactly
   \`production\`. Configure **required reviewers** (choose the authorized
   approver) and, if appropriate, prevent self-review. This is the human
   **approval gate**. **Merely declaring \`environment: production\` in the YAML
   does NOT enforce independent approval until required reviewers are
   configured.** Repository plan and visibility must support this protection.
2. In **Settings → Actions → General**, allow the workflow's
   \`GITHUB_TOKEN\` the necessary \`contents: write\` permission for its
   release-update jobs; ensure repository rules permit the bot to write its
   dev image-tag commit to \`main\` and the approved release commit to
   \`production\`. The workflows grant write permission only to those jobs.
   If branch protection prevents these pushes, use a narrowly scoped bot
   bypass or PR-based alternative instead of disabling protection broadly.
3. Protect the **\`production\` branch** with a rule/ruleset requiring approval
   or restricting direct updates to the trusted promotion automation. This
   prevents someone with repository push access bypassing the environment
   gate via an ordinary push to \`production\`. Configure the rule **before
   first production use**, or immediately after the first approved creation,
   depending on available branch rules.
4. The two GHCR packages must be pullable by k3s (public or via a namespace
   imagePullSecret). Do not save registry credentials or VM SSH keys in Git.
5. GitHub Actions workflows must be enabled. On the initial merge, the dev
   release job may fail if branch rules block its \`main\` commit; fix the
   repository permission and rerun the failed workflow (no VM changes are
   required).

## Normal dev delivery

1. Merge a tested feature PR into \`main\`.
2. **Kubernetes manifests and images** CI validates overlays, tests the
   tag utility, runs Trivy, and publishes both packages to GHCR.
3. Only after both packages publish, the \`update_dev_gitops\` job writes
   \`sha-<published commit>\` into
   \`deployment/kubernetes/overlays/dev/kustomization.yaml\` on \`main\`.
   It skips stale runs if another commit has already reached \`main\`.
   The generated commit uses \`GITHUB_TOKEN\` and does not start another
   GitHub Actions run. Argo CD still observes the Git change.
4. Argo CD auto-synchronizes \`dev\`. On the **Ubuntu VM**, verify:

   \`\`\`bash
   sudo k3s kubectl -n argocd get application job-market-dev
   sudo k3s kubectl -n dev get pods
   sudo k3s kubectl -n dev get deployment/backend deployment/airflow \\
     -o jsonpath='{range .items[*]}{.metadata.name}={.spec.template.spec.containers[0].image}{"\\n"}{end}'
   sudo k3s kubectl -n dev rollout status deployment/backend
   sudo k3s kubectl -n dev rollout status deployment/airflow
   \`\`\`

   Check that Argo CD reports **Synced/Healthy**, the expected \`sha-...\`
   appears in the running Deployments, and application / ETL smoke tests
   succeed. The CI cannot independently verify runtime health inside this
   private VM. Record a concise result or workflow/UI link for approval.

## Approve and promote to production

1. Go to **GitHub → Actions → Promote tested dev release to production**.
2. Click **Run workflow** on branch \`main\` and supply:
   - \`release_sha\`: **full 40-character** SHA from the current dev overlay
     tag, without the \`sha-\` prefix;
   - \`dev_verification\`: a meaningful note/link recording the dev checks;
   - \`confirmation\`: literally \`PROMOTE\`.
3. The preflight job verifies that both images in the current dev overlay
   have that exact SHA. The promotion job then pauses for required approval
   in the GitHub \`production\` environment. An authorized reviewer checks
   the dev evidence and explicitly approves it.
4. After approval, the job **rechecks** the current dev release (rejecting a
   stale request), merges \`main\` into the independent \`production\` branch,
   sets the production overlay to the same tested image tag, validates the
   rendered prod manifests, and pushes only to \`production\`. On first
   use, the workflow creates the branch. No production resources exist
   until you bootstrap them on the VM.

### One-time production cluster bootstrap

After the **first approved promotion**, on the **Ubuntu VM**, with the
usual \`main\` checkout:

\`\`\`bash
cd ~/german-job-market-analytics
git switch main
git pull --ff-only
bash deployment/argocd/bootstrap-prod.sh
\`\`\`

This script fetches \`production\`, deploys that branch's prod overlay with
**separate Secrets and PVCs**, protects the six live prod PVCs against
automatic pruning, then registers \`job-market-prod\` in Argo CD. It uses a
temporary \`git archive\`, leaving the main checkout unchanged. The script
does not recreate the VM and does not touch \`dev\`.

**Subsequent promotions are automatic from Argo CD's perspective:** after
human approval the Git branch advances, and prod auto-syncs. Verify:

\`\`\`bash
sudo k3s kubectl -n argocd get application job-market-prod
sudo k3s kubectl -n prod get deployments,pods,pvc
sudo k3s kubectl -n prod get deployment/backend deployment/airflow \\
  -o jsonpath='{range .items[*]}{.metadata.name}={.spec.template.spec.containers[0].image}{"\\n"}{end}'
\`\`\`

Use \`./kubernetes_start.sh prod\` from the **local machine** to open the
existing protected browser tunnels. Keep load tests and dev/prod Airflow
extractions from overlapping until resource usage is understood.

## Rollback, failure and safety

- **If dev publication or tag update fails:** Argo CD retains the previous
  dev image tag; fix CI and rerun. Published images are not directly
  deployed just because the mutable \`:main\` tag changed.
- **If approval is rejected:** the production Git branch does not move.
  If a new dev release appeared during review, the promotion action rejects
  the stale candidate; run a fresh approval with current dev evidence.
- **If a production image is unhealthy:** revert the \`production\` branch to
  a previous **approved** release via a reviewed change or re-promote an
  earlier image using a controlled procedure. Never delete PVCs to undo an
  application release. The usual promotion workflow intentionally permits
  only the *current* dev candidate, so rollback to an older release needs
  a separate explicit operator change and review.
- **Rollback of images does NOT roll back database migrations or data.**
  Keep database and stateful-volume backups outside the VM and test
  restoration. This workflow is not a disaster-recovery solution.
- The sample uses local-path PVCs, Airflow standalone/SQLite and private
  HTTP Ingress. It is a **lab demonstration**, not a publicly accessible,
  highly available production deployment.
