---
description: "Use when accessing the Proxmox home lab server via SSH or web UI, managing VMs/containers, or performing any operations on the local Proxmox server."
---
# Proxmox Home Lab — Access Guide

## Server Details

| Field | Value |
|-------|-------|
| SSH Alias | `proxmox` |
| Hostname / IP | `192.168.2.70` |
| SSH User | `ben` |
| SSH Port | `22` |
| SSH Key | `~/.ssh/id_ed25519` (default) |
| Web UI | `https://192.168.2.70:8006` |

The SSH alias `proxmox` is pre-configured in `~/.ssh/config` — use it for all SSH operations.

## SSH Access

```bash
# Simple alias (preferred)
ssh proxmox

# Explicit form
ssh -i ~/.ssh/id_ed25519 ben@192.168.2.70
```

## File Transfer

```bash
# Upload
scp /local/path proxmox:/remote/path

# Download
scp proxmox:/remote/path /local/path
```

## Web UI

```bash
xdg-open https://192.168.2.70:8006
```

> Accept the self-signed certificate if prompted.

## Remote Access

This server is on the `192.168.2.0/24` LAN. To access remotely, connect via the WireGuard VPN first:

```bash
just vpn-ssh   # Connect to WireGuard EC2 server
```

Then SSH to Proxmox as normal. See [Docs/proxmox.md](../../Docs/AWS_info/proxmox.md) for full details.

## Resource Documentation

Full inventory: [Docs/proxmox.md](../../Docs/AWS_info/proxmox.md)
