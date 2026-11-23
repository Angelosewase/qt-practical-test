resource "proxmox_virtual_environment_vm" "vm" {
  for_each = var.vms

  name        = each.key
  description = "MyDiary exam VM (${each.value.role}), cloned from template ${var.template_vm_id}"
  tags        = ["exam", "c5", each.value.role]
  node_name   = var.node_name
  pool_id     = var.pool_id

  clone {
    vm_id        = var.template_vm_id
    datastore_id = var.datastore_id
    full         = true
  }

  operating_system {
    type = var.os_type
  }

  cpu {
    cores = each.value.cores
    type  = "host"
  }

  memory {
    dedicated = each.value.memory_mb
  }

  disk {
    datastore_id = var.datastore_id
    interface    = "scsi0"
    size         = each.value.disk_gb
    discard      = "on"
    iothread     = true
  }

  network_device {
    bridge = var.bridge
  }

  agent {
    enabled = true
    timeout = var.guest_agent_timeout
  }

  initialization {
    datastore_id = var.datastore_id

    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }

    user_account {
      username = var.vm_username
      password = var.vm_password
      keys     = [var.ssh_public_key]
    }
  }
}
