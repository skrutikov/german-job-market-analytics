# Ubuntu infrastructure on Proxmox with Terraform

This directory contains Infrastructure as Code for the Job Market Analytics project.
It now describes **a real Ubuntu 24.04 cloud-image VM**, not a template clone.
**Current target (14 November 2026):** a **NEW Terraform-managed VM 100** at **10.10.10.20/24** with **4 vCPUs, 16,384 MiB RAM and a 30 GiB disk**. The example remains disabled by default (`create_vm = false`). The existing manually created VM 100 is **not managed by Terraform** and must be backed up and removed with authorization before reusing its ID. See [VM 100 rebuild runbook](../VM100_REBUILD.md).

**Historical test (November 2026):** Terraform created a temporary VM 101 from the staged Ubuntu Cloud Image (Ubuntu 24.04.5 booted successfully); that particular test instance was later destroyed. **A VM 101 is visible again in the 14 November Proxmox screenshot**; its present state/ownership must be checked separately. Its Cloud-Init guest networking/SSH authentication and fresh Ansible installation were not verified. The manually provisioned VM 100 continues to run k3s. **Remote Ansible from WSL to VM 100 through an instructor-approved Proxmox SSH gateway is now verified**, with `changed=0` and `failed=0`. See [Ansible README](../ansible/README.md).

**Before any further `terraform apply`:** check `terraform state list` and `terraform plan`, then review whether the local, Git-ignored `terraform.tfvars` still has `create_vm = true`. An enabled configuration with a stale local `terraform.tfvars` can **target VM 101**; a disabled configuration can **plan destruction** of a state-managed VM. The current `deploy.sh` blocks delete/replace plans and expects VM **100** by default. Never rely on the checked-in example as a description of the live state.

## What this configuration creates

When explicitly enabled, Terraform provisions a **separate Ubuntu VM** from an Ubuntu 24.04 (Noble) cloud image:

- A new VM ID and name (current target: `100`, `job-market-ubuntu-100` **only after the original VM 100 is removed**).
- Configurable virtual CPU model/core count, dedicated RAM, and a QCOW2 `scsi0` disk.
- The approved `local` datastore for disk and Cloud-Init data.
- A VirtIO NIC on `nat0`, with firewall enabled.
- Cloud-Init for **static IPv4, gateway, DNS, Linux username and SSH public key**; no password is stored in Terraform.
- Starts the VM to run Cloud-Init; automatic start on a future Proxmox host boot remains disabled.
- Optional official Ubuntu image download through the Proxmox API, **only when explicitly enabled**.

**Terraform by itself** does not install k3s in the guest, invoke Ansible, deploy the app, or provision an SSH gateway. The repository's root `deploy.sh` runs Ansible after Terraform, but the complete fresh-VM chain is **not yet tested**. The **separately configured SSH gateway now allows remote Ansible to VM 100**, but it is not Terraform-managed. This repository does **not yet** offer a tested single-command end-to-end rebuild.

The **current tracked example** uses **4 vCPUs, 16,384 MiB RAM and a 30 GiB disk**, for the new replacement VM 100. Earlier VM 101 tests used 2 vCPUs, 4096 MiB RAM and a 16 GiB disk. The Git-ignored local `terraform.tfvars` must be updated separately before deploying.

## Proxmox-side setup actually performed (Web UI and host shell)

The sections below retain **historical evidence** of the November 2026 VM 101 test, not current values to apply. Follow the [VM 100 rebuild runbook](../VM100_REBUILD.md) for the new target. The Proxmox host is shared: keep all changes scoped to the instructor-authorized VM, datastore and network.

### Inspect the available resources (Proxmox HOST shell)

These are **read-only Proxmox host** commands, not commands for local Ubuntu WSL:

~~~bash
pvesm status
qm list
qm config 100
ip -br addr show nat0
pvesm list local --content iso
pvesm list local --content import
~~~

The existing VM 100 uses a 30 GiB QCOW2 disk on `local` and the `nat0` network, with gateway `10.10.10.1/24`. We checked the disk's physical usage with:

~~~bash
du -h /var/lib/vz/images/100/vm-100-disk-0.qcow2
~~~

