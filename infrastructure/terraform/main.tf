# Proxmox API credentials come from PROXMOX_VE_ENDPOINT and PROXMOX_VE_API_TOKEN.
# Use a verified Proxmox CA (for example SSL_CERT_FILE=/etc/pve/pve-root-ca.pem).
# This configuration never manages host-level networking. A manually created VM
# with ID 100 must be backed up and REMOVED before Terraform can create VM 100.
provider "proxmox" {}

# NEW Ubuntu 24.04 VM 100 from a QCOW2 cloud image (not a clone).
# create_vm defaults to false. This resource must NOT adopt an existing VM.
resource "proxmox_virtual_environment_vm" "k3s" {
  count = var.create_vm ? 1 : 0

  name        = var.vm_name
  description = "Job Market Ubuntu Cloud-Init VM - managed by Terraform"
  tags        = ["group3", "terraform", "ubuntu", "k3s"]
  node_name   = var.node_name
  vm_id       = var.vm_id

  # Boot once created so Cloud-Init can run. This is not a host-level setting.
  started         = true
  on_boot         = false
  stop_on_destroy = true

  # The cloud image may not have a running QEMU guest agent at first boot.
  agent {
    enabled = false
  }

  operating_system {
    type = "l26"
  }

  cpu {
    cores = var.cpu_cores
    type  = var.cpu_type
  }

  memory {
    dedicated = var.memory_mb
  }

  scsi_hardware = "virtio-scsi-single"

  disk {
    datastore_id = var.datastore_id
    interface    = "scsi0"
    file_format  = "qcow2"
    import_from  = var.cloud_image_file_id
    iothread     = true
    discard      = "on"
    size         = var.disk_gb
  }

  network_device {
    bridge   = var.network_bridge
    model    = "virtio"
    firewall = true
  }

  initialization {
    datastore_id = var.datastore_id

    dns {
      servers = var.dns_servers
    }

    ip_config {
      ipv4 {
        address = var.vm_ipv4_cidr
        gateway = var.vm_gateway
      }
    }

    user_account {
      username = var.vm_username
      keys     = [trimspace(file(pathexpand(var.ssh_public_key_path)))]
    }
  }

  lifecycle {
    # Creating VM 100 is intentional, but only after the old manual VM is gone.
    # Provider/API will reject a duplicate VM ID; check qm list and Terraform
    # state first. Terraform must never silently import or delete that old VM.
    precondition {
      condition     = var.vm_id >= 100
      error_message = "Use an approved Proxmox VM ID (100 or greater)."
    }

    precondition {
      condition     = var.vm_ipv4_cidr != "" && var.vm_gateway != ""
      error_message = "Specify an approved, available VM IP/CIDR and gateway."
    }

    precondition {
      condition     = var.vm_id != 100 || var.vm_ipv4_cidr == "10.10.10.20/24"
      error_message = "For replacement VM 100, use its approved IP 10.10.10.20/24."
    }
  }
}
