# k3s configuration with Ansible

This playbook configures the **existing** Ubuntu VM (`group3-ubuntu01`, `10.10.10.20`), **not** the shared Proxmox host. It provides a repeatable installation/configuration procedure for a single-node k3s cluster.

## Current tested setup (November 2026)

- The VM runs Ubuntu 24.04, with **4 vCPUs, approximately 16 GB RAM, and a 30 GB virtual disk**.
- k3s `v1.36.5+k3s1` was **initially installed manually** and has been verified `Ready`.
- The Ansible playbook was subsequently run **locally on the Proxmox VM** through its console.
- A local inventory worked and the live run completed without failures.
- Repeated live runs reported **`changed=0`, `failed=0`** (idempotency verified).
- The `dev` and `prod` namespaces are created/maintained by `files/namespaces.yaml`.

We did **not** test a fresh k3s installation with Ansible. The installer branch of the playbook remains unverified on a clean VM.

## What the playbook does

- Confirms the target is Ubuntu on amd64.
- Installs **k3s v1.36.5+k3s1** only if `/usr/local/bin/k3s` is absent.
- Ensures the k3s systemd service is enabled and running, without restarting an already-running service.
- Waits for the Kubernetes node to be Ready.
- Applies declarative manifests for the `dev` and `prod` namespaces.
- Displays the Kubernetes node status.

Existing k3s installations are **not reinstalled or upgraded**. The version setting pins only *new* installations. The installer is downloaded from the official k3s endpoint; review it before executing on any fresh machine.

The playbook does not manage Proxmox host networking or storage, create VMs, deploy the Job Market Analytics application, or configure Kubernetes ingress.

## Run locally on the existing Proxmox VM (tested approach)

The VM's `10.10.10.20` address is on a private network **not directly reachable from our Ubuntu WSL environment**. Therefore our tested approach runs Ansible on the VM itself using `ansible_connection=local`, without SSH.

Open **Proxmox Web UI → Ubuntu VM → Console** (or log into the VM through another approved method), and use the `group3` account with sudo privileges.

Install prerequisites if not already present:

```bash
sudo apt update
sudo apt install -y ansible git
```

Use the current merged `main` branch of the existing clone:

```bash
cd ~/german-job-market-analytics
git switch main
git pull origin main
cd infrastructure/ansible
```

If the repository has not yet been cloned, clone it first from GitHub.

Create a **local, Git-ignored** inventory (`inventory.ini`):

```bash
printf '[k3s_servers]\nlocalhost ansible_connection=local ansible_python_interpreter=/usr/bin/python3\n' > inventory.ini
```

Run the connection check and optional preliminary dry run:

```bash
ansible -i inventory.ini k3s_servers -m ping
ansible-playbook -i inventory.ini install-k3s.yml --check --diff --ask-become-pass
```

Run the playbook:

```bash
ansible-playbook -i inventory.ini install-k3s.yml --ask-become-pass
```

The `--ask-become-pass` flag prompts for the Ubuntu user's sudo password on every invocation. If sudo authentication is already cached, the playbook also works without the flag:

```bash
ansible-playbook -i inventory.ini install-k3s.yml
```

If that command fails because a sudo password is required, rerun with `--ask-become-pass`. We did **not** enable passwordless sudo; the `group3` account has ordinary sudo permissions. Do not change sudo policies for convenience.

**Check mode limitation:** Command tasks cannot fully simulate a fresh installation, and some are skipped in check mode. The important checks are the first real execution and a repeat execution that should report `changed=0` when the system has not drifted.

Verify the cluster afterward:

```bash
sudo k3s kubectl get nodes
sudo k3s kubectl get namespaces
```

## Optional remote execution (not tested from WSL)

`inventory.example.ini` contains the intended SSH inventory for remote Ansible execution. Use it **only if** Liora provides an approved VPN, route, or SSH gateway to the VM's private network. A working Proxmox browser console and outbound internet access **do not** imply that WSL can directly SSH to `10.10.10.20`.

Do not expose SSH ports on the shared Proxmox host or change host-level networking to work around this limitation.

## Safety and scope

- Target only this project's Ubuntu VM, never another group's VM or the Proxmox host.
- Keep `inventory.ini`, private SSH keys, credentials, and kubeconfigs out of Git.
- This playbook manages k3s installation/service health and namespaces; it is **not** a complete backup, disaster recovery, or Kubernetes application deployment solution.
