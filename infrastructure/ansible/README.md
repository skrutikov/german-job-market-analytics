# k3s configuration with Ansible

This playbook configures the **existing** Ubuntu VM (`group3-ubuntu01`, `10.10.10.20`), **not** the shared Proxmox host. It provides a repeatable installation/configuration procedure for a single-node k3s cluster.

## Current tested setup (November 2026)

- The manually provisioned **VM 100** (`group3-ubuntu01`, `10.10.10.20`) runs Ubuntu 24.04.5 LTS, with 4 vCPUs, approximately 16 GB RAM, and a 30 GB virtual disk.
- k3s `v1.36.5+k3s1` was **initially installed manually**. Kubernetes reports the single control-plane node as **Ready**.
- The playbook was first run **locally on VM 100** and repeated without changes.
- **Verified on 11 November 2026:** the same playbook also ran **remotely from Ubuntu WSL** via the then-configured `group3jump` SSH gateway account on the Proxmox host. The remote run completed with `ok=10 changed=0 unreachable=0 failed=0 skipped=2`. The current `deploy.sh` instead defaults to `jumpuser`; on 14 November, forwarding to **10.10.10.21:22** worked but forwarding to the desired **10.10.10.20:22** was refused.
- The two skipped tasks were the fresh-host installer download and installation, because k3s was already present.
- The `dev` and `prod` namespaces are maintained by `files/namespaces.yaml`.

**Not yet tested:** installing k3s via this playbook on a clean Terraform-provisioned VM. A successful no-change run against VM 100 verifies remote access and repeatability, not the fresh-install path.

## What the playbook does

- Confirms the target is Ubuntu on amd64.
- Installs **k3s v1.36.5+k3s1** only if `/usr/local/bin/k3s` is absent.
- Ensures the k3s systemd service is enabled and running, without restarting an already-running service.
- Waits for the Kubernetes node to be Ready.
- Applies declarative manifests for the `dev` and `prod` namespaces.
- Displays the Kubernetes node status.

Existing k3s installations are **not reinstalled or upgraded**. The version setting pins only *new* installations. The installer is downloaded from the official k3s endpoint; review it before executing on any fresh machine.

The playbook does not manage Proxmox host networking or storage, create VMs, deploy the Job Market Analytics application, or configure Kubernetes ingress.

## Run remotely from WSL through Proxmox

The private VM address `10.10.10.20` is not directly reachable from WSL. For the **current configuration**, Ansible runs on WSL through the instructor-approved Proxmox SSH gateway account named `jumpuser`:

```text
WSL (Ansible controller) -> Proxmox (jumpuser) -> VM 100 (group3@10.10.10.20)
```

`jumpuser` is the **Proxmox gateway account**; `group3` is the **Ubuntu guest account**. Neither is the Proxmox web/API identity `root1@pve`. The gateway account does not require sudo privileges. The private SSH key stays on WSL; its corresponding public key must be authorized on the gateway and guest. The Proxmox SSH host key was previously verified against the trusted web console. The 11 November remote Ansible run used the older gateway account `group3jump`, not `jumpuser`.

On **WSL** (`root@Seryoga-MC`), configure `~/.ssh/config`:

```sshconfig
Host liora-proxmox
    HostName 195.154.103.231
    User jumpuser
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes

Host liora-vm100
    HostName 10.10.10.20
    User group3
    ProxyJump liora-proxmox
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
```

Then:

```bash
chmod 600 ~/.ssh/config
ssh liora-vm100                   # Verify access before running Ansible
# If the guest key is not yet authorized, while password SSH is available:
# ssh-copy-id -i ~/.ssh/id_ed25519.pub liora-vm100
```

After the guest is configured for public-key authentication, create the **Git-ignored** `inventory.ini` on WSL:

```bash
cd ~/german-job-market-analytics/infrastructure/ansible
cat > inventory.ini <<'EOF'
[k3s_servers]
liora-vm100 ansible_connection=ssh ansible_python_interpreter=/usr/bin/python3
EOF

ansible -i inventory.ini k3s_servers -m ping
ansible-playbook -i inventory.ini install-k3s.yml --ask-become-pass
```

The playbook asks for `group3`'s **sudo password** (become), not the Proxmox API token. The **historical 11 November run via `group3jump`** ended with:

```text
PLAY RECAP
liora-vm100 : ok=10 changed=0 unreachable=0 failed=0 skipped=2
```

Its node report showed `group3-ubuntu01 Ready control-plane`, internal IP `10.10.10.20`, and k3s `v1.36.5+k3s1`. Ansible is not installed on the guest for this remote approach; the Ansible controller is WSL.

**Gateway scope:** On 14 November, `jumpuser` allowed a connection to `10.10.10.21:22` but refused `10.10.10.20:22`. The `jumpuser` public key must be permitted to forward **only** to the approved replacement VM destination `10.10.10.20:22` (for example with `restrict,port-forwarding,permitopen="10.10.10.20:22"` in its `authorized_keys` entry). The gateway can serve a rebuilt VM at the same IP, but cannot automatically reach a different VM/IP. Keep the approved forwarding restrictions in place.

**Troubleshooting `administratively prohibited`:** if `ssh liora-vm100` reports `channel 0: open failed: administratively prohibited: open failed`, the SSH gateway accepted the key but **refused the TCP forwarding request before reaching the guest**. First check the WSL SSH config: `liora-proxmox` must use `jumpuser`, while `liora-vm100` must use `group3`. An authorized administrator can then check `/home/jumpuser/.ssh/authorized_keys` for the correct key and exact `permitopen="10.10.10.20:22"` destination, along with the effective SSH server `AllowTcpForwarding` / `PermitOpen` restrictions. Do not weaken forwarding restrictions or modify shared-host settings without instructor approval. See [infrastructure SSH jump setup](../README.md#create-the-ssh-jump-account).

**Before replacing VM 100:** follow the [VM 100 replacement runbook](../VM100_REBUILD.md) for backups, the old VM's removal, Terraform state and SSH gateway restrictions. **Do not confuse VM 101 at .21 with VM 100 at .20.**

**After intentionally replacing VM 100:** ensure Cloud-Init creates `group3` with the WSL public key. A rebuilt guest will have a *new SSH host key*; verify its fingerprint through the trusted Proxmox console and then update the old guest entry in WSL `known_hosts` rather than blindly ignoring host-key warnings. Back up the existing VM and confirm its replacement is approved before any deletion.

## Earlier local execution on VM 100 (also tested)

Before the SSH gateway was configured, the VM's private IP was unreachable directly from WSL. We therefore ran Ansible **inside VM 100** using `ansible_connection=local`.

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

## Inventory example and network precautions

The checked-in `inventory.example.ini` shows the target VM's address and user. When using the SSH aliases above, the local `inventory.ini` example in the **remote execution** section is sufficient; never commit host passwords, SSH private keys, or API tokens.

The shared Proxmox host must only be used as the **approved SSH jump gateway**. Keep any key-level forwarding rules limited to authorized guest addresses and ports; do not broaden access to the shared server or other groups' VMs.

## Safety and scope

- Target only this project's Ubuntu VM, never another group's VM or the Proxmox host.
- Keep `inventory.ini`, private SSH keys, credentials, and kubeconfigs out of Git.
- This playbook manages k3s installation/service health and namespaces; it is **not** a complete backup, disaster recovery, or Kubernetes application deployment solution.
