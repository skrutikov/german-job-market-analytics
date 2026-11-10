# Ubuntu infrastructure on Proxmox with Terraform

This directory contains Infrastructure as Code for the Job Market Analytics project.
It now describes **a real Ubuntu 24.04 cloud-image VM**, not a template clone.
**Provisioning is disabled by default:** `create_vm = false`. This is for a **new** VM (initial test target: 101), not the working VM 100.

## Existing environment and what has been tested (November 2026)

- Existing VM **100**, created manually, runs Ubuntu 24.04, k3s, and the `dev`/`prod` namespaces. Its private address is `10.10.10.20/24`.
- VM 100: **4 vCPUs, 16384 MiB RAM, 30 GiB QCOW2 virtual disk**, on Proxmox storage `local` (disk file actually occupied about **8.8 GiB** when checked).
- VM 100 uses `nat0`, gateway `10.10.10.1`, DNS `1.1.1.1` and `8.8.8.8`. Node: `B2C-DevOps-Inter-Bootcamp-SEP26-group-5`.
- The `local` datastore had about **63.06 GB total / 18.38 GB used** at the last check. That is shared capacity, **not an allocation for this group**.
- `terraform init`, `terraform fmt -check` and `terraform validate` previously passed for the **original scaffold** with Terraform v1.17.1 and `bpg/proxmox v0.120.0`.
- HTTPS/TLS with `/etc/pve/pve-root-ca.pem`, API-token authentication (HTTP 200), and **read-only Terraform API data-source access** were verified.
- An isolated `~/terraform-smoke-test` directory successfully created and destroyed an **empty VM 101**. Subsequently, using **this repository's Terraform configuration**, we successfully provisioned **VM 101 with an Ubuntu Cloud Image and Cloud-Init** (`Apply complete! Resources: 1 added, 0 changed, 0 destroyed`). The Proxmox console displayed **Ubuntu 24.04.5 LTS** at the login prompt. Guest SSH, static IP, and full Cloud-Init completion have **not yet been verified from inside the VM**.
- The Ansible playbook in `../ansible/` has been run locally on VM 100 and was idempotent on repeated runs. **A fresh k3s installation using Ansible has not yet been tested.**

## What this configuration creates

When explicitly enabled, Terraform provisions a **separate Ubuntu VM** from an Ubuntu 24.04 (Noble) cloud image:

- A new VM ID and name (example: `101`, `job-market-ubuntu-101`).
- Configurable virtual CPU model/core count, dedicated RAM, and a QCOW2 `scsi0` disk.
- The approved `local` datastore for disk and Cloud-Init data.
- A VirtIO NIC on `nat0`, with firewall enabled.
- Cloud-Init for **static IPv4, gateway, DNS, Linux username and SSH public key**; no password is stored in Terraform.
- Starts the VM to run Cloud-Init; automatic start on a future Proxmox host boot remains disabled.
- Optional official Ubuntu image download through the Proxmox API, **only when explicitly enabled**.

**What it does not yet do:** install Ansible or k3s inside the new guest, run the existing playbook automatically, deploy the application, or set up direct network access from WSL to the private VM. Those are distinct next automation steps. This repository does **not yet** offer a tested single-command end-to-end rebuild.

The example temporary VM uses **2 vCPUs, 4096 MiB RAM and a 16 GiB virtual disk**. The production-sized existing VM 100 is left untouched. These values are adjustable in `terraform.tfvars`.

## Cloud-image prerequisite: choose one method

The existing `ubuntu-24.04.5-live-server-amd64.iso` is an **installation ISO**, **not** a Cloud Image. We subsequently downloaded and verified the proper Ubuntu Cloud Image on Proxmox; see the setup runbook below.

**Option A — pre-stage an official image (recommended for current restricted token):**

1. Ask an authorized Proxmox operator to stage the official Ubuntu 24.04 amd64 cloud-image QCOW2 on the already approved `local` datastore as `local:import/job-market-noble-server-cloudimg-amd64.qcow2`. The source image is `https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img`; use a pinned version and verify its official checksum for a fully reproducible setup.
2. Confirm the imported file exists (e.g. `pvesm list local --content import` on the Proxmox host). The `local` storage supports **Import** content, as verified in the Proxmox UI and by the successful download.
3. Keep `download_cloud_image = false` and set `cloud_image_file_id` to the actual Proxmox image ID. Terraform uses the staged file without uploading a snippet or requiring host SSH from WSL.

**Option B — Terraform downloads the official image:**

