# Ansible: install and configure k3s

`install-k3s.yml` configures an Ubuntu VM as a single-node **k3s Kubernetes cluster**. Terraform provisions the VM; Ansible installs/configures k3s and applies the `dev` and `prod` namespaces.

See the [infrastructure guide](../README.md) for Proxmox, Terraform and restricted SSH gateway configuration.

## What the playbook does

- Verifies the target is Ubuntu on x86-64.
- Installs the pinned k3s version if `/usr/local/bin/k3s` is not present.
- Enables and starts the `k3s` systemd service.
- Waits until all Kubernetes nodes report `Ready`.
- Copies `files/namespaces.yaml` and applies the `dev` and `prod` namespaces.
- Reports the node status.

The playbook does **not** deploy the Job Market application, configure ingress or provision persistent storage. An existing k3s installation is left in place; the playbook does not upgrade it.

## Prerequisites

- An Ubuntu VM with Python 3 and a user able to run `sudo`.
- Ansible and OpenSSH installed on the control machine (for example, Linux or WSL).
- SSH access to the VM, optionally through an authorized Proxmox jump host.
- A verified SSH host key and the corresponding public-key authorization on the gateway and guest.

The example VM uses private IP `10.10.10.20` and Ubuntu user `group3`. Adjust these to match your own environment.

## Configure SSH access

If the VM is only reachable through the Proxmox host, configure the control machine's `~/.ssh/config`:

```sshconfig
Host liora-proxmox
    HostName PROXMOX_HOST
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

Replace `PROXMOX_HOST` with the actual gateway and adapt the VM IP/user if needed. The gateway user (`jumpuser`) and Ubuntu guest user (`group3`) are separate accounts.

Check connectivity:

```bash
chmod 600 ~/.ssh/config
ssh liora-vm100
```

If SSH reports `administratively prohibited`, the gateway is denying forwarding to the requested VM IP/port. Verify its permitted destination with the authorized administrator. Do not disable the forwarding restriction.

## Run from the control machine

From the repository root:

```bash
cd infrastructure/ansible
cp inventory.example.ini inventory.ini
```

Edit `inventory.ini` to use the SSH alias:

```ini
[k3s_servers]
liora-vm100 ansible_connection=ssh ansible_python_interpreter=/usr/bin/python3
```

Then run:

```bash
ansible -i inventory.ini k3s_servers -m ping
ansible-playbook -i inventory.ini install-k3s.yml --ask-become-pass
```

The `--ask-become-pass` option prompts for the **guest's sudo password**, not a Proxmox API token. The inventory file is ignored by Git; do not commit credentials or private keys.

For a complete Terraform and Ansible execution, use the root [`deploy.sh`](../../deploy.sh). The deployment script creates an inventory based on Terraform outputs.

## Verify Kubernetes

On the guest VM:

```bash
sudo k3s kubectl get nodes -o wide
sudo k3s kubectl get namespaces
```

The node should be `Ready` and the `dev` and `prod` namespaces should exist.

To check idempotency, rerun the Ansible playbook. Existing installations should not be reinstalled, and unchanged namespace configuration should not report modifications.

## Security and limits

- Use the private VM IP, not the shared Proxmox host, as the Ansible target.
- Keep SSH gateway port forwarding restricted to the authorized VM.
- Verify new SSH host fingerprints after VM re-creation before updating `known_hosts`.
- Maintain backups of persistent Kubernetes data separately.
- A single-node cluster does not provide high availability.
