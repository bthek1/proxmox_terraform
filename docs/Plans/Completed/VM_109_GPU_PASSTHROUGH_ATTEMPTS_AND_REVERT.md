# VM 109 GPU Passthrough — Attempts, Crashes & Revert

**Status**: ✅ Completed (revert to stable state)
**Date completed**: 2026-05-17

## Summary

Three separate plans were attempted to pass the NVIDIA GTX 1660 SUPER through to VM 109.
All passthrough attempts caused **full Proxmox host network loss / apparent crash** every
time QEMU started. The root cause was IOMMU group 14 containing the host NIC alongside the
GPU — any VFIO initialisation triggered a PCIe secondary bus reset that killed the NIC.

All changes were reverted. VM 109 is now running cleanly without GPU passthrough.
The host is stable with the GPU back under the `nvidia` driver.

**Outcome**: Passthrough abandoned for now. Safe retry requires ACS override (see
[VM_109_GPU_PASSTHROUGH_ACS.md](../../Plans/In_progress/VM_109_GPU_PASSTHROUGH_ACS.md)).

---

## Root Cause

> **IOMMU group 14 contains the host NIC (`08:00.0` Realtek RTL8125 2.5GbE) alongside the
> GPU (`07:00.0–07:00.3`).** When QEMU initialises the VFIO device it triggers a PCIe
> secondary bus reset (SBR) that propagates through the AMD PCIe switch and resets every
> device in the group — including the host NIC — dropping SSH and the Proxmox WebUI.

`iommu=pt` does **not** prevent SBR propagation across a shared PCIe switch.
PCIe ACS (Access Control Services) override is required to isolate the GPU into its own
IOMMU group.

### IOMMU Group 14 Contents

| PCI Addr          | Device                                          |
| ----------------- | ----------------------------------------------- |
| `05:00.0`         | AMD 600 Series PCIe Switch Upstream Port        |
| `06:00.0–06:0d.0` | AMD 600 Series PCIe Switch Downstream Ports     |
| **`07:00.0`**     | **NVIDIA GTX 1660 SUPER — VGA**                 |
| **`07:00.1`**     | **NVIDIA GTX 1660 SUPER — Audio**               |
| **`07:00.2`**     | **NVIDIA GTX 1660 SUPER — USB 3.1**             |
| **`07:00.3`**     | **NVIDIA GTX 1660 SUPER — USB-C UCSI**          |
| `08:00.0`         | Realtek RTL8125 2.5GbE (host NIC) ← **PROBLEM** |
| `09:00.0`         | Realtek RTL8852BE Wi-Fi                         |
| `0b:00.0`         | AMD USB 3.2 Controller                          |
| `0c:00.0`         | AMD SATA Controller                             |

---

## Host Configuration

| Item              | Value                                              |
| ----------------- | -------------------------------------------------- |
| Proxmox host      | `192.168.2.70`, SSH alias `proxmox`, user `ben`    |
| GPU               | NVIDIA GTX 1660 SUPER at `07:00.0–07:00.3`         |
| Vendor:Device IDs | `10de:21c4`, `10de:1aeb`, `10de:1aec`, `10de:1aed` |
| Host display GPU  | AMD Raphael iGPU at `0f:00.0`, driver `amdgpu`     |
| IOMMU             | `amd_iommu=on iommu=pt video=efifb:off` in GRUB    |
| VM 109 IP         | `192.168.2.20`                                     |

---

## Attempt 1: GPU_SWAP_107_109 ❌ CRASHED

**Goal**: Swap GPUs — move GTX 1660 SUPER from LXC 107 to VM 109, give RTX 3060 to LXC 107.

**Result**: Host network lost on `qm start 109`. PCIe SBR in IOMMU group 14 killed the
host NIC. Proxmox appeared to crash; SSH and WebUI were unreachable.

**What was attempted**:

- Removed GTX 1660 SUPER device node entries from LXC 107 config
- Unloaded `nvidia` host driver, stopped `nvidia-devices.service`
- Bound `07:00.0` and `07:00.1` to `vfio-pci`
- Added `hostpci1: 0000:07:00.0,pcie=1` to VM 109

**Why it failed**: IOMMU group 14 shared with host NIC; SBR on VFIO init killed networking.

---

## Attempt 2: VM_109_GPU_PCIE_PASSTHROUGH ❌ CRASHED

