variable "proxmox_endpoint" {
  description = "Proxmox VE API base URL"
  type        = string
  default     = "https://192.168.160.14:8006/"
}

variable "proxmox_token_id" {
  description = "Proxmox API token ID (user@realm!tokenname)"
  type        = string
  default     = "candidate5@pve!exam"
}

variable "proxmox_api_token_secret" {
  description = "Proxmox API token secret. Supplied via TF_VAR_proxmox_api_token_secret from .private/secrets.env"
  type        = string
  sensitive   = true
}

variable "proxmox_insecure" {
  description = "Skip TLS verification (the exam Proxmox uses a self-signed certificate)"
  type        = bool
  default     = true
}

variable "node_name" {
  description = "Proxmox node that hosts the VMs"
  type        = string
  default     = "server4"
}

variable "datastore_id" {
  description = "Storage for VM disks and the cloud-init drive"
  type        = string
  default     = "local-lvm"
}

variable "pool_id" {
  description = "Proxmox resource pool the VMs are added to"
  type        = string
  default     = "exam-c5"
}

variable "template_vm_id" {
  description = "VMID of the template to clone (9105)"
  type        = number
  default     = 9105
}

variable "bridge" {
  description = "Network bridge for the VM NICs"
  type        = string
  default     = "vmbr0"
}

variable "vms" {
  description = "VMs to create, keyed by hostname. Each has a role, vCPU count, RAM (MB) and disk (GB)."
  type = map(object({
    role      = string
    cores     = number
    memory_mb = number
    disk_gb   = number
  }))
  default = {
    "c3-docker-host" = {
      role      = "docker-host"
      cores     = 4
      memory_mb = 4096
      disk_gb   = 30
    }
    "c3-k8s-master" = {
      role      = "k8s-control-plane"
      cores     = 4
      memory_mb = 4096
      disk_gb   = 30
    }
    "c3-k8s-worker-1" = {
      role      = "k8s-worker"
      cores     = 4
      memory_mb = 4096
      disk_gb   = 30
    }
    "c3-k8s-worker-2" = {
      role      = "k8s-worker"
      cores     = 4
      memory_mb = 4096
      disk_gb   = 30
    }
  }
}

variable "os_type" {
  description = "Proxmox OS type for the VM (l26 = Linux 2.6+ kernel)"
  type        = string
  default     = "l26"
}

variable "vm_username" {
  description = "Login user created by cloud-init on every VM"
  type        = string
  default     = "devops"
}

variable "vm_password" {
  description = "Password for vm_username. Supplied via TF_VAR_vm_password from .private/secrets.env"
  type        = string
  sensitive   = true
}

variable "ssh_public_key" {
  description = "SSH public key authorised for vm_username. Supplied via TF_VAR_ssh_public_key (.private/ssh/id_ed25519.pub)"
  type        = string
}

variable "guest_agent_timeout" {
  description = "How long Terraform waits for the QEMU guest agent to report IP addresses"
  type        = string
  default     = "10m"
}
