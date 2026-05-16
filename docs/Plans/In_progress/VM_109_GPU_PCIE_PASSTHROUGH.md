# Plan: PCIe Passthrough — NVIDIA GTX 1660 SUPER → VM 109

## Summary

Configure full PCIe passthrough of the NVIDIA GeForce GTX 1660 SUPER (`07:00.0–07:00.3`)
from the Proxmox host to a new QEMU VM (ID **109**). Remove any conflicting GPU settings
from VM 109 if they exist.

---

## Current State (discovered)

| Item               | Value                                                                           |
| ------------------ | ------------------------------------------------------------------------------- |
| GPU                | NVIDIA TU116 GTX 1660 SUPER                                                     |
| PCI addresses      | `07:00.0` (GPU), `07:00.1` (Audio), `07:00.2` (USB 3.1), `07:00.3` (USB-C UCSI) |
| Vendor:Device IDs  | `10de:21c4`, `10de:1aeb`, `10de:1aec`, `10de:1aed`                              |
| IOMMU group        | 14 (shared with AMD chipset PCIe bridges, SATA, WiFi, Ethernet, USB)            |
| IOMMU enabled      | ✅ `amd_iommu=on iommu=pt` already in GRUB cmdline                              |
| VFIO modules       | ✅ `vfio`, `vfio_pci`, `vfio_pci_core`, `vfio_iommu_type1` loaded               |
| Current GPU driver | `nvidia` (wrong — needs to be `vfio-pci` for passthrough)                       |
| Existing vfio.conf | ⚠️ Has **wrong IDs** (`10de:2504,10de:228e`) — must be corrected                |
| VFIO initramfs     | ❌ Not configured — modules not loaded early enough                             |
| VM 109             | ⚠️ **Exists** — has a prior GPU PCIe passthrough that must be removed first     |

### IOMMU Group 14 — Other Devices (non-GPU)

These share IOMMU group 14 with the GPU due to AMD PCIe switch topology.
Because we cannot isolate the GPU to its own group without ACS override, we use
Proxmox's `unsafe` passthrough flag (acceptable for a home lab).

| PCI Addr          | Device                                      |
| ----------------- | ------------------------------------------- |
| `05:00.0`         | AMD 600 Series PCIe Switch Upstream Port    |
| `06:00.0–06:0d.0` | AMD 600 Series PCIe Switch Downstream Ports |
| `08:00.0`         | Realtek RTL8125 2.5GbE (host NIC)           |
| `09:00.0`         | Realtek RTL8852BE Wi-Fi                     |
| `0b:00.0`         | AMD USB 3.2 Controller                      |
| `0c:00.0`         | AMD SATA Controller                         |

> **Risk**: The host SATA and NIC are in the same group. Do NOT pass those
> devices through. Only pass `07:00.*`. Use `unsafe=1` in Proxmox hostpci config.

---

## Phase 0: Remove Existing GPU Passthrough from VM 109

**Status**: Not started

**Goal**: Strip all existing `hostpci`, `vga`, and GPU-related entries from VM 109's config
so there is no conflict when the GTX 1660 SUPER passthrough is applied.

**Deliverables**:

- [ ] Stop VM 109 if running: `qm stop 109`
- [ ] Read current config to identify all existing `hostpci` and `vga` entries:
  ```bash
  # Requires root on Proxmox host
  sudo cat /etc/pve/nodes/bthek1/qemu-server/109.conf
  ```
- [ ] Remove every `hostpci*` line (prior GPU passthrough)
- [ ] Remove or set `vga: none` (remove any virtual display tied to old GPU)
- [ ] Remove any `machine:` / `bios:` lines that conflict with q35 + OVMF (will be
      set correctly in Phase 2)
- [ ] Verify config no longer references any old GPU PCI addresses

**Commands** (run as root on Proxmox):

```bash
# Remove all hostpci lines
qm set 109 --delete hostpci0
qm set 109 --delete hostpci1
# (repeat for hostpci2, hostpci3, etc. — as many as exist)

# Set display to none
qm set 109 --vga none
```

**Tests**:

- [ ] `qm config 109` shows zero `hostpci` lines
- [ ] `qm config 109` shows `vga: none`
- [ ] No references to prior GPU PCI address remain in the config

**Stability Criteria**: VM 109 config has no `hostpci` entries; VM can be started
(even without GPU) without VFIO device conflicts.

**Notes**:

---

## Phase 1: Fix VFIO Binding on the Host

**Status**: Not started

**Goal**: Ensure the GPU is bound to `vfio-pci` at boot, not `nvidia`.

**Deliverables**:

- [ ] Correct `/etc/modprobe.d/vfio.conf` with the right vendor:device IDs:
  ```
  options vfio-pci ids=10de:21c4,10de:1aeb,10de:1aec,10de:1aed
  ```
- [ ] Create `/etc/modprobe.d/blacklist-nvidia.conf` to prevent `nvidia` driver from
      grabbing the GPU at boot:
  ```
  blacklist nvidia
  blacklist nvidiafb
  blacklist nouveau
  softdep nvidia pre: vfio-pci
  ```
- [ ] Ensure VFIO modules load before PCI device probing by adding to
      `/etc/initramfs-tools/modules`:
  ```
  vfio
  vfio_pci
  vfio_pci_core
  vfio_iommu_type1
  ```
- [ ] Rebuild initramfs: `update-initramfs -u -k all`
- [ ] Reboot Proxmox host
- [ ] Verify: `readlink /sys/bus/pci/devices/0000:07:00.0/driver` → should be
      `...drivers/vfio-pci`

**Tests**:

