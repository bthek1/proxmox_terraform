# GPU Swap Plan — LXC 107 ↔ VM 109

**Goal**: Move the GTX 1660 SUPER from LXC 107 to VM 109 as PCIe passthrough (display), switch the display cable, then reclaim the RTX 3060 from VM 109 and give it to LXC 107 for compute. End result: 107 gets the better GPU, 109 keeps display output.

---

## Current State

| Machine  | Type | GPU access method         | GPU                              | Purpose          |
| -------- | ---- | ------------------------- | -------------------------------- | ---------------- |
| LXC 107  | LXC  | Device node passthrough   | GTX 1660 SUPER (`08:00.0`)       | Compute (AI/ML)  |
| VM 109   | VM   | PCIe passthrough (VFIO)   | RTX 3060 LHR (`01:00.0`)         | Display/graphics |

## Target State (after both parts)

| Machine  | Type | GPU access method         | GPU                              | Purpose          |
| -------- | ---- | ------------------------- | -------------------------------- | ---------------- |
| LXC 107  | LXC  | Device node passthrough   | RTX 3060 LHR (`01:00.0`)         | Compute (AI/ML)  |
| VM 109   | VM   | PCIe passthrough (VFIO)   | GTX 1660 SUPER (`08:00.0`)       | Display/graphics |

> Part 1 adds GTX 1660 SUPER to VM 109 for display (so the cable can be switched off the RTX 3060). Part 2 releases the RTX 3060 from VM 109 and hands it to LXC 107 for compute.

---

## ⚠️ Important Constraint

**VM 109 is the active workstation** (the machine running this VS Code session). Stopping it ends the current desktop session. All Proxmox host commands must be run via SSH from within VM 109 **before** it is shut down, or from the **Proxmox web UI shell** after it goes down.

**Before starting Part 1:**
- Save all work on VM 109
- Open an SSH session to the Proxmox host: `ssh proxmox`
- Keep a Proxmox web UI console open as a fallback
- Be ready to lose the VM 109 desktop session when `qm stop 109` is run

---

## Part 1: Add GTX 1660 SUPER to VM 109 as PCIe Passthrough (Display Takeover)

**Status**: Not started

**Goal**: Remove GTX 1660 SUPER from LXC 107's device node config, bind it to `vfio-pci`, assign it to VM 109 as a PCIe passthrough display device, and switch the display cable from the RTX 3060 port to the GTX 1660 SUPER port.

> **Why necessary**: VFIO PCIe passthrough is exclusive — the host NVIDIA driver must release the GTX 1660 SUPER before VM 109 can own it. We do this in Part 1 so 109 has a working display while Part 2 frees the RTX 3060.

### Deliverables

- [ ] **1.1 — SSH into the Proxmox host from VM 109 before shutting down**
  ```bash
  # Run this from VM 109 while it's still up
  ssh proxmox
  ```
  All steps 1.2–1.4 are run over this SSH session. Step 1.5 (editing 109.conf) can also be done now while the VM is still running — config changes take effect on next start.

- [ ] **1.2 — Stop LXC 107**
  ```bash
  pct stop 107
  ```

- [ ] **1.3 — Remove GTX 1660 SUPER from LXC 107 device node config**

  Edit `/etc/pve/lxc/107.conf` on the Proxmox host. With only the 1660 SUPER, the relevant lines will reference `/dev/nvidia0` (the sole NVIDIA device). Remove all nvidia device node entries:
  ```ini
  # Remove these lines (GTX 1660 SUPER — currently the only GPU for 107):
  # lxc.cgroup2.devices.allow: c 195:* rwm
  # lxc.cgroup2.devices.allow: c 507:* rwm
  # lxc.mount.entry: /dev/nvidia0 dev/nvidia0 none bind,optional,create=file
  # lxc.mount.entry: /dev/nvidiactl dev/nvidiactl none bind,optional,create=file
  # lxc.mount.entry: /dev/nvidia-modeset dev/nvidia-modeset none bind,optional,create=file
  # lxc.mount.entry: /dev/nvidia-uvm dev/nvidia-uvm none bind,optional,create=file
  # lxc.mount.entry: /dev/nvidia-uvm-tools dev/nvidia-uvm-tools none bind,optional,create=file
  ```
  > LXC 107 will have no GPU access until Part 2. This is expected.

