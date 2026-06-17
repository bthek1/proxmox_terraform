# Proxmox Inventory

Live snapshot of the Proxmox cluster, queried on 2026-06-17.

- **Cluster:** `mycluster`
- **Node:** `bthek1` — 192.168.2.70
- **Gateway:** 192.168.2.1 · **Bridge:** vmbr0
- **Guests:** 11 total (1 QEMU VM + 10 LXC containers)

| VMID | Name | Type | IP Address | Status | Tags |
|------|------|------|------------|--------|------|
| 109 | Main | VM (qemu) | 192.168.2.20 | running | gpu;works |
| 100 | work | LXC | 192.168.2.23 | running | default |
| 103 | work2 | LXC | 192.168.2.25 | running | default |
| 104 | Frigate | LXC | 192.168.2.26 | running | — |
| 106 | test | LXC | 192.168.2.106 | running | docker |
| 107 | rag | LXC | 192.168.2.28 | running | docker |
| 108 | terraCT | LXC | 192.168.2.100 | stopped | terraform |
| 111 | gh-runner | LXC | 192.168.2.101 | running | github-runner;terraform |
| 200 | stockmarket | LXC | 192.168.2.200 | running | stockmarket;terraform |
| 201 | stockmarket-db | LXC | 192.168.2.201 | running | database;stockmarket;terraform |
| 202 | ollama-202 | LXC | 192.168.2.202 | running | stockmarket;terraform |

## Notes

- IP for VM 109 (Main) came from the QEMU guest agent; all LXC IPs are static from each container's `net0` config.
- This repo's Terraform (`terraform/lxc/`) currently manages only **108 / terraCT** (stopped).
- Containers 111, 200, 201, 202 carry a `terraform` tag but are not in this repo's state — likely managed elsewhere or imported separately.
