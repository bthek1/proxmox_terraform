# VM 109 — Peripheral Passthrough Map

Full map of how the Proxmox host's peripherals reach VM 109 ("Main" — this workstation) and the LXC containers. Verified live against `qm config 109`, `pct config`, `lspci`/`lsusb` on host and guest on **2026-07-22**.

Companion docs: [109_GPU_PASSTHROUGH.md](109_GPU_PASSTHROUGH.md) (GPU/display stack detail), [PROXMOX_INVENTORY.md](PROXMOX_INVENTORY.md), [Incident/proxmox-vm109-gpu-freeze-incident.md](Incident/proxmox-vm109-gpu-freeze-incident.md) (why the USB controller is passed whole).

---

## Forwarded to VM 109

| Peripheral | Host address / USB ID | Method | Config entry | Appears in guest as |
|---|---|---|---|---|
| NVIDIA GTX 1660 SUPER (all functions: VGA + HDMI audio + USB-C + UCSI) | PCI `08:00.0`–`.3` | PCIe passthrough, primary GPU (`x-vga=1`) | `hostpci0: 0000:08:00` | `01:00.x` |
| AMD HD Audio controller | PCI `10:00.6` | PCIe passthrough | `hostpci1` | `02:00.0` (PipeWire analog-stereo sink) |
| Kensington 2.4G dongle (kb/mouse) | `047d:8188` | Per-device USB redirection (QEMU emulated) | `usb2` | emulated bus |
| Logitech MX Brio 4K webcam | `046d:0944` | Per-device USB redirection (QEMU emulated, 480 Mbps cap → **MJPEG only**, 1080p30 OK) | `usb3` | emulated bus |
| Card reader (MR-K013) | `25a7:fa61` | Per-device USB redirection (QEMU emulated) | `usb4` | emulated bus |
| Bluetooth radio (IMC/Realtek) | `13d3:3571` | Per-device USB redirection (QEMU emulated) | `usb1` | emulated bus, `hci0` |
| UGREEN 2K webcam | `1bcf:2284` | Per-device USB redirection (QEMU emulated, 480 Mbps cap) | `usb5` | emulated bus |

## Stays on the Proxmox host

| Peripheral | Why |
|---|---|
| NVIDIA RTX 3060 (`01:00.0`, `/dev/nvidia0`) | Shared into LXCs 106/107/202/205 via `dev0:`–`dev4:` entries (`nvidia0`, `nvidiactl`, `nvidia-uvm`, `nvidia-uvm-tools`, `nvidia-modeset`, all `mode=0666`) |
| ASUS AURA LED controller (`0b05:19af`) | Host OpenRGB service — must **never** be passed to a VM ([OPENRGB_SERVER_SETUP.md](OPENRGB_SERVER_SETUP.md)) |
| USB 3.2 controller (AMD 600 chipset, `0c:00.0`, ID `1022:43f7`) | **Was** passed whole as `hostpci2` until 2026-07-22. Removed: its event ring corrupted repeatedly under passthrough (dmesg `not part of TD` floods → dead camera streams, stuck mouse), unrecoverable from the guest. Desk devices on its ports are now forwarded per-device instead. |

---

## Design rationale

- **Everything is per-device redirection now (2026-07-22, second revision).** The whole-controller passthrough of `0c:00.0` was tried first (native 5 Gbps, needed for raw YUYV/4K on the Brio) but the controller's xHCI event ring corrupted repeatedly under vfio (`not part of TD` floods; stuck mouse; camera streams returning 0 frames), and no guest-side reset recovers it — only a full VM STOP+START or host reboot. Since only 1080p30 is needed (fits MJPEG over the emulated 480 Mbps path, the same path where BT + UGREEN have been stable), the controller passthrough was dropped in favor of `usb2`–`usb4` forwards.
- **Brio format caveat over emulated USB:** use **MJPEG** (1080p30, 1080p60). Raw YUYV 1080p and 4K modes need more than 480 Mbps and will not work. An earlier incident (Mode C display freeze) happened under emulated redirection while GPU passthrough was also unstable; if freezes recur, see the incident doc before blaming the webcam.
- **`hostpci` must be address-based, not ID-based** (relevant if the controller passthrough is ever restored). `0c:00.0` and the AURA's controller `0e:00.0` share PCI ID `1022:43f7` — adding that ID to `vfio.conf` would steal the AURA controller from the host.
- **All-functions GPU passthrough (2026-07-22):** `hostpci0` changed from `0000:08:00.0` (VGA only) to `0000:08:00` so the guest also gets the HDMI/DP audio function (`08:00.1`, was already vfio-bound and unused) plus the card's USB-C controller (`.2`, no devices attached) and UCSI (`.3`). Enables monitor-speaker audio. Applies on the next **QEMU restart** (see below). Rollback: `sudo qm set 109 -hostpci0 0000:08:00.0,pcie=1,x-vga=1`.

---

## Gotchas

- **`hostpci`/`usb` config changes need a QEMU restart, not a guest reboot.** Use the Proxmox UI *Reboot* button or `sudo qm reboot 109` on the host. A `reboot` from inside the guest restarts the OS but not the QEMU process, so pending changes do not apply.
- **QEMU refuses to start if a `usb-host` entry's device is unplugged.** Keep entries only for permanently attached devices; hot-plug anything else via the web UI.
- **Both cams are capped at USB 2.0** by emulated redirection — use MJPEG. Fine for UGREEN 2K and Brio 1080p30.

---

## Verification

```bash
# Host side (ssh proxmox)
sudo qm config 109 | grep -E 'hostpci|usb'   # hostpci0/1 only; usb1-usb5 entries
lspci -k -s 08:00.0        # expect: vfio-pci
lspci -k -s 0c:00.0        # expect: xhci_hcd (back on host since 2026-07-22)
lsusb                      # all five forwarded devices visible (usbfs), plus AURA LED

# Guest side (this machine)
lsusb                      # Kensington, Brio, card reader, BT, UGREEN — all on emulated buses
nvidia-smi                 # GTX 1660 SUPER
lspci | grep -i audio      # AMD audio at 02:00.0 (+ NVIDIA audio at 01:00.1 after all-functions reboot)
hciconfig                  # hci0 UP RUNNING
ls /dev/video*             # both cameras
```
