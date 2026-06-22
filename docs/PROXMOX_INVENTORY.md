# Proxmox Inventory

Live snapshot of the Proxmox cluster, queried on 2026-06-17.

- **Cluster:** `mycluster`
- **Node:** `bthek1` — 192.168.2.70
- **Gateway:** 192.168.2.1 · **Bridge:** vmbr0
- **Guests:** 9 total (1 QEMU VM + 8 LXC containers)

| VMID | Name | Type | IP Address | Status | Tags |
|------|------|------|------------|--------|------|
| 109 | Main | VM (qemu) | 192.168.2.109 | running | gpu;works |
| 100 | work | LXC | 192.168.2.100 | running | default |
| 103 | work2 | LXC | 192.168.2.103 | running | default |
| 106 | test | LXC | 192.168.2.106 | running | docker |
| 107 | rag | LXC | 192.168.2.107 | running | docker |
| 111 | gh-runner | LXC | 192.168.2.111 | running | github-runner;lxc;terraform |
| 200 | stockmarket | LXC | 192.168.2.200 | running | stockmarket;terraform |
| 201 | stockmarket-db | LXC | 192.168.2.201 | running | database;stockmarket;terraform |
| 202 | ollama-202 | LXC | 192.168.2.202 | running | — |

## Notes

- **IP convention:** every guest uses a static `192.168.2.<VMID>` address (last octet = VMID). On 2026-06-17 the `work` (100), `work2` (103), and `rag` (107) containers were re-IP'd via `pct set <id> -net0 …` to bring them in line (`.23→.100`, `.25→.103`, `.28→.107`). VM 109 (Main) was brought in line the same day (`.20→.109`) via a router DHCP reservation pinned to its MAC, applied by bouncing its NetworkManager connection (`nmcli con down/up netplan-enp6s18`); the host runs DHCP-assigned networking, so the reservation — not a guest static config — fixes the address.
- LXC rows (IPs, status, tags) were verified live against `pct list` / `pct config` on 2026-06-17. VM 109 (Main)'s `.109` IP was verified live from the host itself (this workstation *is* VM 109); its status is carried over from the previous snapshot.
- Container **108 / terraCT** was destroyed on 2026-06-17 (`pct destroy 108` on the node). It was the container `terraform/lxc/` was templated for; the repo's Terraform now manages no live guests.
- Container **104 / Frigate** was destroyed on 2026-06-17 (`pct stop 104` + `pct destroy 104`); its 64G rootfs (`vm-104-disk-0`) was removed. Freed IP `192.168.2.26`.
- Containers 111, 200, 201 carry a `terraform` tag but are not in this repo's state — likely managed elsewhere or imported separately.
- **Host RGB / OpenRGB (2026-06-23):** The ASUS **Aura** USB controller (`0b05:19af`) was removed from VM 109's USB passthrough so the **host** can drive it. OpenRGB now runs as a host systemd service (`openrgb.service`) serving `192.168.2.70:6742`, controlling all 3 RGB controllers (2× ENE DRAM over SMBus + Aura motherboard). Do not re-pass `0b05:19af` to a VM. See [OPENRGB_SERVER_SETUP.md](OPENRGB_SERVER_SETUP.md). 109's remaining USB passthroughs (`13d3:3571`, `047d:8188`, `1bcf:2284`, `25a7:fa61`) are unaffected.
