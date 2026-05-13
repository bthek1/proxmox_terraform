#!/bin/bash
set -e

DRIVER_VER="595.71.05"
DRIVER_FILE="NVIDIA-Linux-x86_64-${DRIVER_VER}.run"
DRIVER_URL="https://download.nvidia.com/XFree86/Linux-x86_64/${DRIVER_VER}/${DRIVER_FILE}"
DRIVER_PATH="/tmp/${DRIVER_FILE}"

echo "=== Kernel: $(uname -r) ==="

echo "=== Removing old DKMS entry for 580.105.08 ==="
dkms remove nvidia/580.105.08 --all 2>/dev/null || true

echo "=== Downloading NVIDIA ${DRIVER_VER} ==="
if [ ! -f "${DRIVER_PATH}" ]; then
    wget -q --show-progress -O "${DRIVER_PATH}" "${DRIVER_URL}"
fi
chmod +x "${DRIVER_PATH}"

echo "=== Installing NVIDIA ${DRIVER_VER} with DKMS ==="
bash "${DRIVER_PATH}" \
    --silent \
    --dkms \
    --no-drm \
    --no-backup \
    --no-x-check \
    --no-nouveau-check

echo "=== Loading modules ==="
modprobe nvidia
modprobe nvidia_uvm
modprobe nvidia_modeset

echo "=== nvidia-smi ==="
nvidia-smi

echo "=== Starting nvidia-devices service ==="
systemctl start nvidia-devices.service
systemctl status nvidia-devices.service --no-pager

echo "=== Device nodes ==="
ls -la /dev/nvidia*

echo "=== Starting LXC 107 ==="
pct start 107

echo "=== Done ==="
