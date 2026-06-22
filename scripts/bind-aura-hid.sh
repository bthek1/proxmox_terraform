#!/bin/sh
# Ensure the ASUS Aura USB controller's HID interface is bound to usbhid so a
# /dev/hidraw node exists for OpenRGB. Idempotent; safe to run repeatedly.
# (Needed because nothing auto-rebinds the interface if it was ever detached,
#  e.g. after a VM USB-passthrough released it.)
for dev in /sys/bus/usb/devices/*; do
  [ -f "$dev/idVendor" ] || continue
  [ "$(cat "$dev/idVendor")" = "0b05" ] && [ "$(cat "$dev/idProduct")" = "19af" ] || continue
  for iface in "$dev"/*:*; do
    [ -f "$iface/bInterfaceClass" ] || continue
    [ "$(cat "$iface/bInterfaceClass")" = "03" ] || continue
    name=$(basename "$iface")
    cur=$(basename "$(readlink "$iface/driver" 2>/dev/null)" 2>/dev/null)
    [ "$cur" = "usbhid" ] && continue
    [ -n "$cur" ] && echo -n "$name" > "/sys/bus/usb/drivers/$cur/unbind" 2>/dev/null
    echo -n "$name" > /sys/bus/usb/drivers/usbhid/bind 2>/dev/null
  done
done
exit 0
