# OpenRGB Server on the Proxmox Host

Control the motherboard RGB over the network. OpenRGB runs as a systemd service on
the Proxmox **host** (`bthek1`, 192.168.2.70) and exposes a TCP server on **:6742**.
Any client — Home Assistant, VM 109, a laptop — connects over the LAN; nothing needs
USB passthrough. **Set up and verified live on 2026-06-23.**

## What's on this host

- **Board:** ASUS PRIME X670-P WIFI.
- **RGB controllers OpenRGB drives (3):**
  - `0: ENE DRAM` — SMBus, `/dev/i2c-2` @ 0x71 (RGB RAM stick)
  - `1: ENE DRAM` — SMBus, `/dev/i2c-2` @ 0x73 (RGB RAM stick)
  - `2: ASUS PRIME X670-P WIFI` — ASUS **Aura** USB controller `0b05:19af`, via `/dev/hidraw0`
- **OS:** Debian 13 (trixie). `openrgb` is **not** in this host's apt repos, so we run
  the upstream **AppImage** (extracted to `/opt/openrgb/squashfs-root`, bundles Qt — no
  trixie dependency issues).

## Why on the host (not a VM/LXC)

The Aura controller is a USB HID device the host owns. A **VM** can only get it via
*exclusive* USB passthrough (it was passed to VM 109 originally — that's why the host
couldn't see it). Running OpenRGB on the host keeps the device shared and lets every
client reach it over the network. Contrast with exclusive PCI passthrough in
[109_GPU_PASSTHROUGH.md](109_GPU_PASSTHROUGH.md).

> **Do not USB-pass the Aura controller (`0b05:19af`) to VM 109 again.** If you do,
> QEMU claims it via `usbfs`, the host's `usbhid` can't bind it, no `/dev/hidraw`
> node appears, and OpenRGB sees only the DRAM. It was removed from 109 on 2026-06-23.

## The usbhid gotcha (why there's a bind hook)

OpenRGB's Aura driver needs a `/dev/hidraw` node, which only exists when the kernel's
`usbhid` driver is bound to the controller's HID interface (class 03). If anything
ever detaches it (a prior VM passthrough, a manual libusb grab), the interface is left
unbound and no hidraw node returns on its own. So the service runs
[scripts/bind-aura-hid.sh](../scripts/bind-aura-hid.sh) as `ExecStartPre` — it finds
`0b05:19af` and (re)binds its HID interface to `usbhid` before the server launches.
Idempotent; a no-op once correctly bound (the normal state after a clean boot with no
passthrough).

## Install

```bash
scp scripts/openrgb_server_setup.sh scripts/bind-aura-hid.sh root@192.168.2.70:/tmp/
ssh root@192.168.2.70 'cd /tmp && bash openrgb_server_setup.sh'
```

Installs the AppImage + bind helper to `/opt/openrgb`, loads `i2c-dev`, writes
`/etc/systemd/system/openrgb.service`, enables and starts it.

## Verify / control from the CLI

```bash
ssh root@192.168.2.70 'systemctl status openrgb'
ssh root@192.168.2.70 '/opt/openrgb/squashfs-root/AppRun --list-devices'   # expect 3 devices
# quick visible test — all RGB green, then off:
ssh root@192.168.2.70 '/opt/openrgb/squashfs-root/AppRun --mode static --color 00FF00'
ssh root@192.168.2.70 '/opt/openrgb/squashfs-root/AppRun --mode static --color 000000'
```

## Connect from Home Assistant

OpenRGB integration → **host `192.168.2.70`, port `6742`**. (No HA guest exists in
[PROXMOX_INVENTORY.md](PROXMOX_INVENTORY.md) yet; the server is ready for one.)

## Security note

`openrgb --server` has **no authentication** and binds `0.0.0.0:6742` — fine on a
trusted LAN. To restrict it to only the HA host:

```bash
iptables -A INPUT -p tcp --dport 6742 -s <HA_IP> -j ACCEPT
iptables -A INPUT -p tcp --dport 6742 -j DROP
```

## Default lighting at boot (optional)

The server only relays control; LEDs change when a client sets them. To apply a saved
profile on boot, create it once (`AppRun --profile <name> ...` or the GUI), then add
`--profile <name>` to `ExecStart` in the unit and `systemctl daemon-reload && systemctl restart openrgb`.
