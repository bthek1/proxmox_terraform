# Plan: GPU Passthrough to VM 109 via ACS Override

**Status**: ✅ Complete (2026-05-17)
**Prerequisite**: Host is stable, GPU (`07:00.x`) bound to `nvidia`, VM 109 running at `192.168.2.20`.

## Summary

Previous passthrough attempts crashed the Proxmox host because the GTX 1660 SUPER shares
IOMMU group 14 with the host NIC (`08:00.0` Realtek RTL8125). ACS override forces the
kernel to split every PCIe endpoint into its own IOMMU group, isolating the GPU so VFIO
initialisation no longer triggers a secondary bus reset on the NIC.

See [VM_109_GPU_PASSTHROUGH_ATTEMPTS_AND_REVERT.md](../Completed/VM_109_GPU_PASSTHROUGH_ATTEMPTS_AND_REVERT.md)
for the full failure history and root cause analysis.

---

## Hardware Reference

| Item              | Value                                                                  |
| ----------------- | ---------------------------------------------------------------------- |
| GPU               | NVIDIA GTX 1660 SUPER                                                  |
| PCI addresses     | `07:00.0` (VGA), `07:00.1` (Audio), `07:00.2` (USB), `07:00.3` (USB-C) |
| Vendor:Device IDs | `10de:21c4`, `10de:1aeb`, `10de:1aec`, `10de:1aed`                     |
| Host display      | AMD Raphael iGPU `0f:00.0` — safe, separate group                      |
| Host NIC          | Realtek RTL8125 `08:00.0` — must stay on host                          |
| IOMMU             | `amd_iommu=on iommu=pt video=efifb:off` already set                    |
| VM 109            | q35, OVMF, cpu=host, IP `192.168.2.20`                                 |
| Proxmox SSH       | `ssh proxmox` → `ben@192.168.2.70`                                     |

---

## Phase 1: Enable ACS Override and Split IOMMU Group 14

**Status**: ✅ Complete (2026-05-17)

**Goal**: Add `pcie_acs_override=downstream,multifunction` to the kernel cmdline so the
GPU gets its own IOMMU group, isolated from the host NIC and SATA.

> ⚠️ **Security note**: ACS override weakens DMA isolation between PCIe devices. Acceptable
> for a home lab; not recommended for production or multi-tenant systems.

### Deliverables

- [x] **1.1 — Add ACS override to GRUB**

  ```bash
  ssh proxmox
  sudo nano /etc/default/grub
  ```

  Change the `GRUB_CMDLINE_LINUX_DEFAULT` line to:

  ```
  GRUB_CMDLINE_LINUX_DEFAULT="quiet amd_iommu=on iommu=pt video=efifb:off pcie_acs_override=downstream,multifunction"
  ```

- [x] **1.2 — Apply and reboot**

  ```bash
  sudo update-grub
  sudo reboot
  ```

- [x] **1.3 — Verify GPU is in its own isolated IOMMU group**

  ```bash
  # After reboot, SSH back in
  ssh proxmox

  # Check IOMMU group for the GPU — should be a small group with only 07:00.* devices
  find /sys/kernel/iommu_groups/ -type l | sort -V | xargs -I{} sh -c 'echo "Group $(basename $(dirname {})):  $(lspci -s $(basename {}))"' | grep -A5 "07:00"

  # Also check the NIC is now in a different (separate) group
  find /sys/kernel/iommu_groups/ -type l | sort -V | xargs -I{} sh -c 'echo "Group $(basename $(dirname {})):  $(lspci -s $(basename {}))"' | grep "08:00"
  ```

  Expected: `07:00.x` devices appear together in one small group; `08:00.0` (NIC) is in a
  **different** group number.

### Verification

- [x] GPU (`07:00.x`) is in its own IOMMU group, not shared with `08:00.0`
- [x] Host NIC (`08:00.0`) is in a separate IOMMU group
- [x] Host SSH/WebUI reachable after reboot
- [x] `lspci -k -s 07:00.0` still shows `nvidia` (good — VFIO not yet configured)

### Stability Criteria

Host boots cleanly with ACS override; GPU in isolated IOMMU group; network intact.

### Notes

ACS override split all of Group 14 into individual groups:

- Group 24: `07:00.0` GTX 1660 SUPER VGA
- Group 25: `07:00.1` GTX Audio
- Group 26: `07:00.2` GTX USB
- Group 27: `07:00.3` GTX USB-C
- Group 28: `08:00.0` Realtek NIC
- Group 29: `09:00.0` WiFi
- Group 30: `0b:00.0` USB controller
- Group 31: `0c:00.0` SATA controller

---

## Phase 2: Bind GTX 1660 SUPER to vfio-pci

**Status**: ✅ Complete (2026-05-17)
**Prerequisite**: Phase 1 complete — GPU verified in isolated IOMMU group.