It used ~8.8 GiB of host storage at the time. The `local` datastore showed ~63.06 GB total and ~18.38 GB used. **Free server space is not the group's approved quota.** Confirm CPU/RAM/storage and IP allocations with Liora before adding VMs.

### Download the Ubuntu Cloud Image (Proxmox Web UI)

**Done:** select **local → Import → Download from URL**. Verify that **Datacenter → Storage → local** permits **Import** content (do not change shared storage settings without authorization).

- URL: `https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img`
- Destination filename: `job-market-noble-server-cloudimg-amd64.qcow2`

The `.img` source is a QCOW2-formatted Cloud Image. The actual download reported **621284352 bytes (~593 MiB)** and completed successfully.

On the **Proxmox host**, verify:

~~~bash
pvesm list local --content import
~~~

Our actual result was:

~~~text
local:import/job-market-noble-server-cloudimg-amd64.qcow2 qcow2 import 621284352
~~~

Terraform then uses the pre-staged image:

~~~hcl
download_cloud_image = false
cloud_image_file_id  = "local:import/job-market-noble-server-cloudimg-amd64.qcow2"
~~~

This avoids requiring the restricted Terraform token to download files on the Proxmox host. The image remains available for subsequent recreations. For reproducibility, pin a specific Ubuntu image release and verify its official checksum rather than relying indefinitely on the moving `noble/current` URL.

### Optional alternative: let Terraform download the image

Our working setup uses the pre-staged image with `download_cloud_image = false`; **nothing needs to be downloaded again to recreate the VM**. If an authorized operator later wants Terraform to manage the image download as well, set `download_cloud_image = true` to use `proxmox_download_file.ubuntu_cloud_image`. The provider's download-url API requires additional storage and node permissions. We **did not test this alternative**; do not grant broad host permissions on the shared server just for this convenience.

