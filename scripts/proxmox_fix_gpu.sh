#!/bin/bash
# Run as root on the Proxmox host:
#   bash /tmp/proxmox_fix_gpu.sh
set -e

echo "=== [1/4] Checking LXC 107 for existing nvidia entries ==="
if grep -qi "nvidia\|195:\|504:\|507:" /etc/pve/lxc/107.conf; then
    echo "Already present — skipping add."
    grep -i "nvidia\|195:\|504:\|507:" /etc/pve/lxc/107.conf
else
    echo "None found — adding RTX 3060 passthrough..."
    cat >> /etc/pve/lxc/107.conf << 'EOF'
lxc.cgroup2.devices.allow: c 195:* rwm
lxc.cgroup2.devices.allow: c 504:* rwm
lxc.mount.entry: /dev/nvidia0 dev/nvidia0 none bind,optional,create=file
lxc.mount.entry: /dev/nvidiactl dev/nvidiactl none bind,optional,create=file
lxc.mount.entry: /dev/nvidia-modeset dev/nvidia-modeset none bind,optional,create=file
lxc.mount.entry: /dev/nvidia-uvm dev/nvidia-uvm none bind,optional,create=file
lxc.mount.entry: /dev/nvidia-uvm-tools dev/nvidia-uvm-tools none bind,optional,create=file
EOF
    echo "Done."
fi

echo ""
echo "=== [2/4] Fixing VM 109 hostpci address (07:00.0 -> 08:00.0) ==="
qm set 109 --hostpci0 "0000:08:00.0,pcie=1,x-vga=1"
echo "VM 109 hostpci updated: $(grep hostpci0 /etc/pve/qemu-server/109.conf)"

echo ""
echo "=== [3/4] Restarting LXC 107 ==="
pct stop 107
pct start 107
echo "LXC 107 restarted."

echo ""
echo "=== [4/4] Starting VM 109 ==="
qm start 109
echo "VM 109 start issued."

echo ""
echo "=== Done. Verifying ==="
echo "LXC 107 status: $(pct status 107)"
echo "VM 109 status:  $(qm status 109)"
sleep 5
echo "VM 109 status (5s later): $(qm status 109)"