**Goal**: Configure the host to hand the GPU to VFIO at boot instead of loading the
`nvidia` driver for it.

> **Key lessons from previous attempts**:
>
> - Do NOT use `blacklist nvidia` — it causes boot hangs when `nvidia-devices.service` runs
> - Use `softdep` only: `softdep nvidia pre: vfio-pci`
> - `unsafe=1` is **not** a valid Proxmox hostpci parameter in PVE 7.x — do not use it

### Deliverables

- [x] **2.1 — Set vfio-pci IDs**

  ```bash
  sudo bash -c 'cat > /etc/modprobe.d/vfio.conf << EOF
  options vfio-pci ids=10de:21c4,10de:1aeb,10de:1aec,10de:1aed
  EOF'
  ```

- [x] **2.2 — Add softdep to prevent nvidia from binding first**

  ```bash
  sudo bash -c 'cat > /etc/modprobe.d/vfio-nvidia-softdep.conf << EOF
  # Ensure vfio-pci binds before nvidia for the GTX 1660 SUPER
  softdep nvidia pre: vfio-pci
  softdep nvidia_drm pre: vfio-pci
  softdep nvidia_modeset pre: vfio-pci
  softdep nvidia_uvm pre: vfio-pci
  EOF'
  ```

- [x] **2.3 — Load VFIO modules early in initramfs**

  ```bash
  sudo bash -c 'cat >> /etc/initramfs-tools/modules << EOF
  vfio
  vfio_pci
  vfio_pci_core
  vfio_iommu_type1
  EOF'
  ```

- [x] **2.4 — Rebuild initramfs and reboot**

  ```bash
  sudo update-initramfs -u -k all
  sudo reboot
  ```

- [x] **2.5 — Verify GPU is bound to vfio-pci**

  ```bash
  ssh proxmox
  for addr in 07:00.0 07:00.1 07:00.2 07:00.3; do
    echo -n "0000:$addr → "
    readlink /sys/bus/pci/devices/0000:$addr/driver | xargs basename
  done
  ```

  All four should show `vfio-pci`.

  Also verify host NIC is still bound to its driver (not lost):

  ```bash
  lspci -k -s 08:00.0   # should show r8169 or similar, NOT vfio-pci
  ip link show           # host network interfaces should be present
  ```

### Verification

- [x] `lspci -k -s 07:00.0` → `Kernel driver in use: vfio-pci`
- [x] `lspci -k -s 07:00.1` → `Kernel driver in use: vfio-pci`
- [ ] `lspci -k -s 07:00.2` → `Kernel driver in use: vfio-pci` ⚠️ still `xhci_hcd` — isolated group, OK for VGA-only passthrough
- [ ] `lspci -k -s 07:00.3` → `Kernel driver in use: vfio-pci` ⚠️ still `nvidia-gpu` — isolated group, OK for VGA-only passthrough
- [x] Host NIC still up, SSH/WebUI reachable

### Stability Criteria

All four GPU functions bound to `vfio-pci` after clean boot; host remains fully accessible.

### Notes

`07:00.0` (VGA) and `07:00.1` (Audio) correctly bound to `vfio-pci`. Functions `07:00.2` and `07:00.3` remain on `xhci_hcd`/`nvidia-gpu` — softdep does not cover those drivers. Since each function is now in its own IOMMU group (ACS), this is safe to proceed: only `07:00.0` will be passed to the VM.

---

## Phase 3: Configure VM 109 with PCIe Passthrough

**Status**: ✅ Complete (2026-05-17)
**Prerequisite**: Phase 2 complete — GPU bound to vfio-pci.

**Goal**: Add the GTX 1660 SUPER as a PCIe passthrough device to VM 109, start the VM,
and confirm the GPU is visible inside the guest.

### Deliverables

- [x] **3.1 — Stop VM 109**

  ```bash
  ssh proxmox
  sudo qm stop 109
  ```

- [x] **3.2 — Set VM 109 PCIe passthrough config**

  ```bash
  # Add GPU as primary display PCIe device
  sudo qm set 109 --hostpci0 "0000:07:00.0,pcie=1,x-vga=1"

  # Set vga to none (GPU handles all output)
  sudo qm set 109 --vga none

  # Verify config
  sudo qm config 109 | grep -E "hostpci|vga|machine|bios"
  ```

  Expected config excerpt:

  ```ini
  bios: ovmf
  hostpci0: 0000:07:00.0,pcie=1,x-vga=1
  machine: pc-q35-*
  vga: none
  ```

  > Only pass `07:00.0` (VGA function). The audio/USB functions can be added later if
  > needed — starting with just the display function reduces risk.

