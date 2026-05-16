#!/bin/bash
# Phase 1: Fix VFIO binding — correct IDs, initramfs, blacklist nvidia
# Run as root on the Proxmox host: sudo bash phase1_fix_vfio.sh
set -euo pipefail

echo "=== Phase 1: Fix VFIO binding on host ==="
echo ""

# --- 1. Fix /etc/modprobe.d/vfio.conf ---
echo "--- Fixing /etc/modprobe.d/vfio.conf ---"
echo "Current content:"
cat /etc/modprobe.d/vfio.conf 2>/dev/null || echo "(file does not exist)"
echo ""

cat > /etc/modprobe.d/vfio.conf << 'EOF'
options vfio-pci ids=10de:21c4,10de:1aeb,10de:1aec,10de:1aed
EOF
echo "✓ Written: options vfio-pci ids=10de:21c4,10de:1aeb,10de:1aec,10de:1aed"
echo ""

# --- 2. Create blacklist to prevent nvidia driver grabbing GPU at boot ---
echo "--- Creating /etc/modprobe.d/blacklist-nvidia-vfio.conf ---"
cat > /etc/modprobe.d/blacklist-nvidia-vfio.conf << 'EOF'
# Prevent nvidia/nouveau from claiming the GPU before vfio-pci
blacklist nvidia
blacklist nvidiafb
blacklist nouveau
softdep nvidia pre: vfio-pci
softdep nouveau pre: vfio-pci
EOF
echo "✓ Created blacklist-nvidia-vfio.conf"
echo ""

# --- 3. Ensure VFIO modules are in initramfs ---
echo "--- Updating /etc/initramfs-tools/modules ---"
MODULES_FILE=/etc/initramfs-tools/modules

for mod in vfio vfio_pci vfio_pci_core vfio_iommu_type1; do
    if grep -q "^${mod}" "${MODULES_FILE}" 2>/dev/null; then
        echo "  ${mod} already present"
    else
        echo "${mod}" >> "${MODULES_FILE}"
        echo "  Added: ${mod}"
    fi
done
echo ""

# --- 4. Rebuild initramfs ---
echo "--- Rebuilding initramfs for all kernels ---"
update-initramfs -u -k all
echo "✓ initramfs rebuilt"
echo ""

echo "=== Phase 1 complete ==="
echo ""
echo "NEXT STEP: Reboot the Proxmox host, then verify with:"
echo "  lspci -k -s 07:00.0   # should show: Kernel driver in use: vfio-pci"
echo "  lspci -k -s 07:00.1   # should show: Kernel driver in use: vfio-pci"
echo "  lspci -k -s 07:00.2   # should show: Kernel driver in use: vfio-pci"
echo "  lspci -k -s 07:00.3   # should show: Kernel driver in use: vfio-pci"
