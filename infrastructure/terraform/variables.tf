variable "create_vm" {
  description = "Safety guard: provision a new VM only when explicitly enabled."
  type        = bool
  default     = false
}

variable "node_name" {
  description = "Liora-approved Proxmox node name."
  type        = string
  default     = "CHANGE_ME"
}

variable "template_vm_id" {
  description = "ID of an approved, clonable cloud-init VM template. Never use another group's VM."
  type        = number
  default     = 0
}

variable "vm_id" {
  description = "Unique VM ID assigned to our group by Liora."
  type        = number
  default     = 0
}

variable "vm_name" {
  description = "Name for the optional new group 3 k3s VM."
  type        = string
  default     = "group3-k3s-01"
}

variable "network_bridge" {
  description = "Bridge explicitly approved by Liora; not assumed to have internet access."
  type        = string
  default     = "vmbr0"
}

variable "cpu_cores" {
  description = "CPU cores; subject to Liora resource limits."
  type        = number
  default     = 2
}

variable "memory_mb" {
  description = "RAM in MiB; adjust to our resource allowance."
  type        = number
  default     = 4096
}
