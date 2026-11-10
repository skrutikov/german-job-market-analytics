# Proxmox API credentials come from PROXMOX_VE_ENDPOINT and PROXMOX_VE_API_TOKEN.
# Use a verified Proxmox CA (for example SSL_CERT_FILE=/etc/pve/pve-root-ca.pem).
# This configuration never manages host-level networking or the existing VM 100.
provider "proxmox" {}

# Optional image download. Proxmox's download-url API needs more than VM-level
# privileges (including Sys.Modify); keep OFF unless explicitly authorized.
# Alternatively, have an authorized operator pre-stage the image under
# var.cloud_image_file_id and leave download_cloud_image = false.
resource "proxmox_virtual_environment_download_file" "ubuntu_cloud_image" {
  count = var.create_vm && var.download_cloud_image ? 1 : 0

  node_name    = var.node_name
  datastore_id = var.datastore_id
  content_type = "import"
  url          = var.cloud_image_url
  file_name    = "job-market-noble-server-cloudimg-amd64.qcow2"
  overwrite    = false
}

# NEW Ubuntu 24.04 VM from a QCOW2 cloud image, not a clone of VM 100.
# create_vm defaults to false. VM 100 remains untouched.
resource "proxmox_virtual_environment_vm" "k3s" {
  count = var.create_vm ? 1 : 0

  name        = var.vm_name
  description = "Job Market Ubuntu Cloud-Init VM - managed by Terraform"
  tags        = ["group3", "terraform", "ubuntu", "test"]
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
    import_from  = var.download_cloud_image ? proxmox_virtual_environment_download_file.ubuntu_cloud_image[0].id : var.cloud_image_file_id
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
    # Guard against accidentally pointing this NEW resource at the running VM.
    precondition {
      condition     = var.vm_id > 0 && var.vm_id != 100
      error_message = "This configuration is for a separate VM; VM ID 100 is the existing manually installed Kubernetes VM."
    }

    precondition {
      condition     = var.vm_ipv4_cidr != "" && var.vm_ipv4_cidr != "10.10.10.20/24" && var.vm_gateway != ""
      error_message = "Specify an approved unused IP/CIDR and gateway; do not reuse VM 100's 10.10.10.20/24 address."
    }
  }
}
