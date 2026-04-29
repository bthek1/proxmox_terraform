---
name: "Scaffold Proxmox VM"
description: "Scaffold a new Proxmox VM Terraform resource with variables, outputs, and provider config pre-filled"
argument-hint: "VM name or description (e.g. 'ubuntu-dev', 'k8s-node')"
agent: "agent"
---

Scaffold a complete Terraform module for a new Proxmox VM using the `bpg/proxmox` provider.

The argument (if provided) is the VM name/purpose: **$argument**

## Required files to generate

### `terraform/main.tf`
- `proxmox_virtual_environment_vm` resource for the VM
- Reference variables for all configurable values (no hardcoded values except resource type defaults)
- Include: `cpu`, `memory`, `disk`, `network_device`, `operating_system`, `initialization` (cloud-init) blocks
- Tag the VM with its purpose/name

### `terraform/variables.tf`
Include these variables with sensible defaults:
- `proxmox_endpoint` — Proxmox API URL (e.g. `https://proxmox.local:8006/`)
- `proxmox_node` — target node name
- `vm_name` — VM hostname
- `vm_id` — numeric VM ID (no default — must be set explicitly)
- `cpu_cores` — default `2`
- `memory_mb` — default `2048`
- `disk_size` — default `"20G"`
- `datastore_id` — default `"local-lvm"`
- `network_bridge` — default `"vmbr0"`
- `cloud_image_url` — URL for the cloud init image (e.g. Ubuntu cloud image)

### `terraform/outputs.tf`
- `vm_id` — the Proxmox VM ID
- `vm_ipv4_address` — the assigned IPv4 address (from the VM's network interface)

### `terraform/provider.tf`
- Configure the `bpg/proxmox` provider
- Read credentials from env vars: `PROXMOX_VE_USERNAME`, `PROXMOX_VE_PASSWORD` (or `PROXMOX_VE_API_TOKEN`)
- Set `insecure = true` by default (self-signed certs are common in home labs)
- Pin provider version `~> 0.75`

### `terraform/versions.tf`
- `required_version = ">= 1.5"`
- `required_providers` block for `bpg/proxmox`

## Conventions
- All resource/variable names use `snake_case`
- No credentials or IP addresses in source files — use variables or env vars
- Add a comment block at the top of each file indicating its purpose
