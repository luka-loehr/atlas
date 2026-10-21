#!/usr/bin/env bash
# Install/refresh the host power units: Wake-on-LAN, readable RAPL, and the
# daily schedule (RTC wake at 10:00, power-off at 22:00).
#
# Both predate the atlas- unit naming and were installed by hand as
# wol.service / rapl-readable.service. Those are disabled and removed here —
# leaving them enabled would run the same ExecStart twice under two names.
set -euo pipefail
cd "$(dirname "$0")"

NIC=${ATLAS_WOL_NIC:-enp4s0}
if ! ip link show "$NIC" >/dev/null 2>&1; then
  echo "no such interface: $NIC — edit atlas-wol.service (ip -br link)" >&2
  exit 1
fi

for old in wol.service rapl-readable.service; do
  if [ -f "/etc/systemd/system/$old" ]; then
    sudo systemctl disable --now "$old" >/dev/null 2>&1 || true
    sudo rm -f "/etc/systemd/system/$old"
  fi
done

# The 2026-08 rtcwake units (slots 11:00/15:00/20:00) were parked by hand as
# *.disabled-by-owner. The daily schedule below replaces them.
sudo rm -f /etc/systemd/system/atlas-rtcwake*.disabled-by-owner /usr/local/sbin/atlas-rtcwake.bak-*

# A root-owned copy, not the checkout: a root unit must not run a file that
# luka, or anything running as luka, can rewrite.
sudo install -o root -g root -m 0755 atlas-rtcwake /usr/local/sbin/atlas-rtcwake

sudo cp atlas-wol.service atlas-rapl-readable.service atlas-rtcwake.service \
  atlas-poweroff.service atlas-poweroff.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now atlas-wol.service atlas-rapl-readable.service atlas-poweroff.timer
# enable + restart, not --now: on a re-run the unit is already active and
# --now would not re-arm.
sudo systemctl enable atlas-rtcwake.service
sudo systemctl restart atlas-rtcwake.service
echo "Installed."
echo "  wake mode:  sudo ethtool $NIC | grep Wake-on        # expect 'g'"
echo "  rapl:       head -c 40 /sys/class/powercap/intel-rapl:0/energy_uj"
echo "  wake:       journalctl -t atlas-rtcwake -n 1              # expect 'armed for <next 10:00>'"
echo "  power-off:  systemctl list-timers atlas-poweroff.timer"
