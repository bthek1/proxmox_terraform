# VM 109 — Peripheral Passthrough Map

Full map of how the Proxmox host's peripherals reach VM 109 ("Main" — this workstation) and the LXC containers. Verified live against `qm config 109`, `pct config`, `lspci`/`lsusb` on host and guest on **2026-07-22**.

Companion docs: [109_GPU_PASSTHROUGH.md](109_GPU_PASSTHROUGH.md) (GPU/display stack detail), [PROXMOX_INVENTORY.md](PROXMOX_INVENTORY.md), [Incident/proxmox-vm109-gpu-freeze-incident.md](Incident/proxmox-vm109-gpu-freeze-incident.md) (why the USB controller is passed whole).

---

## Forwarded to VM 109

| Peripheral | Host address / USB ID | Method | Config entry | Appears in guest as |
|---|---|---|---|---|
| NVIDIA GTX 1660 SUPER (all functions: VGA + HDMI audio + USB-C + UCSI) | PCI `08:00.0`–`.3` | PCIe passthrough, primary GPU (`x-vga=1`) | `hostpci0: 0000:08:00` | `01:00.x` |
| AMD HD Audio controller | PCI `10:00.6` | PCIe passthrough | `hostpci1` | `02:00.0` (PipeWire analog-stereo sink) |
| USB 3.2 controller (ASMedia `1022:43f7`, IOMMU group 33) | PCI `0c:00.0` | **Whole-controller** PCIe passthrough | `hostpci2` | `03:00.0` → guest buses 009 (USB2) / 010 (USB3, 20 Gbps) |
| Logitech MX Brio 4K webcam | `046d:0944` | Plugged into the passed-through controller's **USB3 port** — native 5 Gbps, no config entry | via `hostpci2` | guest bus 010 |
| Kensington 2.4G dongle (kb/mouse) | `047d:8188` | Plugged into the passed-through controller — native, no config entry | via `hostpci2` | guest bus 009 |
| Card reader (MR-K013) | `25a7:fa61` | Plugged into the passed-through controller — native, no config entry | via `hostpci2` | guest bus 009 |
| Bluetooth radio (IMC/Realtek) | `13d3:3571` | Per-device USB redirection (QEMU emulated) | `usb1` | guest bus 011, `hci0` |
| UGREEN 2K webcam | `1bcf:2284` | Per-device USB redirection (QEMU emulated, 480 Mbps cap) | `usb5` | guest bus 011 |

## Stays on the Proxmox host

| Peripheral | Why |
|---|---|
| NVIDIA RTX 3060 (`01:00.0`, `/dev/nvidia0`) | Shared into LXCs 106/107/202/205 via `dev0:`–`dev4:` entries (`nvidia0`, `nvidiactl`, `nvidia-uvm`, `nvidia-uvm-tools`, `nvidia-modeset`, all `mode=0666`) |
| ASUS AURA LED controller (`0b05:19af`) | Host OpenRGB service — must **never** be passed to a VM ([OPENRGB_SERVER_SETUP.md](OPENRGB_SERVER_SETUP.md)) |

---

## Design rationale

- **Two USB forwarding styles coexist deliberately.** Devices on the passed-through `0c:00.0` controller get native speed/latency and are invisible to the host. Bluetooth and the UGREEN cam stay as per-device redirection because their host controller also carries the AURA LED, which must remain host-side — that controller can therefore never be passed whole.
- **MX Brio must ride the passed-through controller.** Under emulated redirection it triggered display freezes (see incident doc, Mode C). Its old `usb2`/`usb3` entries were removed 2026-07-22; do not re-add them.
- **`hostpci` must be address-based, not ID-based.** `0c:00.0` and the AURA's controller `0e:00.0` share PCI ID `1022:43f7` — adding that ID to `vfio.conf` would steal the AURA controller from the host.
- **All-functions GPU passthrough (2026-07-22):** `hostpci0` changed from `0000:08:00.0` (VGA only) to `0000:08:00` so the guest also gets the HDMI/DP audio function (`08:00.1`, was already vfio-bound and unused) plus the card's USB-C controller (`.2`, no devices attached) and UCSI (`.3`). Enables monitor-speaker audio. Applies on the next **QEMU restart** (see below). Rollback: `sudo qm set 109 -hostpci0 0000:08:00.0,pcie=1,x-vga=1`.

---

## Gotchas

- **`hostpci`/`usb` config changes need a QEMU restart, not a guest reboot.** Use the Proxmox UI *Reboot* button or `sudo qm reboot 109` on the host. A `reboot` from inside the guest restarts the OS but not the QEMU process, so pending changes do not apply.
- **QEMU refuses to start if a `usb-host` entry's device is unplugged.** Keep entries only for permanently attached devices (`13d3:3571`, `1bcf:2284`); hot-plug anything else via the web UI.
- **UGREEN cam is capped at USB 2.0** by emulated redirection — fine for MJPEG 2K. For native speed, move it to a port on the passed-through controller and delete `usb5`.

---

## Verification

```bash
# Host side (ssh proxmox)
sudo qm config 109 | grep -E 'hostpci|usb'
lspci -k -s 08:00.0        # expect: vfio-pci
lspci -k -s 0c:00.0        # expect: vfio-pci
lsusb                      # BT + UGREEN visible (usbfs), Brio/Kensington/reader NOT visible

# Guest side (this machine)
lsusb -t                   # Brio at 5000M on bus 010; dongles on 009; BT+UGREEN on 011
nvidia-smi                 # GTX 1660 SUPER
lspci | grep -i audio      # AMD audio at 02:00.0 (+ NVIDIA audio at 01:00.1 after all-functions reboot)
hciconfig                  # hci0 UP RUNNING
ls /dev/video*             # both cameras
```
