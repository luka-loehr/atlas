#!/usr/bin/env bash
# Install/refresh the nightly Postgres backup timer.
#
# Also removes the older systemd *user* copy of the same pair. Both existed for
# a while, so the dump ran twice a night against the same directory; the system
# units are the ones this repo ships.
set -euo pipefail
cd "$(dirname "$0")"

if systemctl --user list-unit-files atlas-pg-backup.timer >/dev/null 2>&1; then
  systemctl --user disable --now atlas-pg-backup.timer 2>/dev/null || true
  rm -f "$HOME/.config/systemd/user/atlas-pg-backup.service" \
        "$HOME/.config/systemd/user/atlas-pg-backup.timer"
  systemctl --user daemon-reload 2>/dev/null || true
fi

sudo cp atlas-pg-backup.service atlas-pg-backup.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now atlas-pg-backup.timer
echo "Installed."
echo "  next run:   systemctl list-timers atlas-pg-backup.timer"
echo "  run now:    sudo systemctl start atlas-pg-backup.service"
echo "  history:    journalctl -u atlas-pg-backup.service -n 50"
