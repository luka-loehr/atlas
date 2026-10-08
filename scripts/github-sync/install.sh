#!/usr/bin/env bash
# Install/refresh the hourly GitHub mirror. Run as the user gh is logged in as.
#
# Creates /srv/bulk/github, installs the script to /usr/local/bin (the unit
# does not depend on which branch the checkout is on), renders the unit and
# hooks it into atlas-bulk-backup.service. Safe to re-run.
set -euo pipefail
cd "$(dirname "$0")"

DEST=/srv/bulk/github

gh auth status >/dev/null 2>&1 || { echo "gh is not logged in for $(id -un) — run gh auth login first" >&2; exit 1; }
mountpoint -q /srv/bulk || { echo "/srv/bulk is not mounted" >&2; exit 1; }
systemctl cat atlas-bulk-backup.service >/dev/null 2>&1 \
  || echo "warning: atlas-bulk-backup.service is not installed; nothing will trigger the sync (scripts/bulk-backup)" >&2

sudo install -d -o "$(id -un)" -g "$(id -gn)" -m 0750 "$DEST"
sudo install -o root -g root -m 0755 sync.sh /usr/local/bin/atlas-github-sync

. ../lib/install-unit.sh
install_unit atlas-github-sync.service
sudo systemctl daemon-reload
sudo systemctl enable atlas-github-sync.service
echo "Installed. Runs with every atlas-bulk-backup run (hourly)."
echo "  run now:    sudo systemctl start --no-block atlas-github-sync.service"
echo "  history:    journalctl -u atlas-github-sync.service -n 50"
echo "  status:     cat /var/lib/atlas-github-sync/status.json"
