#!/bin/bash
# Phase 0: Remove existing GPU PCIe passthrough from VM 109
# Run as root on the Proxmox host: sudo bash phase0_remove_old_gpu.sh
set -euo pipefail

VM_ID=109

echo "=== Phase 0: Remove old GPU passthrough from VM ${VM_ID} ==="
echo ""

# Show current config
echo "--- Current VM ${VM_ID} config ---"
qm config ${VM_ID}
echo ""

# Stop VM if running
STATUS=$(qm status ${VM_ID} | awk '{print $2}')
if [ "${STATUS}" = "running" ]; then
    echo "Stopping VM ${VM_ID}..."
    qm stop ${VM_ID}
    echo "Waiting for VM to stop..."
    sleep 5
else
    echo "VM ${VM_ID} is not running (status: ${STATUS})"
fi

# Remove all hostpci entries (0 through 9 to be safe)
echo ""
echo "Removing all hostpci entries..."
for i in 0 1 2 3 4 5 6 7 8 9; do
    if qm config ${VM_ID} | grep -q "^hostpci${i}:"; then
        echo "  Deleting hostpci${i}..."
        qm set ${VM_ID} --delete "hostpci${i}"
    fi
done

# Set VGA to none
echo "Setting vga to none..."
qm set ${VM_ID} --vga none

echo ""
echo "--- Updated VM ${VM_ID} config ---"
qm config ${VM_ID}
echo ""

# Verify
if qm config ${VM_ID} | grep -q "^hostpci"; then
    echo "ERROR: hostpci entries still present!"
    exit 1
else
    echo "✓ All hostpci entries removed"
fi

if qm config ${VM_ID} | grep -q "^vga: none"; then
    echo "✓ vga set to none"
fi

echo ""
echo "=== Phase 0 complete ==="