- [ ] **1.4 — Stop the nvidia-devices service and unload NVIDIA host driver**
  ```bash
  systemctl stop nvidia-devices.service
  modprobe -r nvidia_uvm nvidia_modeset nvidia
  ```
  Verify:
  ```bash
  lsmod | grep nvidia   # should return empty (i2c_nvidia_gpu is acceptable)
  ```

- [ ] **1.5 — Bind GTX 1660 SUPER to vfio-pci**

  Find the vendor:device IDs for the GTX 1660 SUPER:
  ```bash
  lspci -nn | grep "08:00"
  # Example output:
  #   08:00.0 VGA compatible controller [0300]: NVIDIA GTX 1660 SUPER [10de:21c4]
  #   08:00.1 Audio device [10de:1aeb]
  ```

  Bind both functions (GPU + audio) to `vfio-pci`:
  ```bash
  echo "0000:08:00.0" > /sys/bus/pci/drivers/nvidia/unbind
  echo "0000:08:00.0" > /sys/bus/pci/drivers/vfio-pci/bind
  echo "0000:08:00.1" > /sys/bus/pci/drivers/snd_hda_intel/unbind
  echo "0000:08:00.1" > /sys/bus/pci/drivers/vfio-pci/bind
  ```

  Verify:
  ```bash
  lspci -k -s 08:00.0   # Kernel driver in use: vfio-pci
  ```

- [ ] **1.6 — Add GTX 1660 SUPER PCIe passthrough to VM 109 config**

  VM 109 currently has the RTX 3060 as `hostpci0`. Add the GTX 1660 SUPER as a second passthrough device in `/etc/pve/qemu-server/109.conf`:
  ```ini
  hostpci1: 0000:08:00.0,pcie=1
  ```
  > Do **not** use `x-vga=1` here yet — the RTX 3060 is still the primary display GPU for Part 1. The GTX 1660 SUPER becomes `hostpci0` with `x-vga=1` in Part 2.

  This config edit can be done while 109 is still running — it takes effect on next start.

- [ ] **1.7 — Save work and shut down VM 109**

  > ⚠️ This step ends the current desktop session on VM 109.

  ```bash
  # From the SSH session on the Proxmox host:
  qm stop 109
  ```

- [ ] **1.8 — Start VM 109, confirm GTX 1660 SUPER is visible**
  ```bash
  qm start 109
  ```
  Inside VM 109, verify the second GPU appears (Device Manager on Windows, or `lspci | grep NVIDIA` on Linux).

- [ ] **1.9 — Install GTX 1660 SUPER drivers inside VM 109 (if needed)**

  If VM 109 is Windows: install NVIDIA drivers so the 1660 SUPER is fully functional.
  If VM 109 is Linux: drivers should auto-detect. Confirm with `nvidia-smi`.

- [ ] **1.10 — Switch display cable**

  Connect the monitor cable to the **GTX 1660 SUPER** port on the host. Confirm the display is active on that GPU in the VM.

### Verification

- [ ] `qm status 109` shows `running`
- [ ] GTX 1660 SUPER visible and working inside VM 109
- [ ] Display output confirmed on GTX 1660 SUPER port
- [ ] `pct status 107` shows stopped (expected — no GPU until Part 2)

### Notes

_Fill in when completing this phase: GTX 1660 SUPER vendor IDs, actual hostpci line used, Windows/Linux driver notes._

---

## Part 2: Release RTX 3060 from VM 109, Assign to LXC 107

**Status**: Not started  
**Prerequisite**: Part 1 complete — GTX 1660 SUPER display confirmed on VM 109, cable switched.

**Goal**: Remove the RTX 3060 PCIe passthrough from VM 109, reload the NVIDIA host driver for it, and configure LXC 107 with device node passthrough to the RTX 3060. VM 109 switches to using the GTX 1660 SUPER as its sole display GPU.

### Deliverables

- [ ] **2.1 — Stop VM 109**
  ```bash
  qm stop 109
  ```

- [ ] **2.2 — Reconfigure VM 109: remove RTX 3060, promote GTX 1660 SUPER to primary**

  Edit `/etc/pve/qemu-server/109.conf`:
  ```ini
  # Remove RTX 3060:
  # hostpci0: 0000:01:00.0,pcie=1,x-vga=1

  # Promote GTX 1660 SUPER to primary display GPU:
  hostpci0: 0000:08:00.0,pcie=1,x-vga=1
  ```

  Also ensure `vga: none` is set so the VM uses the passthrough GPU output:
  ```ini
  vga: none
  ```