- [x] **3.3 — Start VM 109 and watch for host stability**

  > ⚠️ This is the critical test. Keep an eye on host SSH in a separate terminal.

  ```bash
  # Terminal 1 — monitor host
  ssh proxmox "watch -n1 'ip link show | grep -E \"eth|enp|state\"'"

  # Terminal 2 — start VM
  ssh proxmox "sudo qm start 109"
  ```

  If the host network survives, ACS override worked. If the host goes down again, the GPU
  is still in a shared IOMMU group — do NOT retry without fixing the grouping.

- [x] **3.4 — Verify GPU visible in guest**

  ```bash
  # Linux guest (VM 109)
  ssh 192.168.2.20 "lspci | grep -i nvidia && nvidia-smi"

  # Or use Proxmox web UI console to check inside VM 109
  ```

### Verification

- [x] `qm start 109` succeeds without host network loss
- [x] `qm status 109` → `running`
- [x] GPU visible inside VM 109 (`lspci` or Device Manager)
- [x] Host SSH/WebUI reachable during and after VM start
- [x] `lspci -k -s 07:00.0` on host still shows `vfio-pci` (not reclaimed)

### Stability Criteria

VM 109 running with GPU passthrough; host network unaffected; GPU owned by guest.

### Notes

VM 109 was already stopped. Config applied: `hostpci0: 0000:07:00.0,pcie=1,x-vga=1`, `vga: none`. Host NIC (`eno1`) remained `UP` throughout. GPU visible in guest as `01:00.0`.

---

## Phase 4: Guest Driver and Display Verification

**Status**: ✅ Complete (2026-05-17)
**Prerequisite**: Phase 3 complete — VM 109 running, GPU visible in guest.

**Goal**: Install drivers in the guest and confirm a working display on the GTX 1660 SUPER
output port.

### Deliverables

- [x] **4.1 — Install NVIDIA drivers inside VM 109** (if not already present)

  Linux guest:

  ```bash
  # Debian/Ubuntu
  sudo apt install nvidia-driver
  # or use the installer from nvidia.com for the matching version
  ```

  Windows guest: Download and install from [nvidia.com](https://www.nvidia.com/Download/index.aspx).

- [x] **4.2 — Hide KVM from GPU (Windows only, to avoid Code 43)**

  If VM 109 is Windows and NVIDIA reports Code 43 error, add to VM 109 config:

  ```bash
  sudo qm set 109 --cpu "host,hidden=1"
  ```

- [x] **4.3 — Connect display cable to GTX 1660 SUPER port on host**

  Switch the monitor cable from its current port to the GTX 1660 SUPER port.
  Confirm display output appears.

- [x] **4.4 — Run `nvidia-smi` inside VM 109**
  ```bash
  nvidia-smi
  # Expected: shows GTX 1660 SUPER, no errors
  ```

### Verification

- [x] `nvidia-smi` inside guest shows GTX 1660 SUPER
- [x] No Code 43 (Windows) / no NVRM errors (Linux)
- [x] Display output confirmed on GTX 1660 SUPER port
- [x] Host `lspci -k -s 07:00.0` still shows `vfio-pci`

### Stability Criteria

GPU fully functional inside guest with driver; display output confirmed.

### Notes

Driver `580.142` already installed. `nvidia-smi` shows GTX 1660 SUPER at 49°C, 0% util idle, 18MiB/6144MiB VRAM in use. Xorg and GNOME Shell running on the GPU. Linux kernel `6.17.0-23-generic` (Ubuntu 24.04).

---

## Rollback Procedure

If any phase causes host network loss or instability, revert immediately:

```bash
# On Proxmox host (via IPMI, WebUI out-of-band, or physical access):

# 1. Remove GPU from VM 109
sudo qm stop 109
sudo qm set 109 --delete hostpci0 --vga std

# 2. Clear VFIO config
sudo bash -c 'echo "# vfio-pci: no IDs bound by default" > /etc/modprobe.d/vfio.conf'
sudo rm -f /etc/modprobe.d/vfio-nvidia-softdep.conf
sudo sed -i '/^vfio/d' /etc/initramfs-tools/modules

# 3. Remove ACS override from GRUB (edit /etc/default/grub, remove pcie_acs_override)
sudo nano /etc/default/grub
sudo update-grub

# 4. Rebuild initramfs and reboot
sudo update-initramfs -u -k all
sudo reboot
```

---

## Commands Reference

```bash
# SSH to Proxmox
ssh proxmox

# Check IOMMU groups (after ACS override)
find /sys/kernel/iommu_groups/ -type l | sort -V | xargs -I{} sh -c \
  'echo "Group $(basename $(dirname {})):  $(lspci -s $(basename {}))"'

# Check GPU driver binding
for addr in 07:00.0 07:00.1 07:00.2 07:00.3; do
  echo -n "0000:$addr → "
  readlink /sys/bus/pci/devices/0000:$addr/driver | xargs basename
done

# VM 109 operations
sudo qm start 109
sudo qm stop 109
sudo qm config 109
sudo qm status 109
```