Set `download_cloud_image = true` so Terraform manages `proxmox_download_file.ubuntu_cloud_image`. The download uses Proxmox's `download-url` API and the storage's **Import** content type. It requires additional storage and node privileges (including `Datastore.AllocateTemplate`, `Sys.Audit`, and `Sys.Modify`) beyond the narrowly scoped VM 101 ACL. **Do not grant broad permissions or change shared host settings without Liora's approval.** The managed image may be removed from storage on a subsequent `terraform destroy`.

For the provider's native approach, see the [cloud-image guide](https://bpg.sh/docs/guides/cloud-image/) and [cloud-init guide](https://bpg.sh/docs/guides/cloud-init/).

## Prepare local WSL environment

1. Use the existing Git branch, in `infrastructure/terraform/`. The sample `terraform.tfvars.example` specifies the temporary VM 101; copy it to your Git-ignored local `terraform.tfvars`:

   ```bash
   cp terraform.tfvars.example terraform.tfvars
   ```

2. **Before enabling `create_vm`**, verify that VM ID `101` is still free and approved, and that `10.10.10.21/24` is available and approved. It is only a **proposed** guest address; the working VM 100 uses `10.10.10.20/24`. Confirm group quotas and sufficient space on shared `local` storage.
3. Create/select a local SSH key pair; set `ssh_public_key_path` to the **public** key file on the Terraform client. The example `~/.ssh/id_ed25519.pub` must exist before planning with `create_vm=true`. **Never commit SSH private keys, API tokens or a `terraform.tfvars` containing secrets.**
4. Supply the token and endpoint securely via shell environment variables (do not put them in `.tf` files):

   ```bash
   export PROXMOX_VE_ENDPOINT="https://195.154.103.231:8006/"
   # Set PROXMOX_VE_API_TOKEN securely in your local shell (do not echo it).
   ```

   Use the **authentic, verified** Proxmox CA certificate already accessible from WSL as `/etc/pve/pve-root-ca.pem`:

   ```bash
   export SSL_CERT_FILE=/etc/pve/pve-root-ca.pem
   ```

5. With `create_vm = false`, test the local configuration without provisioning:

   ```bash
   terraform init
   terraform fmt -check
   terraform validate
   terraform plan
   ```

6. Once the image, resource quotas, IP and permissions are verified, set `create_vm = true` in your **local** `terraform.tfvars`, inspect `terraform plan`, and only then consider `terraform apply`.

   The token has successfully created a disk-backed Ubuntu VM 101 after VM, datastore and SDN permissions were configured. The VM booted to the Ubuntu console login prompt; **we have not yet verified Cloud-Init from inside the guest or installed k3s on the new VM**. Do not bypass permission failures with global administrator privileges.

## Proxmox-side setup actually performed (Web UI and host shell)

The procedures below document the **successful November 2026 provisioning of Ubuntu VM 101**. The Proxmox host is shared: keep all changes scoped to the instructor-authorized VM, datastore and network.

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

## Bootstrapping k3s with Ansible (next milestone)

The existing `../ansible/install-k3s.yml` playbook installs k3s on a fresh Ubuntu host and maintains `dev`/`prod` namespaces. Repeated runs on the existing VM were idempotent, but its fresh-install branch is untested.

Because WSL cannot directly reach `10.10.10.0/24`, Ansible has so far been invoked **inside** the Ubuntu VM with local inventory. After VM 101 boots and Cloud-Init finishes, verify private networking and use the VM console/approved access method to run the playbook locally. Only then can we claim that a full fresh provisioning + configuration has been tested.

**One-command deployment is a future improvement:** it needs an approved way to deliver/run the playbook in the guest (such as an authorized SSH jump host, or custom Cloud-Init snippets). Custom snippets require `Snippets` storage support and provider SFTP/SSH access to the Proxmox node; that is **not configured** on the current shared storage. Do not enable it without approval.

## Cleanup and safety

- VM 100 is **not imported or managed**. The new VM resource rejects VM ID `100` and the existing IP `10.10.10.20/24`.
- Use a **separate state** from `~/terraform-smoke-test`. Never mix two independently managed resources targeting the same VM ID.
- Review `terraform plan -destroy` before `terraform destroy`: only resources managed by this new configuration (including its optional downloaded image) should be removed. Keep the matching `terraform.tfstate` until cleanup is verified.
- Do not modify the Proxmox host's network, storage configuration, firewall rules, permissions for another group or existing VM 100.
- Physical free space and group quotas are different; reconfirm available storage before creating even thin-provisioned disks.
- Terraform state may contain sensitive infrastructure details. For collaborative work, agree on secure remote state and state locking.
- Kubernetes manifests, CI/CD and application data backups are separate tasks.
