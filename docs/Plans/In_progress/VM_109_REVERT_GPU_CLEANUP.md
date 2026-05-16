# Plan: Revert GPU Passthrough & Stabilise VM 109

## Why This Plan Exists

Three attempts to pass the GTX 1660 SUPER (PCIe `07:00.0`) through to VM 109 caused
**full host network loss and apparent crash** every time QEMU started. Root cause:

> **IOMMU group 14 contains the host NIC (`08:00.0` Realtek RTL8125) alongside the
> GPU.** When QEMU initialises the VFIO device it triggers a PCIe secondary bus reset
> (SBR) that resets every device in group 14 — including the host NIC — dropping
> SSH/WebUI and making the host appear crashed.

The `iommu=pt` boot parameter does NOT prevent SBR propagation across a shared PCIe
switch. PCIe ACS (Access Control Services) is required to isolate the GPU into its own
IOMMU group before passthrough is safe.

### Changes Made to Host (to undo)

| File                                         | Change made                    | Must revert?                     |
| -------------------------------------------- | ------------------------------ | -------------------------------- |
| `/etc/modprobe.d/vfio.conf`                  | IDs changed to `10de:21c4,...` | Yes — restore original or remove |
| `/etc/modprobe.d/blacklist-nvidia-vfio.conf` | Created (softdep entries)      | Yes — delete                     |
| `/etc/initramfs-tools/modules`               | Added `vfio`, `vfio_pci`, etc. | Yes — remove those lines         |

### Current VM 109 State (already fixed)

- `hostpci0` — **removed** ✅
- `vga` — **set back to `std`** ✅
- `onboot` — **0** (manual start only) ✅

---

## Phase 1: Revert Host VFIO Config

**Status**: Not started

**Goal**: Remove all VFIO-related modprobe config added during passthrough attempts so
the host boots cleanly with the `nvidia` driver reclaiming the GPU.

**Deliverables**:

- [ ] Delete `/etc/modprobe.d/blacklist-nvidia-vfio.conf`
  ```bash
  sudo rm /etc/modprobe.d/blacklist-nvidia-vfio.conf
  ```
- [ ] Restore `/etc/modprobe.d/vfio.conf` to its original state (or remove IDs so
      vfio-pci loads but claims nothing by default):
  ```bash
  sudo bash -c 'echo "# vfio-pci: no IDs bound by default" > /etc/modprobe.d/vfio.conf'
  ```
- [ ] Remove VFIO modules from `/etc/initramfs-tools/modules`:
  ```bash
  sudo sed -i '/^vfio/d' /etc/initramfs-tools/modules
  ```
- [ ] Rebuild initramfs:
  ```bash
  sudo update-initramfs -u -k all
  ```
- [ ] Reboot Proxmox host

**Tests**:

- [ ] `lspci -k -s 07:00.0` shows `Kernel driver in use: nvidia` (not vfio-pci)
- [ ] SSH and web UI reachable after reboot
- [ ] `nvidia-smi` works on host (if nvidia userspace tools installed)

**Stability Criteria**: Host boots cleanly; GPU back under `nvidia` driver; no
VFIO-related errors in `dmesg`.

**Notes**:

---

## Phase 2: Verify VM 109 Boots Without GPU

**Status**: Not started

**Goal**: Confirm VM 109 starts and is reachable over SSH with the virtual display and
no PCIe passthrough.

**Deliverables**:

- [ ] Start VM 109: `qm start 109`
- [ ] Confirm status: `qm status 109` → `running`
- [ ] SSH into VM 109 at `192.168.2.71`

**Tests**:

- [ ] `qm config 109` shows no `hostpci` entries
- [ ] `qm config 109` shows `vga: std`
- [ ] VM responds to SSH within 60 seconds of start

**Stability Criteria**: VM 109 running and accessible; host SSH/WebUI unaffected.

**Notes**:

---

## Phase 3 (Future): GPU Passthrough via ACS Override

**Status**: Not started — prerequisite: Phases 1 & 2 complete

**Goal**: Re-attempt GPU passthrough safely by splitting IOMMU group 14 using the
PCIe ACS override kernel parameter, isolating the GPU from the host NIC/SATA.

### What ACS Override Does

Adds `pcie_acs_override=downstream,multifunction` to the kernel cmdline. This forces
every PCIe downstream port to report ACS capability, causing the kernel to place each
endpoint device into its own IOMMU group.

**Security note**: ACS override weakens DMA isolation between devices. Acceptable for
a home lab; not recommended for production/multi-tenant environments.

**Deliverables**:

- [ ] Add to `/etc/default/grub`:
  ```
  GRUB_CMDLINE_LINUX_DEFAULT="quiet amd_iommu=on iommu=pt video=efifb:off pcie_acs_override=downstream,multifunction"
  ```
- [ ] Run `sudo update-grub`
- [ ] Rebuild VFIO config (re-run Phase 1 of `VM_109_GPU_PCIE_PASSTHROUGH.md` steps)
- [ ] Reboot and verify GPU is in its **own** IOMMU group:
  ```bash
  find /sys/kernel/iommu_groups/ -type l | sort -V | grep "07:00"
  # All 07:00.* should be in their own small group (ideally just the 4 GPU functions)
  ```
- [ ] Re-add GPU passthrough to VM 109 using `pcie=1,x-vga=1`
- [ ] Start VM 109 and confirm host stays stable

**Tests**:

- [ ] GPU is in an isolated IOMMU group (not shared with NIC/SATA)
- [ ] `qm start 109` succeeds without host network loss
- [ ] Host SSH/WebUI remain reachable during and after VM start

**Stability Criteria**: VM 109 running with GPU passthrough; host network unaffected
throughout VM lifecycle (start, stop, reboot).

**Notes**:

---

## Commands Reference

```bash
# SSH to Proxmox
ssh proxmox

# Check current GPU driver
lspci -k -s 07:00.0

# Check IOMMU group for GPU after ACS override
find /sys/kernel/iommu_groups/ -type l | sort -V | grep "07:00"

# VM 109 operations
sudo qm start 109
sudo qm stop 109
sudo qm config 109
```
