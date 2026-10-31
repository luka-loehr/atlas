#!/usr/bin/env bash
# Install/refresh the hourly agentbrain archive pull.
#
# Expects the backup key in /etc/atlas/credentials/agentbrain-backup.key and
# the server address in /etc/atlas/agentbrain-backup.env (README). Creates the
# atlas-agentbrain system user and /srv/bulk/agentbrain, installs the script to
# /usr/local/bin, installs the unit and hooks it into atlas-bulk-backup.service.
# Safe to re-run.
set -euo pipefail
cd "$(dirname "$0")"

DEST=/srv/bulk/agentbrain
USR=atlas-agentbrain

sudo test -s /etc/atlas/credentials/agentbrain-backup.key \
  || { echo "/etc/atlas/credentials/agentbrain-backup.key is missing — create a backup key first (README)" >&2; exit 1; }
sudo grep -q '^AGENTBRAIN_URL=https://' /etc/atlas/agentbrain-backup.env 2>/dev/null \
  || { echo "/etc/atlas/agentbrain-backup.env lacks AGENTBRAIN_URL=https://… (README)" >&2; exit 1; }
mountpoint -q /srv/bulk || { echo "/srv/bulk is not mounted" >&2; exit 1; }
systemctl cat atlas-bulk-backup.service >/dev/null 2>&1 \
  || { echo "install ../bulk-backup first: it runs the pull and provides the shared lock" >&2; exit 1; }

id "$USR" >/dev/null 2>&1 || sudo useradd --system --no-create-home --home-dir /var/lib/atlas-agentbrain-backup --shell /usr/sbin/nologin "$USR"
sudo install -d -o "$USR" -g "$USR" -m 0750 "$DEST" "$DEST/daily"
sudo chmod 0600 /etc/atlas/credentials/agentbrain-backup.key
sudo chown root:root /etc/atlas/credentials/agentbrain-backup.key /etc/atlas/agentbrain-backup.env
sudo chmod 0644 /etc/atlas/agentbrain-backup.env

sudo install -o root -g root -m 0755 pull.sh /usr/local/bin/atlas-agentbrain-backup
sudo install -m 0644 atlas-agentbrain-backup.service /etc/systemd/system/atlas-agentbrain-backup.service
sudo systemctl daemon-reload
sudo systemctl enable atlas-agentbrain-backup.service
echo "Installed. Runs with every atlas-bulk-backup run (hourly)."
echo "  run now:    sudo systemctl start atlas-agentbrain-backup.service"
echo "  history:    journalctl -u atlas-agentbrain-backup.service -n 50"
echo "  status:     sudo cat /var/lib/atlas-agentbrain-backup/status.json"
