variable "create_vm" {
  description = "Safety guard: no VM or image is created until explicitly enabled."
  type        = bool
  default     = false
}

variable "node_name" {
  description = "Proxmox node name (verify on Liora's shared server)."
  type        = string
  default     = "CHANGE_ME"
}

variable "vm_id" {
  description = "Approved, currently unused VM ID; never use the existing VM 100."
  type        = number
  default     = 0
}

variable "vm_name" {
  description = "New Ubuntu VM name."
  type        = string
  default     = "job-market-ubuntu-101"
}

variable "cpu_cores" {
  description = "Number of virtual CPU cores."
  type        = number
  default     = 2

  validation {
    condition     = var.cpu_cores >= 1
    error_message = "cpu_cores must be at least 1."
  }
}

variable "cpu_type" {
  description = "QEMU virtual CPU model; matches the existing Ubuntu VM by default."
  type        = string
  default     = "x86-64-v2-AES"
}

variable "memory_mb" {
  description = "Dedicated VM memory in MiB."
  type        = number
  default     = 4096

  validation {
    condition     = var.memory_mb >= 512
    error_message = "memory_mb must be at least 512 MiB."
  }
}

variable "disk_gb" {
  description = "Boot disk size in GiB (minimum must fit the imported cloud image)."
  type        = number
  default     = 16

  validation {
    condition     = var.disk_gb >= 8
    error_message = "disk_gb must be at least 8 GiB."
  }
}

variable "datastore_id" {
  description = "Approved Proxmox storage for the VM disk and cloud-init disk."
  type        = string
  default     = "local"
}

variable "network_bridge" {
  description = "Proxmox bridge; the existing project's NAT network is nat0."
  type        = string
  default     = "nat0"
}

variable "vm_ipv4_cidr" {
  description = "Approved unused static IPv4/CIDR, e.g. 10.10.10.21/24; verify before use."
  type        = string
  default     = ""
}

variable "vm_gateway" {
  description = "Default gateway for the NAT subnet."
  type        = string
  default     = "10.10.10.1"
}

variable "dns_servers" {
  description = "DNS servers for Cloud-Init."
  type        = list(string)
  default     = ["1.1.1.1", "8.8.8.8"]
}

variable "vm_username" {
  description = "Ubuntu account created by Cloud-Init."
  type        = string
  default     = "group3"
}

variable "ssh_public_key_path" {
  description = "Local path to an existing SSH PUBLIC key; never commit a private key."
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "cloud_image_file_id" {
  description = "Manually staged image on Proxmox storage, in datastore:import/name.qcow2 format."
  type        = string
  default     = "local:import/job-market-noble-server-cloudimg-amd64.qcow2"
}
