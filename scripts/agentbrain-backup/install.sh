#!/usr/bin/env bash
# Install/refresh the hourly agentbrain sync. Safe to re-run.
#
# Expects the backup key in /etc/atlas/credentials/agentbrain-backup.key and
# the settings in /etc/atlas/agentbrain-backup.env (README):
#   AGENTBRAIN_URL=https://…              your agentbrain server
#   AGENTBRAIN_BACKUP_DEST=/srv/bulk/…    optional, where the archives go
# Creates the atlas-agentbrain system user and the destination, installs the
# script to /usr/local/bin and the unit. With scripts/bulk-backup installed it
# runs before every bulk backup (and so lands in its snapshots); without, on
# its own hourly timer.
set -euo pipefail
cd "$(dirname "$0")"

ENV=/etc/atlas/agentbrain-backup.env
KEY=/etc/atlas/credentials/agentbrain-backup.key
USR=atlas-agentbrain
LOCK=/run/lock/atlas-backup.lock

sudo test -s "$KEY" \
  || { echo "$KEY is missing — create a backup key in agentbrain (Settings → Backups) and save it there (README)" >&2; exit 1; }
sudo grep -q '^AGENTBRAIN_URL=https://' "$ENV" 2>/dev/null \
  || { echo "$ENV lacks AGENTBRAIN_URL=https://… (README)" >&2; exit 1; }
DEST=$(sudo sed -n 's/^AGENTBRAIN_BACKUP_DEST=//p' "$ENV" | tail -n1)
DEST=${DEST:-/srv/bulk/agentbrain}
case $DEST in /*) ;; *) echo "AGENTBRAIN_BACKUP_DEST must be an absolute path" >&2; exit 1 ;; esac
[ "$DEST" != /srv/bulk/agentbrain ] || mountpoint -q /srv/bulk \
  || { echo "/srv/bulk is not mounted; mount it or set AGENTBRAIN_BACKUP_DEST" >&2; exit 1; }

id "$USR" >/dev/null 2>&1 || sudo useradd --system --no-create-home --home-dir /var/lib/atlas-agentbrain-backup --shell /usr/sbin/nologin "$USR"
sudo install -d -o "$USR" -g "$USR" -m 0750 "$DEST" "$DEST/daily"
sudo chown root:root "$KEY" "$ENV"
sudo chmod 0600 "$KEY"
sudo chmod 0644 "$ENV"

sudo install -o root -g root -m 0755 pull.sh /usr/local/bin/atlas-agentbrain-backup
sed -e "s|^RequiresMountsFor=SET-BY-INSTALLER$|RequiresMountsFor=$DEST|" \
    -e "s|^ReadWritePaths=SET-BY-INSTALLER$|ReadWritePaths=$DEST|" \
    atlas-agentbrain-backup.service | sudo tee /etc/systemd/system/atlas-agentbrain-backup.service >/dev/null
# Mail on failure, where scripts/alerts is installed.
if systemctl cat atlas-alert@.service >/dev/null 2>&1; then
  sudo install -d /etc/systemd/system/atlas-agentbrain-backup.service.d
  printf '[Unit]\nOnFailure=atlas-alert@%%n.service\n' | sudo tee /etc/systemd/system/atlas-agentbrain-backup.service.d/alert.conf >/dev/null
fi

if systemctl cat atlas-bulk-backup.service >/dev/null 2>&1; then
  sudo systemctl daemon-reload
  sudo systemctl disable --now atlas-agentbrain-backup.timer 2>/dev/null || true
  sudo rm -f /etc/systemd/system/atlas-agentbrain-backup.timer
  sudo systemctl daemon-reload
  sudo systemctl enable atlas-agentbrain-backup.service
  echo "Installed. Runs before every atlas-bulk-backup run (hourly), so its snapshots version the archives."
else
  # The lock the bulk backup would provide.
  [ -e "$LOCK" ] || { echo "f $LOCK 0644 root root -" | sudo tee /etc/tmpfiles.d/atlas-agentbrain-backup.conf >/dev/null; sudo systemd-tmpfiles --create /etc/tmpfiles.d/atlas-agentbrain-backup.conf; }
  sudo install -m 0644 atlas-agentbrain-backup.timer /etc/systemd/system/atlas-agentbrain-backup.timer
  sudo systemctl daemon-reload
  sudo systemctl enable --now atlas-agentbrain-backup.timer
  echo "Installed. Runs hourly on atlas-agentbrain-backup.timer."
fi
echo "  run now:    sudo systemctl start atlas-agentbrain-backup.service"
echo "  history:    journalctl -u atlas-agentbrain-backup.service -n 50"
echo "  status:     sudo cat /var/lib/atlas-agentbrain-backup/status.json"