- [ ] `lspci -k -s 07:00.0` shows `Kernel driver in use: vfio-pci`
- [ ] `lspci -k -s 07:00.1` shows `Kernel driver in use: vfio-pci`
- [ ] `lspci -k -s 07:00.2` shows `Kernel driver in use: vfio-pci`
- [ ] `lspci -k -s 07:00.3` shows `Kernel driver in use: vfio-pci`
- [ ] Proxmox host is still accessible via SSH after reboot (host NIC intact)

**Stability Criteria**: All four GPU functions bound to `vfio-pci`; host network reachable.

**Notes**:

---

## Phase 2: Create VM 109 with PCIe Passthrough

**Status**: Not started

**Goal**: Create QEMU VM 109 configured for GPU passthrough, with no virtual GPU or
display device that would conflict with the passed-through GPU.

**VM Spec (recommended baseline)**:

| Setting      | Value                                            |
| ------------ | ------------------------------------------------ |
| VM ID        | 109                                              |
| Machine type | `q35` (required for PCIe passthrough)            |
| BIOS         | `OVMF (UEFI)` — needed for GPU primary output    |
| CPU          | `host` (expose host CPU flags)                   |
| Cores        | 4+                                               |
| Memory       | 8192 MB+                                         |
| Disk         | VirtIO or SCSI                                   |
| Display      | `none` (no virtual display — GPU handles output) |
| VGA          | Remove / set to `none`                           |

**PCIe Passthrough Config (in Proxmox VM hardware)**:

| hostpci slot | PCI address    | Options                   |
| ------------ | -------------- | ------------------------- |
| `hostpci0`   | `0000:07:00.0` | `pcie=1,x-vga=1,unsafe=1` |
| `hostpci1`   | `0000:07:00.1` | `pcie=1,unsafe=1`         |
| `hostpci2`   | `0000:07:00.2` | `pcie=1,unsafe=1`         |
| `hostpci3`   | `0000:07:00.3` | `pcie=1,unsafe=1`         |

> `x-vga=1` on `hostpci0` enables VGA arbitration so the GPU can be used as primary display.
> `unsafe=1` bypasses the IOMMU group isolation check (required here due to shared group 14).

**Deliverables**:

- [ ] VM 109 already exists (cleaned up in Phase 0) — no need to create
- [ ] Machine type set to `q35`
- [ ] BIOS set to OVMF (EFI disk required: add `efidisk0`)
- [ ] CPU type set to `host`
- [ ] Display/VGA set to `none`
- [ ] All four GPU functions added as `hostpci0–3` with options above
- [ ] Remove any existing virtual GPU entries (e.g., `vga:` lines) from VM 109 config
- [ ] VM 109 config saved and visible at `/etc/pve/qemu-server/109.conf`

**Verify config file** (`/etc/pve/qemu-server/109.conf`) contains:

```ini
machine: pc-q35-*
bios: ovmf
cpu: host
vga: none
hostpci0: 0000:07:00.0,pcie=1,x-vga=1,unsafe=1
hostpci1: 0000:07:00.1,pcie=1,unsafe=1
hostpci2: 0000:07:00.2,pcie=1,unsafe=1
hostpci3: 0000:07:00.3,pcie=1,unsafe=1
```

**Tests**:

- [ ] `qm config 109` shows all four `hostpci` entries and `vga: none`
- [ ] No `hostpci` entries exist that reference AMD iGPU (`0f:00.0`)
- [ ] VM starts without error: `qm start 109`
- [ ] VM QEMU process holds the VFIO device: `lsof /dev/vfio/*`

**Stability Criteria**: VM 109 boots; no errors in `journalctl -u kvm` related to VFIO device
acquisition; GPU functions no longer shown under `nvidia` in host `lspci -k`.

**Notes**:

---

## Phase 3: Guest OS & Driver Verification

**Status**: Not started

**Goal**: Confirm the GPU is usable inside VM 109 with drivers installed.

**Deliverables**:

- [ ] OS installed on VM 109 (Linux or Windows)
- [ ] NVIDIA drivers installed inside guest
- [ ] GPU detected and functional inside guest (`nvidia-smi` or Device Manager)

**Tests**:

- [ ] `nvidia-smi` inside guest shows GTX 1660 SUPER
- [ ] No Code 43 errors (Windows) — ensured by UEFI + hiding KVM from GPU
- [ ] Host confirms: `lspci -k -s 07:00.0` still shows `vfio-pci` (not claimed back)

**Notes**:

---

## Commands Reference

```bash
# SSH to Proxmox
ssh proxmox

# Check current GPU driver binding
lspci -k -s 07:00.0

# Manually rebind GPU to vfio-pci (without reboot, for testing)
echo "0000:07:00.0" > /sys/bus/pci/drivers/nvidia/unbind
echo "10de:21c4" > /sys/bus/pci/drivers/vfio-pci/new_id

# Check IOMMU groups
find /sys/kernel/iommu_groups/ -type l | sort -V

# View VM 109 config
qm config 109

# Start/stop VM 109
qm start 109
qm stop 109
```

---

## Risk Notes

| Risk                                       | Mitigation                                            |
| ------------------------------------------ | ----------------------------------------------------- |
| Host SATA controller in IOMMU group 14     | Only pass `07:00.*`; use `unsafe=1`                   |
| Host loses display if `nvidia` blacklisted | AMD iGPU (`amdgpu` at `0f:00.0`) handles host console |
| Wrong VFIO IDs in existing config          | Phase 1 corrects them                                 |
| Guest Code 43 (Windows driver error)       | Use UEFI/OVMF + `hidden=1` CPU flag if needed         |
