#!/usr/bin/env bash
# Install/refresh the hourly GitHub mirror.
#
# Expects the GitHub App key in /etc/atlas/credentials/github-sync-app.pem and
# the app id plus the allowed accounts in /etc/atlas/github-sync.env (README).
# Creates the atlas-github system user and /srv/bulk/github, installs the
# script to /usr/local/bin, renders the unit and hooks it into
# atlas-bulk-backup.service. Safe to re-run.
set -euo pipefail
cd "$(dirname "$0")"

DEST=/srv/bulk/github
USR=atlas-github

sudo test -s /etc/atlas/credentials/github-sync-app.pem \
  || { echo "/etc/atlas/credentials/github-sync-app.pem is missing — create the GitHub App first (README)" >&2; exit 1; }
sudo grep -q '^GITHUB_APP_ID=' /etc/atlas/github-sync.env 2>/dev/null \
  || { echo "/etc/atlas/github-sync.env lacks GITHUB_APP_ID (README)" >&2; exit 1; }
mountpoint -q /srv/bulk || { echo "/srv/bulk is not mounted" >&2; exit 1; }
systemctl cat atlas-bulk-backup.service >/dev/null 2>&1 \
  || { echo "install ../bulk-backup first: it runs the sync and provides the shared lock" >&2; exit 1; }

id "$USR" >/dev/null 2>&1 || sudo useradd --system --no-create-home --home-dir /var/lib/atlas-github-sync --shell /usr/sbin/nologin "$USR"
sudo install -d -o "$USR" -g "$USR" -m 0750 "$DEST"
# Clones made by an earlier install that ran as luka.
[ "$(sudo find "$DEST" ! -user "$USR" -print -quit)" = "" ] || sudo chown -R "$USR:$USR" "$DEST"

sudo install -o root -g root -m 0755 sync.sh /usr/local/bin/atlas-github-sync
sudo install -m 0644 atlas-github-sync.service /etc/systemd/system/atlas-github-sync.service
sudo systemctl daemon-reload
sudo systemctl enable atlas-github-sync.service
echo "Installed. Runs with every atlas-bulk-backup run (hourly)."
echo "  run now:    sudo systemctl start --no-block atlas-github-sync.service"
echo "  history:    journalctl -u atlas-github-sync.service -n 50"
echo "  status:     sudo cat /var/lib/atlas-github-sync/status.json"