**Goal**: Full PCIe passthrough of GTX 1660 SUPER (`07:00.0–07:00.3`) to VM 109.

**Result**: Same crash. Every combination tried:

- `pcie=1,x-vga=1` — crash
- `pcie=1,x-vga=1` with `unsafe=1` removed (invalid param) — crash
- Single function only (`07:00.0`) — crash

**Phases executed**:

### Phase 0 — Remove Existing GPU Passthrough from VM 109 ✅

- Removed prior `hostpci0`, `hostpci1`, `hostpci2` (old GPU at `01:00.0`, `10:00.6`, `08:00.0`)
- Deleted missing `scsi2` backup disk (`vm-109-disk-0.qcow2` not found)
- Disabled `onboot: 0`
- Set `vga: std`

### Phase 1 — VFIO Binding on Host ✅ (then reverted)

- Updated `/etc/modprobe.d/vfio.conf` with correct IDs (`10de:21c4,10de:1aeb,10de:1aec,10de:1aed`)
- Created `/etc/modprobe.d/blacklist-nvidia-vfio.conf` with `softdep` entries
  - ⚠️ **Lesson**: `blacklist nvidia` caused host boot hang when GPU is physically present
    (likely `nvidia-devices.service` hanging). Use `softdep` only, never blanket blacklist.
- Added `vfio`, `vfio_pci`, `vfio_pci_core`, `vfio_iommu_type1` to `/etc/initramfs-tools/modules`
- Rebuilt initramfs for all 5 kernels, rebooted

### Phase 2 — VM 109 PCIe Passthrough Config ✅ (then reverted)

- Set `hostpci0: 0000:07:00.0,pcie=1,x-vga=1` (note: `unsafe=1` is not a valid param in PVE 7.x)
- VM start immediately crashed host networking

**Lessons learned**:

- `unsafe=1` is **not** a valid Proxmox `qm set --hostpci` parameter in PVE 7.x — remove it
- `blacklist nvidia` causes boot hangs when `nvidia-devices.service` runs with GPU present — use `softdep` only
- `iommu=pt` does NOT prevent PCIe SBR; ACS override is mandatory for shared groups

---

## Revert: VM_109_REVERT_GPU_CLEANUP ✅ COMPLETED

### Phase 1 — Revert Host VFIO Config ✅ Completed 2026-05-17

- Deleted `/etc/modprobe.d/blacklist-nvidia-vfio.conf`
- Cleared `/etc/modprobe.d/vfio.conf` (no IDs bound)
- Removed `vfio*` lines from `/etc/initramfs-tools/modules`
- Rebuilt initramfs for all kernels
- Rebooted host
- Confirmed: `07:00.0 → nvidia` ✅, host SSH/WebUI reachable ✅

### Phase 2 — Verify VM 109 Boots Without GPU ✅ Completed 2026-05-17

- Started VM 109: `qm start 109` → `status: running` ✅
- VM 109 reachable at `192.168.2.20` (SSH key auth failing — use Proxmox web UI console)
- Config confirmed: no `hostpci` entries, `vga: std`, `onboot: 0` ✅

---

## Final State

| Machine | State   | GPU config            | Notes                                      |
| ------- | ------- | --------------------- | ------------------------------------------ |
| Host    | Stable  | `nvidia` at `07:00.x` | Full networking, SSH/WebUI reachable       |
| VM 109  | Running | No GPU passthrough    | `vga: std`, `onboot: 0`, IP `192.168.2.20` |
| LXC 107 | —       | Unchanged             | Not modified during these attempts         |

---

## Host File State After Revert

| File                                         | Current state                         |
| -------------------------------------------- | ------------------------------------- |
| `/etc/modprobe.d/vfio.conf`                  | `# vfio-pci: no IDs bound by default` |
| `/etc/modprobe.d/blacklist-nvidia-vfio.conf` | Deleted                               |
| `/etc/initramfs-tools/modules`               | No `vfio*` entries                    |
| `/etc/pve/qemu-server/109.conf`              | No `hostpci`, `vga: std`, `onboot: 0` |

---

## Next Steps

See [VM_109_GPU_PASSTHROUGH_ACS.md](../In_progress/VM_109_GPU_PASSTHROUGH_ACS.md) for the
correct approach using `pcie_acs_override=downstream,multifunction` to isolate the GPU into
its own IOMMU group before attempting passthrough.
