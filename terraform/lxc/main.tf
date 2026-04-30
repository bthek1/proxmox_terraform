# main.tf — Proxmox LXC container resource

resource "proxmox_virtual_environment_container" "lxc" {
  node_name   = var.proxmox_node
  vm_id       = var.container_id
  description = var.container_description
  tags        = var.container_tags

  unprivileged = var.unprivileged

  features {
    nesting = var.nesting
  }

  started       = var.start_on_create
  start_on_boot = var.start_on_boot

  initialization {
    hostname = var.container_hostname

    # Network: set static IP or DHCP
    ip_config {
      ipv4 {
        address = var.network_ip
        gateway = var.network_ip != "dhcp" ? var.network_gateway : null
      }
    }

    user_account {
      password = var.root_password != "" ? var.root_password : null
      keys     = var.ssh_public_keys != "" ? [var.ssh_public_keys] : []
    }
  }

  cpu {
    cores = var.cpu_cores
  }

  memory {
    dedicated = var.memory_mb
    swap      = var.swap_mb
  }

  disk {
    datastore_id = var.datastore_id
    size         = var.disk_size
  }

  network_interface {
    name    = "eth0"
    bridge  = var.network_bridge
    enabled = true
  }

  operating_system {
    template_file_id = var.template_file_id
    type             = var.os_type
  }
}
