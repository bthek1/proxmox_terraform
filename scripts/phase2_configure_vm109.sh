#!/bin/bash
# Phase 2: Configure VM 109 with GTX 1660 SUPER PCIe passthrough
# Run as root on the Proxmox host AFTER reboot (post Phase 1)
# Usage: sudo bash phase2_configure_vm109.sh
set -euo pipefail

VM_ID=109

echo "=== Phase 2: Configure VM ${VM_ID} PCIe passthrough ==="
echo ""

# --- Pre-flight: verify GPU is bound to vfio-pci ---
echo "--- Pre-flight: checking GPU driver binding ---"
for addr in 07:00.0 07:00.1 07:00.2 07:00.3; do
    DRIVER=$(readlink /sys/bus/pci/devices/0000:${addr}/driver 2>/dev/null | xargs basename 2>/dev/null || echo "none")
    if [ "${DRIVER}" != "vfio-pci" ]; then
        echo "ERROR: 0000:${addr} is bound to '${DRIVER}', expected 'vfio-pci'"
        echo "Complete Phase 1 and reboot before running Phase 2."
        exit 1
    fi
    echo "  ✓ 0000:${addr} → vfio-pci"
done
echo ""

# --- Stop VM if running ---
STATUS=$(qm status ${VM_ID} | awk '{print $2}')
if [ "${STATUS}" = "running" ]; then
    echo "Stopping VM ${VM_ID}..."
    qm stop ${VM_ID}
    sleep 5
fi

# --- Set machine type to q35 and OVMF BIOS ---
echo "--- Setting machine type and BIOS ---"
qm set ${VM_ID} --machine q35
qm set ${VM_ID} --bios ovmf
echo "✓ machine=q35, bios=ovmf"

# --- Set CPU to host ---
echo "--- Setting CPU type ---"
qm set ${VM_ID} --cpu host
echo "✓ cpu=host"

# --- Ensure EFI disk exists (required for OVMF) ---
echo "--- Checking EFI disk ---"
if ! qm config ${VM_ID} | grep -q "^efidisk0:"; then
    echo "Adding EFI disk on local-lvm..."
    qm set ${VM_ID} --efidisk0 local-lvm:0,format=raw,efitype=4m,pre-enrolled-keys=0
    echo "✓ efidisk0 added"
else
    echo "  efidisk0 already present"
fi

# --- Set display to none ---
echo "--- Setting display to none ---"
qm set ${VM_ID} --vga none
echo "✓ vga=none"

# --- Add PCIe passthrough for all four GPU functions ---
echo "--- Adding PCIe passthrough ---"
qm set ${VM_ID} --hostpci0 "0000:07:00.0,pcie=1,x-vga=1"
echo "✓ hostpci0: 0000:07:00.0 (GPU)         pcie=1,x-vga=1"
qm set ${VM_ID} --hostpci1 "0000:07:00.1,pcie=1"
echo "✓ hostpci1: 0000:07:00.1 (Audio)       pcie=1"
qm set ${VM_ID} --hostpci2 "0000:07:00.2,pcie=1"
echo "✓ hostpci2: 0000:07:00.2 (USB 3.1)     pcie=1"
qm set ${VM_ID} --hostpci3 "0000:07:00.3,pcie=1"
echo "✓ hostpci3: 0000:07:00.3 (USB-C UCSI)  pcie=1"
echo ""

# --- Final config dump ---
echo "--- Final VM ${VM_ID} config ---"
qm config ${VM_ID}
echo ""

# --- Verification ---
echo "--- Verification ---"
ERRORS=0

for key in "machine: q35" "bios: ovmf" "cpu: host" "vga: none" \
           "hostpci0" "hostpci1" "hostpci2" "hostpci3"; do
    if qm config ${VM_ID} | grep -qi "${key}"; then
        echo "  ✓ ${key}"
    else
        echo "  ✗ MISSING: ${key}"
        ERRORS=$((ERRORS + 1))
    fi
done

# Make sure AMD iGPU is NOT in any hostpci line
if qm config ${VM_ID} | grep -q "0f:00"; then
    echo "  ✗ AMD iGPU (0f:00) found in hostpci — remove it!"
    ERRORS=$((ERRORS + 1))
else
    echo "  ✓ AMD iGPU not passed through (correct)"
fi

echo ""
if [ "${ERRORS}" -eq 0 ]; then
    echo "=== Phase 2 complete — all checks passed ==="
    echo ""
    echo "NEXT STEPS:"
    echo "  1. Start VM: qm start ${VM_ID}"
    echo "  2. Install OS if not already installed (connect via Proxmox console)"
    echo "  3. Install NVIDIA drivers inside the guest"
    echo "  4. Verify with: nvidia-smi (Linux) or Device Manager (Windows)"
else
    echo "=== Phase 2 finished with ${ERRORS} error(s) — review above ==="
    exit 1
fi
