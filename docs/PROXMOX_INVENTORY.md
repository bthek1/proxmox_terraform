# Proxmox Inventory

Live snapshot of the Proxmox cluster, queried on 2026-06-17.

- **Cluster:** `mycluster`
- **Node:** `bthek1` — 192.168.2.70
- **Gateway:** 192.168.2.1 · **Bridge:** vmbr0
- **Guests:** 10 total (1 QEMU VM + 9 LXC containers)

| VMID | Name | Type | IP Address | Status | Tags |
|------|------|------|------------|--------|------|
| 109 | Main | VM (qemu) | 192.168.2.20 | running | gpu;works |
| 100 | work | LXC | 192.168.2.23 | running | default |
| 103 | work2 | LXC | 192.168.2.25 | running | default |
| 104 | Frigate | LXC | 192.168.2.26 | running | — |
| 106 | test | LXC | 192.168.2.106 | running | docker |
| 107 | rag | LXC | 192.168.2.107 | running | docker |
| 111 | gh-runner | LXC | 192.168.2.111 | running | github-runner;lxc;terraform |
| 200 | stockmarket | LXC | 192.168.2.200 | running | stockmarket;terraform |
| 201 | stockmarket-db | LXC | 192.168.2.201 | running | database;stockmarket;terraform |
| 202 | ollama-202 | LXC | 192.168.2.202 | running | — |

## Notes

- LXC rows (IPs, status, tags) were verified live against `pct list` / `pct config` on 2026-06-17. The VM 109 (Main) row was **not** re-verified this run — `qm` requires root, unavailable over the `ben` SSH login — so its IP/status are carried over from the previous snapshot.
- Container **108 / terraCT** was destroyed on 2026-06-17 (`pct destroy 108` on the node). It was the container `terraform/lxc/` was templated for; the repo's Terraform now manages no live guests.
- Containers 111, 200, 201 carry a `terraform` tag but are not in this repo's state — likely managed elsewhere or imported separately.
