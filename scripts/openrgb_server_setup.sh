#!/usr/bin/env bash
# openrgb_server_setup.sh — install OpenRGB (AppImage) and run it as a host
# systemd service that exposes the motherboard RGB over the network (TCP :6742).
#
# Run this ON THE PROXMOX HOST (192.168.2.70 / bthek1) as root:
#   scp scripts/openrgb_server_setup.sh scripts/bind-aura-hid.sh root@host:/tmp/
#   ssh root@host 'bash /tmp/openrgb_server_setup.sh'
#
# Notes for this host (verified 2026-06-23):
#   - OS is Debian 13 (trixie); `openrgb` is NOT in the configured apt repos, so we
#     use the self-contained AppImage (bundles Qt — no dependency breakage).
#   - Board: ASUS PRIME X670-P WIFI. RGB is exposed three ways OpenRGB can drive:
#     2x ENE DRAM (SMBus /dev/i2c-2) + the ASUS Aura USB controller (0b05:19af, HID).
#   - The Aura controller must NOT be USB-passed-through to VM 109 — if it is, QEMU
#     claims it via usbfs and the host can't see it. It was removed from 109 on
#     2026-06-23. bind-aura-hid.sh re-binds its HID interface to usbhid on each start.
set -euo pipefail

PORT="${OPENRGB_PORT:-6742}"
DEST=/opt/openrgb
URL="https://openrgb.org/releases/release_0.9/OpenRGB_0.9_x86_64_b5f46e3.AppImage"
UNIT=/etc/systemd/system/openrgb.service
HERE="$(cd "$(dirname "$0")" && pwd)"

[[ $EUID -eq 0 ]] || { echo "ERROR: run as root on the Proxmox host." >&2; exit 1; }

echo "==> Fetching AppImage to $DEST"
mkdir -p "$DEST"
curl -fsSL -o "$DEST/OpenRGB.AppImage" "$URL"
chmod +x "$DEST/OpenRGB.AppImage"

echo "==> Extracting (avoids FUSE dependency)"
rm -rf "$DEST/squashfs-root"
( cd "$DEST" && ./OpenRGB.AppImage --appimage-extract >/dev/null )
RUN="$DEST/squashfs-root/AppRun"
test -x "$RUN"

echo "==> Installing HID-bind helper"
install -m 0755 "$HERE/bind-aura-hid.sh" "$DEST/bind-aura-hid.sh"

echo "==> i2c-dev at boot (for the SMBus DRAM controllers)"
echo i2c-dev > /etc/modules-load.d/openrgb.conf
modprobe i2c-dev || true

echo "==> Writing $UNIT"
cat > "$UNIT" <<EOF
[Unit]
Description=OpenRGB server (motherboard RGB control over network)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=-/sbin/modprobe i2c-dev
ExecStartPre=$DEST/bind-aura-hid.sh
# --server binds 0.0.0.0:${PORT} by default. No auth — keep it on a trusted LAN.
ExecStart=$RUN --server --server-port ${PORT}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

echo "==> Enable + start"
systemctl daemon-reload
systemctl enable --now openrgb.service
sleep 3
systemctl --no-pager --full status openrgb.service | head -10 || true

echo
echo "==> Devices visible to clients:"
"$RUN" --list-devices 2>/dev/null | grep -E "^[0-9]+:|Location:" || true

echo
echo "Done. Home Assistant → OpenRGB integration → host 192.168.2.70, port ${PORT}"