Provider references: [Cloud Image guide](https://bpg.sh/docs/guides/cloud-image/) and [Cloud-Init guide](https://bpg.sh/docs/guides/cloud-init/).

### Proxmox API token and scoped permissions (Web UI)

**Datacenter → Permissions → API Tokens**: token ID `root1@pve!terraform`, with **Privilege Separation = Yes**. Never commit, display or share the token *secret*. With separation enabled, effective rights cannot exceed those of the parent user `root1@pve`.

Under **Datacenter → Permissions → Add → API Token Permission**, the following permissions were needed to provision **VM 101**:

| Path | Token | Role | Why |
| --- | --- | --- | --- |
| `/vms/101` | `root1@pve!terraform` | `PVEVMAdmin` | Allocate, configure, start and delete that VM |
| `/storage/local` | same | `PVEDatastoreUser` | Allow disk / Cloud-Init allocation (`Datastore.AllocateSpace`) |
| `/sdn/zones/studnat/nat0` | same | `PVESDNUser` | Allow NIC use of the existing VNet (`SDN.Use`) |

The VM path `/vms/101` can be typed directly, even if the VM does not exist yet. **Do not assign PVEVMAdmin on `/vms` or Administrator on `/`.** Storage rights on `/storage/local` are broader because this datastore is shared, so require the instructor's authorization. Do not grant network administration privileges just to use an existing VNet.

Verify with these **Proxmox HOST** commands:

~~~bash
pveum user token permissions root1@pve terraform
pveum user permissions root1@pve
pveum role list
qm list
~~~

**Important lifecycle trap observed:** destroying VM 101 also removed the token's ACL on `/vms/101`. We had to reassign that ACL before creating VM 101 again. A dedicated resource pool with properly scoped permissions may provide a durable solution for repeated rebuilds; get Liora's permission before adopting it.

### Actual 403 failures and resolutions

| Error | Actual missing privilege / action |
| --- | --- |
| `HTTP 403 Permission check failed` when creating an empty VM | Add approved VM permissions for `/vms/101` |
| `403 (/storage/local, Datastore.AllocateSpace)` | Allow allocation on `local` for the token, with approved `PVEDatastoreUser` |
| `403 (/sdn/zones/studnat/nat0, SDN.Use)` | Permit use of VNet `nat0`, with `PVESDNUser` on the exact VNet path |

These failures were authorization checks, not Terraform syntax problems. Recheck `qm list` after failed creation attempts to ensure no partially created VM exists before retrying.

## Local Ubuntu WSL — complete command sequence

These commands run on **local Ubuntu WSL** (`root@Seryoga-MC`), NOT on the Proxmox host or inside VM 100. The older `~/terraform-smoke-test` and this repository have **different Terraform states** and must not be mixed.

### 1. Update the files and validate

~~~bash
cd ~/german-job-market-analytics
git fetch origin
git switch proxmox-deployment
git pull --ff-only origin proxmox-deployment
cd infrastructure/terraform
terraform init
terraform fmt -check
terraform validate
~~~

We tested with Terraform v1.17.1 and `bpg/proxmox v0.120.0`. Validation passed without warnings after the old, deprecated cloud-image resource was replaced with `proxmox_download_file`.

### 2. Set API endpoint, TLS CA and token (per shell session)

We confirmed the Proxmox certificate is issued by its own CA and includes the server IP `195.154.103.231`. Our WSL environment contains a trusted, authentic CA copy at `/etc/pve/pve-root-ca.pem`; verify the CA's authenticity through a trusted channel before use. Do not disable certificate verification or send credentials with `curl -k`.

~~~bash
export PROXMOX_VE_ENDPOINT="https://195.154.103.231:8006/"
export SSL_CERT_FILE=/etc/pve/pve-root-ca.pem

# Read the token secret without displaying it or saving it in shell history:
read -rsp "Proxmox token secret: " TOKEN_SECRET
echo
export PROXMOX_VE_API_TOKEN='root1@pve!terraform='"$TOKEN_SECRET"
unset TOKEN_SECRET
~~~

The **token ID** is `root1@pve!terraform`; the secret is a separate private value. Do not echo, commit, or paste the secret into issue trackers or chat.

A read-only authenticated API check (we received `HTTP status: 200`):

~~~bash
curl --cacert /etc/pve/pve-root-ca.pem \
  --silent --show-error --output /dev/null \
  --write-out 'HTTP status: %{http_code}\n' \
  --header "Authorization: PVEAPIToken=$PROXMOX_VE_API_TOKEN" \
  "$PROXMOX_VE_ENDPOINT"api2/json/nodes
~~~

This confirms API authentication and read access, **not** the permissions needed for VM disks or SDN networks.

### 3. Generate a guest SSH public key (once)

Our WSL root account initially had no key pair, so we ran:

~~~bash
ls -la ~/.ssh/
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -C "liora-terraform"
ls -l ~/.ssh/id_ed25519.pub
~~~

Use a passphrase. The private key `~/.ssh/id_ed25519` (permission `600`) stays private on WSL. Terraform uses the public key `~/.ssh/id_ed25519.pub` (permission `644`) in Cloud-Init. Never commit the private key.

### 4. Configure local variables

~~~bash
cd ~/german-job-market-analytics/infrastructure/terraform
test -f terraform.tfvars || cp terraform.tfvars.example terraform.tfvars
nano terraform.tfvars
~~~

Use these **current replacement VM 100 settings** only *after* the old VM 100 has been backed up and removed, the ID/IP are released, forwarding to `10.10.10.20:22` is authorized, and Terraform state is checked:

~~~hcl
create_vm            = true
node_name            = "B2C-DevOps-Inter-Bootcamp-SEP26-group-5"
vm_id                = 100
vm_name              = "job-market-ubuntu-100"
cpu_cores            = 4
cpu_type             = "x86-64-v2-AES"
memory_mb            = 16384
disk_gb              = 30
datastore_id         = "local"
network_bridge       = "nat0"
vm_ipv4_cidr         = "10.10.10.20/24"
vm_gateway           = "10.10.10.1"
dns_servers          = ["1.1.1.1", "8.8.8.8"]
vm_username          = "group3"
ssh_public_key_path  = "~/.ssh/id_ed25519.pub"
cloud_image_file_id  = "local:import/job-market-noble-server-cloudimg-amd64.qcow2"
~~~

The `create_vm = false` value in the checked-in example is a safety default; set it to `true` in your local `terraform.tfvars` only for the intended creation. VM 101 values below are labeled historical test results, **not active configuration**.

**Before provisioning:** verify that the **old manual VM 100 has been backed up and removed**, its ID/IP are free **and assigned to our group**, and that Liora permits the 4 vCPU/16 GiB/30 GiB allocation. Do not reuse historical VM 101 settings without verifying ownership. An unanswered ping is not proof that an IP is available.

**Critical Terraform state rule:** `terraform.tfvars.example` sets `create_vm = false` to prevent accidental first-time provisioning. If a **live VM is managed by this Terraform state**, keep `create_vm = true` in the local `terraform.tfvars` until you intentionally destroy it; changing to `false` and applying can propose destruction. Conversely, a stale local `terraform.tfvars` may still refer to experimental VM 101; `deploy.sh` now requires planned VM **100** by default and refuses deletion/replacement plans. Always inspect `terraform state list` and `terraform plan` before applying.

### 5. Create and apply an exact reviewed plan

~~~bash
terraform init
terraform fmt -check
terraform validate
terraform plan -out=vm101.tfplan
~~~

Inspect the output: the successful plan had **one VM added**, with boot disk imported from our staged Cloud Image, static networking and a Cloud-Init user account. It showed no changes to existing VM 100:

~~~text
Plan: 1 to add, 0 to change, 0 to destroy.
~~~

After reviewing the plan:

~~~bash
terraform apply vm101.tfplan
~~~

Successful result from our real VM 101 deployment:

~~~text
proxmox_virtual_environment_vm.k3s[0]: Creation complete after 6s [id=101]
Apply complete! Resources: 1 added, 0 changed, 0 destroyed.
managed_vm_id = 101
managed_vm_ipv4 = "10.10.10.21/24"
managed_vm_name = "job-market-ubuntu-101"
ubuntu_image_id = "local:import/job-market-noble-server-cloudimg-amd64.qcow2"
~~~

If a permission error is returned, investigate the **exact Proxmox path and privilege named in the 403**, not the Terraform syntax. Generate a fresh plan after configuration changes. Preserve the Git-ignored `terraform.tfstate` for the lifecycle of the managed VM.

### 6. Verify Ubuntu in Proxmox

Open **VM 101 → Console** in the Proxmox Web UI. We observed:

~~~text
Ubuntu 24.04.5 LTS job-market-ubuntu-101 tty1
job-market-ubuntu-101 login:
~~~

The colored circles on VM 101 are **tags** (not status indicators). Cloud-Init configured user `group3` with **SSH public-key authentication**, but **no console-login password**. The Ubuntu login prompt proves successful boot, not that the private guest IP, SSH key or DNS configuration has been verified inside the VM.

At the time of this VM 101 test, guest SSH/Cloud-Init network access was not validated. **Subsequently**, the instructor approved SSH gateway access, and we verified WSL → Proxmox → **VM 100 at `10.10.10.20`**. That does not retrospectively prove SSH worked on VM 101, which has been destroyed.

## SSH gateway and Ansible: what works today

The historical verified SSH route on 11 November was **WSL → Proxmox `group3jump@195.154.103.231` → VM 100 `group3@10.10.10.20`**, using WSL-held SSH keys. The **current** `deploy.sh` and SSH instructions use the approved gateway account **`jumpuser`**, not `group3jump`; the VM SSH username remains **`group3`**. There is no direct WSL route to the private `10.10.10.0/24` network. The guest host was verified reachable from Proxmox on TCP port 22; the Proxmox host's SSH fingerprint was checked against its trusted browser console.

**Verified on 11 November 2026:** from WSL, `ansible-playbook -i inventory.ini install-k3s.yml --ask-become-pass` completed on VM 100 with `ok=10 changed=0 unreachable=0 failed=0 skipped=2`. Its installed k3s node was `Ready`. The SSH aliases, inventory and full instructions are in the [Ansible README](../ansible/README.md).

The SSH gateway is **configured outside Terraform**, and authorization may restrict port forwarding to `10.10.10.20:22`. **As of 14 November 2026**, authentication as `jumpuser` works; forwarding to **10.10.10.21:22** works, but forwarding to the intended **10.10.10.20:22** was refused with `administratively prohibited`. Thus the historical success via `group3jump` does **not** establish that the current `jumpuser` forwarding is working. Check the gateway key's exact `permitopen` destination and the effective SSH forwarding restrictions, without widening access to other groups' VMs. Recreating **VM 100 at the same private IP** can retain that forwarding destination, but the new guest must authorize our WSL public key via Cloud-Init and will have a new SSH host key.

## Rebuild of the existing VM 100 (configured, not yet performed)

Terraform defaults and example variables now target **VM 100 / 10.10.10.20/24 / 4 vCPUs / 16 GiB RAM / 30 GiB disk**. The goal is to provision a **new** VM 100, then install k3s with Ansible. The old manual VM still exists; this is a destructive replacement and **not a safe immediate apply**. See [the dedicated runbook](../VM100_REBUILD.md):

1. Back up or export all data/configuration that must survive from existing VM 100, including any Kubernetes workloads, secrets, volumes and cluster access needed later.
2. Confirm with the instructor the assigned VM ID `100`, IP `10.10.10.20/24`, permitted CPU/RAM/storage and the maintenance window. **Never attempt to create a second VM with the same ID or IP while the old one exists.**
3. After the existing VM has been intentionally removed, update your **Git-ignored local** `terraform.tfvars` to the tracked example's VM 100 values (Git pull does not change that file), and arrange the **API-token ACL on `/vms/100`**. The old `/vms/101` privilege does not automatically cover it; a VM-specific ACL can disappear when its VM is removed.
4. Confirm Terraform state does not still track another live VM. Generate and review a fresh plan, then apply only the intended VM creation.
5. After Cloud-Init, verify VM 100 has `10.10.10.20` and accepts our WSL SSH key. Verify its **new guest SSH host fingerprint** via a trusted console before adjusting the WSL `known_hosts` entry.
6. Run `../ansible/install-k3s.yml` from WSL through the existing gateway, verify `Ready` and the `dev`/`prod` namespaces, then repeat to check idempotency.

**Still untested:** the Ansible **fresh-install branch** and the complete Terraform → Cloud-Init → Ansible chain. Do not describe the rebuild as one-command or production-ready until it has been exercised end-to-end.

## Cleanup and safety

**Historical note:** the earlier test instance of VM 101 was destroyed after provisioning, although a VM 101 was visible again in the 14 November screenshot. Verify current ownership/state before acting. Before any future cleanup, use `terraform state list` to determine what this repository's current state actually manages. For any **future live Terraform-managed VM**, destroy it **only when you intentionally want to remove it**, and review the full plan first (from WSL with credentials and `SSL_CERT_FILE` available):

~~~bash
cd ~/german-job-market-analytics/infrastructure/terraform
terraform state list
terraform plan -destroy        # Inspection only, not a command to approve blindly
~~~

For any **future Terraform-managed VM 100**, run the guarded `./destroy.sh` from the repository root only with verified backups, authorization, `ALLOW_DESTROY_VM100=true`, and the typed `destroy 100` confirmation. This script cannot remove the old manual VM, which is not in Terraform state.

If using the pre-staged image (`download_cloud_image = false`), the original Cloud Image on `local` is **not** Terraform-managed and remains available for a rebuild. Verify removals with `qm list` on the Proxmox host. Do not delete `terraform.tfstate` until teardown has succeeded; when a VM is intentionally destroyed, its VM-specific token ACL may also be removed, so restoring the ACL for the **next approved VM ID** (or arranging a dedicated permitted pool) may be necessary before recreating it.

- VM 100 is **not imported or managed today**. Its current ID/IP must **not be targeted while the manually provisioned VM exists**. The tracked example now uses the intended replacement values, but your **Git-ignored local `terraform.tfvars`** may still contain the older VM 101 values.
- Use a **separate state** from `~/terraform-smoke-test`. Never mix two independently managed resources targeting the same VM ID.
- Review `terraform plan -destroy` before `terraform destroy`: only resources managed by this new configuration (including its optional downloaded image) should be removed. Keep the matching `terraform.tfstate` until cleanup is verified.
- Keep Proxmox host network, storage and firewall changes within the instructor-approved scope. Do not affect other groups' VMs, and do not alter or destroy existing VM 100 outside the planned replacement.
- Physical free space and group quotas are different; reconfirm available storage before creating even thin-provisioned disks.
- Terraform state may contain sensitive infrastructure details. For collaborative work, agree on secure remote state and state locking.
- Kubernetes manifests, CI/CD and application data backups are separate tasks.