- [ ] **2.3 — Unbind RTX 3060 from vfio-pci**
  ```bash
  echo "0000:01:00.0" > /sys/bus/pci/drivers/vfio-pci/unbind
  echo "0000:01:00.1" > /sys/bus/pci/drivers/vfio-pci/unbind
  ```

- [ ] **2.4 — Reload NVIDIA host driver and recreate device nodes**
  ```bash
  modprobe nvidia
  modprobe nvidia_uvm
  modprobe nvidia_modeset
  systemctl start nvidia-devices.service
  ```

  Verify device nodes exist:
  ```bash
  ls -la /dev/nvidia*
  # Expected: nvidia0 (RTX 3060), nvidiactl, nvidia-modeset, nvidia-uvm, nvidia-uvm-tools
  # Note: GTX 1660 SUPER is now owned by VFIO — it will NOT appear as nvidia1
  ```

- [ ] **2.5 — Configure LXC 107 with RTX 3060 device node passthrough**

  Edit `/etc/pve/lxc/107.conf`:
  ```ini
  # cgroup2 device access
  lxc.cgroup2.devices.allow: c 195:* rwm   # /dev/nvidia*
  lxc.cgroup2.devices.allow: c 507:* rwm   # /dev/nvidia-uvm*

  # bind mounts — RTX 3060 (now nvidia0)
  lxc.mount.entry: /dev/nvidia0 dev/nvidia0 none bind,optional,create=file
  lxc.mount.entry: /dev/nvidiactl dev/nvidiactl none bind,optional,create=file
  lxc.mount.entry: /dev/nvidia-modeset dev/nvidia-modeset none bind,optional,create=file
  lxc.mount.entry: /dev/nvidia-uvm dev/nvidia-uvm none bind,optional,create=file
  lxc.mount.entry: /dev/nvidia-uvm-tools dev/nvidia-uvm-tools none bind,optional,create=file
  ```

- [ ] **2.6 — Start LXC 107 and VM 109**
  ```bash
  pct start 107
  qm start 109
  ```

- [ ] **2.7 — Make GTX 1660 SUPER VFIO binding persistent on host**

  Add to `/etc/modprobe.d/vfio.conf` (find the IDs from the output recorded in Part 1 step 1.4):
  ```
  options vfio-pci ids=10de:<1660-gpu-id>,10de:<1660-audio-id>
  ```

  Update initramfs so the binding survives reboots:
  ```bash
  update-initramfs -u
  ```

  Reboot the host and verify both machines come up correctly.

### Verification

- [ ] `qm status 109` shows `running`
- [ ] Display output confirmed on GTX 1660 SUPER port (after reboot)
- [ ] `pct status 107` shows `running`
- [ ] `nvidia-smi` inside LXC 107 shows RTX 3060
- [ ] VM 109 display still works after full host reboot (persistent VFIO binding confirmed)

### Notes

_Fill in when completing this phase: actual /dev/nvidia* nodes created, final 107.conf lines, reboot test results._

---

## Final State

| Machine  | GPU              | Access method             | Purpose            |
| -------- | ---------------- | ------------------------- | ------------------ |
| LXC 107  | RTX 3060 LHR     | Device node passthrough   | Compute (AI/ML)    |
| VM 109   | GTX 1660 SUPER   | PCIe passthrough (VFIO)   | Display/graphics   |

> GTX 1660 SUPER is exclusively claimed by VFIO for VM 109's display. RTX 3060 is held by the host NVIDIA driver and shared into LXC 107 via device nodes (non-exclusive, compute only).

---

## Reference

- [109_GPU_SETUP.md](../109_GPU_SETUP.md) — host driver, device nodes, architecture
- [107_GPU_PASSTHROUGH_SETUP.md](../107_GPU_PASSTHROUGH_SETUP.md) — LXC device node config
- [LXC_107_NVIDIA_MODESET_ERROR.md](../LXC_107_NVIDIA_MODESET_ERROR.md) — common failure diagnosis
- Proxmox VFIO docs: https://pve.proxmox.com/wiki/PCI_Passthrough
