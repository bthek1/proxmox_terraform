#!/bin/bash
set -e

echo "=== Current kernel ==="
uname -r

echo "=== Checking for kernel headers ==="
KERNEL=$(uname -r)
if dpkg -s "linux-headers-${KERNEL}" > /dev/null 2>&1; then
  echo "Headers already installed"
else
  echo "Installing kernel headers..."
  apt-get install -y "linux-headers-${KERNEL}"
fi

echo "=== Running DKMS build ==="
# Get the currently registered nvidia version from DKMS
NVIDIA_VER=$(dkms status | awk -F'[,/]' '/^nvidia/{print $2}' | tr -d ' ' | head -1)
if [ -z "${NVIDIA_VER}" ]; then
  echo "ERROR: No nvidia driver found in DKMS. Run nvidia_upgrade.sh first."
  exit 1
fi
echo "Found DKMS nvidia version: ${NVIDIA_VER}"
dkms install "nvidia/${NVIDIA_VER}" -k "${KERNEL}"

echo "=== Loading modules ==="
modprobe nvidia
modprobe nvidia_uvm
modprobe nvidia_modeset

echo "=== Starting nvidia-devices service ==="
systemctl start nvidia-devices.service
systemctl status nvidia-devices.service --no-pager

echo "=== Device nodes ==="
ls -la /dev/nvidia*

echo "=== Starting LXC 107 ==="
pct start 107

echo "=== Done ==="
