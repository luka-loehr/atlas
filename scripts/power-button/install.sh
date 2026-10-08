#!/usr/bin/env bash
# Install/refresh the power-button daemon: the script goes root-owned to
# /usr/local/sbin (the unit runs as root and must not run a file in the
# checkout), the unit is rendered and enabled. Safe to re-run.
set -euo pipefail
cd "$(dirname "$0")"

# logind must ignore the key, or a single press still powers off (README).
CONF=/etc/systemd/logind.conf.d/10-power-button.conf
if [ ! -e "$CONF" ]; then
  sudo mkdir -p "$(dirname "$CONF")"
  printf '[Login]\nHandlePowerKey=ignore\nHandlePowerKeyLongPress=ignore\n' | sudo tee "$CONF" >/dev/null
  echo "wrote $CONF; it applies after: sudo systemctl restart systemd-logind (or a reboot)"
fi

sudo install -o root -g root -m 0755 power-button.py /usr/local/sbin/atlas-power-button
. ../lib/install-unit.sh
install_unit atlas-power-button.service
sudo systemctl daemon-reload
sudo systemctl enable atlas-power-button.service
sudo systemctl restart atlas-power-button.service
echo "Installed. Status: systemctl status atlas-power-button"
