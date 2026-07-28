#!/usr/bin/env bash
# Install/refresh the two host power units (Wake-on-LAN, readable RAPL).
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

sudo cp atlas-wol.service atlas-rapl-readable.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now atlas-wol.service atlas-rapl-readable.service
echo "Installed."
echo "  wake mode:  sudo ethtool $NIC | grep Wake-on        # expect 'g'"
echo "  rapl:       head -c 40 /sys/class/powercap/intel-rapl:0/energy_uj"
