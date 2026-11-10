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
- A separate isolated `~/terraform-smoke-test` directory was used to create **empty VM 101** using `terraform apply`. Creation succeeded after granting a narrowly scoped token ACL on `/vms/101`, and that temporary VM was subsequently deleted. **VM creation and destruction are therefore tested, but this new Ubuntu cloud-image configuration has NOT been applied or validated yet.**
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

The already available `ubuntu-24.04.5-live-server-amd64.iso` is an **interactive installation ISO**, **not** a Cloud-Init image. At the last check, no image appeared under `pvesm list local --content import`.

**Option A — pre-stage an official image (recommended for current restricted token):**

1. Ask an authorized Proxmox operator to stage the official Ubuntu 24.04 amd64 cloud-image QCOW2 on the already approved `local` datastore as `local:import/job-market-noble-server-cloudimg-amd64.qcow2`. The source image is `https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img`; use a pinned version and verify its official checksum for a fully reproducible setup.
2. Confirm the imported file exists (e.g. `pvesm list local --content import` on the Proxmox host). The `local` storage must allow **Import** content; it appeared enabled in the storage summary.
3. Keep `download_cloud_image = false` and set `cloud_image_file_id` to the actual Proxmox image ID. Terraform uses the staged file without uploading a snippet or requiring host SSH from WSL.

**Option B — Terraform downloads the official image:**

Set `download_cloud_image = true` so Terraform manages `proxmox_virtual_environment_download_file.ubuntu_cloud_image`. The download uses Proxmox's `download-url` API and the storage's **Import** content type. It requires additional storage and node privileges (including `Datastore.AllocateTemplate`, `Sys.Audit`, and `Sys.Modify`) beyond the narrowly scoped VM 101 ACL. **Do not grant broad permissions or change shared host settings without Liora's approval.** The managed image may be removed from storage on a subsequent `terraform destroy`.

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

   The token has already been shown to create an empty VM 101; **disk import, Cloud-Init initialization and boot require additional permissions and have not been tested**. A failure should be investigated, not bypassed with global administrator privileges.

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
