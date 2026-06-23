#!/bin/sh
# apply-boot-state.sh — run by openrgb.service as ExecStartPost.
# The ASUS Aura addressable headers (device 2, zones 1-3) detect as 0 LEDs at
# startup, so OpenRGB never drives them and the strips fall back to their
# hardware-default rainbow. This sizes them so a client (Home Assistant) can
# control them, then sets a neutral OFF state (HA sets the real colors later).
R=/opt/openrgb/squashfs-root/AppRun

# Wait for the server to bind :6742 (max ~15s) before sending it commands.
i=0
while [ $i -lt 30 ]; do
  ss -ltn 2>/dev/null | grep -q ':6742 ' && break
  i=$((i+1)); sleep 0.5
done
sleep 1   # let device init settle after the socket opens

# Size the three Aura addressable headers (resize-only calls, no color = no segfault).
"$R" -d 2 -z 1 -s 100 >/dev/null 2>&1
"$R" -d 2 -z 2 -s 100 >/dev/null 2>&1
"$R" -d 2 -z 3 -s 100 >/dev/null 2>&1

# Neutral OFF until Home Assistant connects and sets colors.
"$R" -d 2 --mode direct --color 000000 >/dev/null 2>&1
exit 0
