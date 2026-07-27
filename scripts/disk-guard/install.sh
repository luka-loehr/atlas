#!/usr/bin/env bash
# Install/refresh the disk-guard timer and the pre-build gate.
set -euo pipefail
cd "$(dirname "$0")"
sudo cp atlas-disk-guard.service atlas-disk-guard.timer /etc/systemd/system/
sudo ln -sfn "$PWD/disk-guard.sh" /usr/local/bin/atlas-disk-guard
sudo systemctl daemon-reload
sudo systemctl enable --now atlas-disk-guard.timer
echo "Installed."
echo "  now:        atlas-disk-guard --status"
echo "  before a build: atlas-disk-guard --require-free || exit 1"
echo "  next run:   systemctl list-timers atlas-disk-guard.timer"
echo "  history:    journalctl -u atlas-disk-guard.service -n 50"
