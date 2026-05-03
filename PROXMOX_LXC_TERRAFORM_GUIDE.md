# Proxmox LXC Containers with Terraform — Knowledge Transfer Guide

A step-by-step guide to provisioning Linux containers (LXC) on Proxmox VE using Terraform and the [bpg/proxmox](https://registry.terraform.io/providers/bpg/proxmox/latest/docs) provider.

Copy this entire `terraform/lxc/` directory into your project to reuse the setup.

---

## Prerequisites

| Requirement | Details |
|---|---|
| Proxmox VE | 7.x or 8.x |
| Terraform | >= 1.5 |
| bpg/proxmox provider | ~> 0.75 |
| LXC template | Downloaded on the Proxmox node before applying |
| SSH key pair | On your local machine (`~/.ssh/id_ed25519`) |

---

## Directory Structure

```
terraform/lxc/
├── versions.tf          # Terraform + provider version pins
├── provider.tf          # bpg/proxmox provider config
├── variables.tf         # All input variable declarations
├── main.tf              # LXC container resource + optional extra user
├── outputs.tf           # Useful outputs after apply
├── terraform.tfvars     # Your values (gitignored — never commit)
└── terraform.tfvars.example  # Template to copy from
```

---

## Step 1 — Download an LXC Template on Proxmox

Before Terraform can create a container, the OS template must already exist on the node.

### Option A: Proxmox Web UI

1. Open the Proxmox web UI → select your node → **local** storage → **CT Templates**.
2. Click **Templates**, find your distro (e.g. Ubuntu 24.04), click **Download**.

### Option B: SSH into the node

```bash
ssh root@<proxmox-ip>
pveam update
pveam available --section system   # list available templates
pveam download local ubuntu-24.04-standard_24.04-2_amd64.tar.zst
```

The downloaded template path will be:
```
local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst
```

Use this exact string as `template_file_id` in your tfvars.

---

## Step 2 — Set Up Proxmox API Credentials

Terraform needs API access to Proxmox. You have two options.

### Option A: API Token (recommended)

1. In the Proxmox UI go to **Datacenter → Permissions → API Tokens**.
2. Create a token for a user (e.g. `root@pam`), uncheck **Privilege Separation**.
3. Copy the token secret — it is only shown once.

Set environment variables before running Terraform:

```bash
export PROXMOX_VE_ENDPOINT="https://192.168.1.100:8006/"
export PROXMOX_VE_API_TOKEN="root@pam!my-token=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
```

### Option B: Username + Password

```bash
export PROXMOX_VE_ENDPOINT="https://192.168.1.100:8006/"
export PROXMOX_VE_USERNAME="root@pam"
export PROXMOX_VE_PASSWORD="your-password"
```

> **Security note:** Never hardcode credentials in `.tf` files or commit them to version control. Always use environment variables or a gitignored `.tfvars` file.

---

## Step 3 — Configure Your Variables

```bash
cd terraform/lxc/
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` with your values:

```hcl
# Proxmox connection
proxmox_endpoint = "https://192.168.1.100:8006/"
proxmox_username = "root@pam"
# proxmox_password = "changeme"   # or use PROXMOX_VE_PASSWORD env var

proxmox_node = "pve"              # name of your Proxmox node

# Container identity
container_id       = 100          # must be unique on the node
container_hostname = "my-ct"
container_tags     = ["terraform", "lxc"]

# OS template (downloaded in Step 1)
template_file_id = "local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
os_type          = "ubuntu"

# Resources
cpu_cores    = 1
memory_mb    = 512
swap_mb      = 512
disk_size    = 8                  # GB
datastore_id = "local-lvm"

# Networking
network_bridge = "vmbr0"
network_ip     = "dhcp"           # or "192.168.1.101/24" for static
# network_gateway = "192.168.1.1" # required if using static IP

# Access
# ssh_public_keys = "ssh-ed25519 AAAA..."
start_on_create = true
start_on_boot   = false
unprivileged    = true
```

### Full Variable Reference

| Variable | Type | Default | Description |
|---|---|---|---|
| `proxmox_endpoint` | string | — | Proxmox API URL, e.g. `https://proxmox.local:8006/` |
| `proxmox_username` | string | `""` | Proxmox user, e.g. `root@pam` |
| `proxmox_password` | string (sensitive) | `""` | Password (leave empty if using API token) |
| `proxmox_api_token` | string (sensitive) | `""` | API token (leave empty if using password) |
| `proxmox_insecure` | bool | `true` | Skip TLS verification (self-signed certs) |
| `proxmox_node` | string | — | Node name where container is created |
| `container_id` | number | — | VMID — must be unique on the node |
| `container_hostname` | string | — | Hostname inside the container |
| `container_description` | string | `""` | Description shown in Proxmox UI |
| `container_tags` | list(string) | `[]` | Tags for organization |
| `template_file_id` | string | — | Full path to the CT template |
| `os_type` | string | `"unmanaged"` | OS hint: `ubuntu`, `debian`, `fedora`, etc. |
| `cpu_cores` | number | `1` | Number of CPU cores |
| `memory_mb` | number | `512` | RAM in MB |
| `swap_mb` | number | `512` | Swap in MB |
| `disk_size` | number | `8` | Root disk size in GB |
| `datastore_id` | string | `"local-lvm"` | Proxmox storage for root disk |
| `network_bridge` | string | `"vmbr0"` | Bridge for network interface |
| `network_ip` | string | `"dhcp"` | IPv4 address in CIDR or `"dhcp"` |
| `network_gateway` | string | `""` | Gateway (required for static IP) |
| `root_password` | string (sensitive) | `""` | Root password |
| `extra_username` | string | `""` | Additional user to create inside container |
| `extra_user_password` | string (sensitive) | `""` | Password for the extra user |
| `ssh_public_keys` | string | `""` | SSH public key for root |
| `start_on_create` | bool | `true` | Start container immediately after creation |
| `start_on_boot` | bool | `false` | Auto-start on node boot |
| `unprivileged` | bool | `true` | Run as unprivileged container (recommended) |
| `nesting` | bool | `false` | Enable nesting (needed for systemd 255+ inside container) |

---

## Step 4 — Deploy

```bash
cd terraform/lxc/

# Initialise providers and modules
terraform init

# Preview what will be created
terraform plan

# Apply (will prompt for confirmation)
terraform apply
```

After a successful apply you will see:

```
Outputs:

container_id       = 100
container_hostname = "my-ct"
network_ip         = "dhcp"
```

---

## Step 5 — Connect to the Container

### Via Proxmox console

In the Proxmox UI click the container → **Console**.

### Via SSH (if SSH key was injected)

```bash
# Get the assigned IP from the Proxmox UI or DHCP server, then:
ssh root@<container-ip>
```

### Via `pct` on the Proxmox node

```bash
ssh root@<proxmox-ip>
pct enter <container_id>
# e.g. pct enter 100
```

---

## Common Patterns

### Static IP

```hcl
network_ip      = "192.168.1.101/24"
network_gateway = "192.168.1.1"
```

### Extra non-root user

```hcl
extra_username      = "deploy"
extra_user_password = "s3cr3t"
```

This triggers a `null_resource` that SSHes into the container after creation and runs `useradd`.

### Privileged container with nesting (for Docker-in-LXC)

```hcl
unprivileged = false
nesting      = true
```

> Note: privileged containers have a larger attack surface. Only use when required.

### Multiple containers

To manage multiple containers from one workspace, use a Terraform `for_each` over a map variable, or duplicate the directory and use separate state files.

```hcl
# Example: multiple containers with for_each (advanced)
locals {
  containers = {
    web = { id = 101, ip = "192.168.1.101/24" }
    db  = { id = 102, ip = "192.168.1.102/24" }
  }
}

resource "proxmox_virtual_environment_container" "lxc" {
  for_each  = local.containers
  vm_id     = each.value.id
  node_name = var.proxmox_node
  # ... rest of config
}
```

---

## Destroying a Container

```bash
terraform destroy
```

Terraform will prompt for confirmation before deleting the container.

To destroy a specific resource without deleting all:

```bash
terraform destroy -target=proxmox_virtual_environment_container.lxc
```

---

## Troubleshooting

| Problem | Solution |
|---|---|
| `401 Unauthorized` | Check `PROXMOX_VE_API_TOKEN` or username/password |
| `TLS handshake error` | Set `proxmox_insecure = true` or add your CA cert |
| Template not found | Run `pveam download` on the node first (Step 1) |
| Container ID already in use | Choose a different `container_id` |
| SSH connection timeout in `null_resource` | Container may not have fully started; increase timeout or check IP |
| `nesting` required | Enable for containers running systemd 255+ or Docker |

---

## Security Checklist

- [ ] `terraform.tfvars` is listed in `.gitignore`
- [ ] `*.tfstate` and `*.tfstate.backup` are listed in `.gitignore`
- [ ] Credentials are passed via environment variables, not hardcoded
- [ ] Use an API token with minimal required permissions instead of `root` credentials
- [ ] Use `unprivileged = true` unless there is a specific need for privileged mode
- [ ] Rotate API tokens regularly

---

## File Reference

These are the files you need to copy into a new project:

| File | Purpose |
|---|---|
| [terraform/lxc/versions.tf](terraform/lxc/versions.tf) | Terraform and provider version pins |
| [terraform/lxc/provider.tf](terraform/lxc/provider.tf) | bpg/proxmox provider block |
| [terraform/lxc/variables.tf](terraform/lxc/variables.tf) | All input variable declarations |
| [terraform/lxc/main.tf](terraform/lxc/main.tf) | LXC container resource definition |
| [terraform/lxc/outputs.tf](terraform/lxc/outputs.tf) | Output values |
| [terraform/lxc/terraform.tfvars.example](terraform/lxc/terraform.tfvars.example) | Example values file |
