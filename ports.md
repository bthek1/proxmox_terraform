# Rear USB ports → controller map (VM 109 host)

Mapped 2026-07-24 from live link-speed observations. Controller PCI addresses are host-side.
⚠️ Host USB **bus numbers renumber across host reboots** (chipset moved buses 1/2 → 3/4 after the Mode E crash-loop reboots) — identify by PCI address, not bus number.

| Physical block | Controller | Host buses (current) | Speed | Notes |
|---|---|---|---|---|
| 2× USB-A (light blue) | `0c:00.0` chipset xHCI | 3 (480M) / 4 (SS) | 5 Gbps | |
| 1× USB-C + 1× USB-A (light blue) | `0c:00.0` chipset xHCI | 3 / 4 | USB-C is the 20 Gbps (gen2x2) port | host udev rule `90-usbc-port-force-usb2.rules` (Brio-era SS-disable) still exists but is moot — Brio refunded — and likely inert after the bus renumber; remove/fix if the USB-C port misbehaves |
| 4× USB-A (dark blue) | mixed: socket #1 → `0c:00.0` (USB2-only wiring); #2/#3 → `10:00.4`; #4 → `10:00.3` | 3, 9/10, 7/8 | 10 Gbps on the CPU pairs | ⛔ `10:00.3`/`10:00.4` are **host-fatal to pass through** (Mode E) — their sockets are fine to *use*, but only for host-forwarded devices, and never at SS for the Brio |
| 2× USB-A (black) | `0c:00.0` chipset xHCI (USB2-only wiring) | 3 only | 480 Mbps max | fine for any forwarded USB2 device (current cams are native USB2, so any port works) |

Front-panel / internal (AURA LED, Bluetooth — bus 5) hang off `0e:00.0` — never pass that controller (AURA must stay host-side for OpenRGB).

# Current connections (2026-07-24 evening, post-Mode-E revert)

| Socket | Device | Host port | Speed | Status |
|---|---|---|---|---|
| dark blue #1 (`0c:00.0`, USB2-only) | Mouse (Compx 2.4G receiver) | 3-5 | 12M | OK, forwarded (`usb4`) |
| chipset ports (`0c:00.0`, bus 3) | **Brio 500** (`046d:0943`, port 3-1, USB-C→A) — sole VM 109 camera | 3-1 | 480M | → VM 109 (`usb5` forward; verified: 30fps 1080p even dim, mic clean under load). C922 removed & unplugged 2026-07-25 (spare) |
| `10:00.4` USB2 side | **UGREEN 2K** (`1bcf:2284`) | 9-1 | 480M | → **LXC 205** (host-owned; video+mic nodes passed as `dev5`–`dev9`) |
| dark blue #4 (`10:00.3`) | Keyboard (Kensington dongle) | 7-2 | 12M | OK, forwarded (`usb2`) |

# Outcome of the native-SS plan — ⛔ DO NOT RETRY

The 2026-07-24 attempt to pass `10:00.4` as `hostpci2` **hard-reset the entire Proxmox host on VM start** and crash-looped it on every boot (autostart retried VM 109) until `startall` was killed over SSH. Reverted same day. The advertised `pm` reset on `10:00.3`/`10:00.4` is broken in hardware. Full write-up: [incident doc, Mode E](docs/Incident/proxmox-vm109-gpu-freeze-incident.md).

**Webcam rule on this box: USB2 + MJPEG + per-device redirection, always.** Native SuperSpeed is exhausted: chipset `0c:00.0` passthrough corrupts (Mode C), CPU xHCI passthrough kills the host (Mode E), and SS through the QEMU forward delivers no frames. Resolved 2026-07-24 by hardware: the Brio was refunded; the C922 and UGREEN are native-USB2 devices with no SS modes to go wrong. (The USB-C SS-disable udev rule `90-usbc-port-force-usb2.rules` is now moot — Brio gone — and was likely inert after the bus renumber anyway; remove or fix if the USB-C port is ever needed.)
