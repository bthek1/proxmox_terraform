#!/bin/bash
# GPU Swap Part 1a: Prep GTX 1660 SUPER for VFIO passthrough to VM 109
# Run as root on the Proxmox host
set -euo pipefail

echo "===== GPU SWAP PART 1A ====="
echo ""

echo "--- 1.2: Stopping LXC 107 ---"
pct stop 107
echo "LXC 107 stopped."

echo ""
echo "--- 1.3: Removing GPU entries from 107.conf ---"
sed -i '/^# NVIDIA GTX 1660 SUPER/d'              /etc/pve/lxc/107.conf
sed -i '/^dev[0-4]: \/dev\/nvidia/d'               /etc/pve/lxc/107.conf
sed -i '/^lxc\.cgroup2\.devices\.allow: c 195/d'  /etc/pve/lxc/107.conf
sed -i '/^lxc\.cgroup2\.devices\.allow: c 504/d'  /etc/pve/lxc/107.conf
echo "107.conf after edit:"
cat /etc/pve/lxc/107.conf

echo ""
echo "--- 1.4: Stopping nvidia-devices service ---"
systemctl stop nvidia-devices.service 2>/dev/null && echo "Stopped." || echo "(not found, skipping)"

echo ""
echo "--- 1.4: Unloading NVIDIA host modules ---"
modprobe -r nvidia_uvm    2>/dev/null && echo "  nvidia_uvm removed"    || echo "  nvidia_uvm not loaded"
modprobe -r nvidia_modeset 2>/dev/null && echo "  nvidia_modeset removed" || echo "  nvidia_modeset not loaded"
modprobe -r i2c_nvidia_gpu 2>/dev/null && echo "  i2c_nvidia_gpu removed" || echo "  i2c_nvidia_gpu not loaded"
modprobe -r nvidia         2>/dev/null && echo "  nvidia removed"         || echo "  nvidia not loaded"
echo "Remaining nvidia modules:"
lsmod | grep nvidia || echo "  (none)"

echo ""
echo "--- 1.5: Loading vfio-pci ---"
modprobe vfio-pci
echo "vfio-pci loaded."

echo ""
echo "--- 1.5: Unbinding 08:00.1 (snd_hda_intel) ---"
if [ -e /sys/bus/pci/devices/0000:08:00.1/driver ]; then
    echo "0000:08:00.1" > /sys/bus/pci/devices/0000:08:00.1/driver/unbind
    echo "  Unbound 08:00.1"
else
    echo "  Already unbound"
fi

echo "--- 1.5: Unbinding 08:00.2 (xhci_hcd) ---"
if [ -e /sys/bus/pci/devices/0000:08:00.2/driver ]; then
    echo "0000:08:00.2" > /sys/bus/pci/devices/0000:08:00.2/driver/unbind
    echo "  Unbound 08:00.2"
else
    echo "  Already unbound"
fi

echo "--- 1.5: Binding all GTX 1660 SUPER functions to vfio-pci ---"
for dev in 0000:08:00.0 0000:08:00.1 0000:08:00.2 0000:08:00.3; do
    echo "vfio-pci" > /sys/bus/pci/devices/$dev/driver_override
    if echo "$dev" > /sys/bus/pci/drivers/vfio-pci/bind 2>/dev/null; then
        echo "  Bound $dev to vfio-pci"
    else
        echo "  WARNING: failed to bind $dev (check IOMMU group)"
    fi
done

echo ""
echo "--- 1.5: Verifying GTX 1660 SUPER bindings ---"
lspci -k -s 08:00

echo ""
echo "--- 1.6: Adding GTX 1660 SUPER to VM 109 config as hostpci2 ---"
if grep -q "^hostpci2:" /etc/pve/qemu-server/109.conf; then
    echo "  hostpci2 already present, skipping"
else
    echo "hostpci2: 0000:08:00,pcie=1" >> /etc/pve/qemu-server/109.conf
    echo "  Added hostpci2 to 109.conf"
fi
echo "Current hostpci lines in 109.conf:"
grep "^hostpci" /etc/pve/qemu-server/109.conf

echo ""
echo "===== PART 1A COMPLETE ====="
echo ""
echo "Next: when ready to lose VM 109 desktop, run Part 1b:"
echo "  sudo qm stop 109 && sudo qm start 109"
