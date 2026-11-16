# Trivy security scans

This milestone introduces automated **Trivy** checks for Python dependencies,
secrets, infrastructure configuration and both locally built container images.
This runs in **GitHub Actions**, not in the Proxmox VM or its k3s workloads.

## What gets scanned

| Job | Input | Issues checked |
|---|---|---|
| `Source, secrets and IaC` | Repository filesystem | Known package vulnerabilities, exposed secrets, and misconfigurations in Dockerfiles, Kubernetes, Terraform, etc. |
| `Container - application` | Image rebuilt from `Dockerfile` | OS and installed Python package vulnerabilities |
| `Container - airflow` | Image rebuilt from `airflow/Dockerfile` | OS and installed Python package vulnerabilities |

The filesystem scan alone is **not** sufficient to determine the exact
installed package versions: `requirements.txt` uses compatible version ranges.
The **container scans** inspect the packages actually installed by each image
build. All images are built on the GitHub runner and are **not pushed or deployed**
by this workflow.

The Airflow Dockerfile has also been updated from `apache/airflow:3.3.0`
to the officially released `3.4.0` base after the first Trivy scan reported
multiple fixable CRITICAL dependency findings in the old image. The image
CI includes a basic `airflow version` and Python import smoke check. This
is **not** a live Airflow upgrade: the running k3s Pods continue using their
existing images until a separate rollout. Airflow 3.4.0 changes its metadata
database/XCom schema, so back up the Airflow state PVC and test the DAG
before replacing the live image; downgrading across this release is not
necessarily trivial. See the [Airflow 3.4.0 release notes](https://airflow.apache.org/docs/apache-airflow/3.4.0/release_notes.html).

The new `.dockerignore` prevents Git metadata, local environments, common
private key formats and Terraform state from being copied by `Dockerfile`'s
`COPY . .`. It does not replace correct secret management; do not put real
credentials in source-controlled files or image build arguments.

## Execution and enforcement

[Security workflow](../.github/workflows/trivy.yml) runs automatically:

- On pull requests targeting `main` (including proposed security changes)
- On pushes to `main` through the existing Kubernetes image pipeline
  (as a **required reusable workflow** before GHCR publication);
  while under development, also directly on `trivy-scanning`
- Weekly on Monday at 06:00 UTC, to catch newly disclosed vulnerabilities
  even when no code has changed
- Manually through **GitHub → Actions → Trivy security scanning → Run workflow**

The workflow uses `aquasecurity/trivy-action@v0.36.0` and explicitly pins
Trivy to `v0.74.0`. Trivy's vulnerability database is fetched/cached by the
action and may change between runs.

**Policy (same for source and images):**

- **HIGH and CRITICAL** findings are collected in machine-readable **SARIF**
  reports, kept as workflow artifacts for **14 days** and uploaded to
  **GitHub → Security → Code scanning** when permitted by the repository.
- The security gate **fails CI** for **CRITICAL** findings for which a fix is
  available (including actionable secret/misconfiguration findings).
  `ignore-unfixed: true` avoids blocking the demonstration on vulnerabilities
  with no released fix; these can still appear in SARIF.
- HIGH findings remain visible but are **not yet a blocking gate**. Review
  them as part of a follow-up hardening phase. Do not silently ignore them.
- A scanner crash/download failure also fails its job. Reports are uploaded
  **before** the enforcing gate, so failures can be investigated afterward.

We do not ship a blanket `.trivyignore`. If a justified exception becomes
necessary, document the advisory ID, affected component, rationale and expiry
date before suppressing it. A green scan is **not** proof that the system is
secure; Trivy only knows published issues and supported checks.

For pull requests from **forks**, GitHub may restrict SARIF uploads due to the
token permission model. The workflow still scans and saves report artifacts;
it skips the Security tab upload when that token cannot be granted. The
repository's default branch must have GitHub code scanning enabled for the
Security tab to show the uploaded reports.

## Review results

In the GitHub repository, go to **Actions → Trivy security scanning**. Open
the latest workflow and inspect:

1. `Source, secrets and IaC`: repository vulnerabilities, secrets, configuration issues.
2. `Container - application`: findings in the runtime FastAPI/Dash image.
3. `Container - airflow`: findings in the Airflow image.

Download the `trivy-*-sarif` artifacts to inspect individual rule IDs, affected
packages, installed/fixed versions and source paths. The Security tab can also
show findings as code scanning alerts (if enabled).

Use the report to distinguish:
- **OS-layer CVEs**: usually require updating the `FROM` image to a patched version and rebuilding.
- **Python dependency CVEs**: update direct constraints or rebuild if a
  transitive dependency is affected; then run the existing tests.
- **Dockerfile/Kubernetes/Terraform issues**: adjust infrastructure manifests
  without leaking secrets or disabling security checks.
- **Secrets**: revoke/rotate any exposed live credential, remove it from
  Git and its history as appropriate; ignoring the detection is not remediation.

For `main`, the [Kubernetes pipeline](../.github/workflows/kubernetes.yml)
**waits for all Trivy jobs to pass** before publishing images to GHCR. This
prevents knowingly publishing a new release after a failed security gate.
The scanner builds images from the reviewed commit, while the separate publish
job rebuilds them; base images and dependency ranges may still change between
those builds, so these are not necessarily identical binaries. Pinning image
digests and exporting immutable release artifacts is a useful future
hardening step.

## Manual local reproduction (optional)

Install a compatible [Trivy](https://trivy.dev/docs/) binary on the
**local machine** and run from the repository root:

```bash
trivy fs --scanners vuln,secret,misconfig --severity HIGH,CRITICAL .
docker build -f Dockerfile -t job-market-trivy-application:local .
trivy image --scanners vuln --severity HIGH,CRITICAL job-market-trivy-application:local
docker build -f airflow/Dockerfile -t job-market-trivy-airflow:local .
trivy image --scanners vuln --severity HIGH,CRITICAL job-market-trivy-airflow:local
```

For the blocking policy, append
`--ignore-unfixed --severity CRITICAL --exit-code 1`.
Do not test by downloading and executing suspicious files or adding real
secrets into the repository.

## Operational scope

Trivy does **not** monitor live Pods, replace Prometheus/Alertmanager, fix
vulnerabilities automatically, or guarantee that the running cluster uses
the exact image bytes examined by CI. The cluster itself, host hardening,
RBAC and externally exposed endpoints need independent reviews.

No Kubernetes deployment manifest or PVC is changed by this feature.
We can merge this branch after its workflow jobs have passed and the
reporting behavior has been checked.
