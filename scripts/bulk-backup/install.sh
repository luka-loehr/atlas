#!/usr/bin/env bash
# Install/refresh the hourly /srv/bulk backup onto the USB disk.
#
# Expects the disk already formatted (see README, one-time step): btrfs with
# label atlas-bulk-backup. Adds the fstab entry if missing, mounts it, installs
# the script root-owned to /usr/local/sbin, renders the units, enables the
# timer. Safe to re-run.
set -euo pipefail
cd "$(dirname "$0")"

LABEL=atlas-bulk-backup
MNT=/srv/bulk-backup

uuid=$(sudo blkid -L "$LABEL" >/dev/null && sudo blkid -s UUID -o value "$(sudo blkid -L "$LABEL")") \
  || { echo "no filesystem labelled $LABEL — format the disk first (README)" >&2; exit 1; }

sudo mkdir -p "$MNT"
if ! grep -q "[[:space:]]${MNT}[[:space:]]" /etc/fstab; then
  # nofail + short device timeout: atlas must still boot with the disk unplugged.
  echo "UUID=$uuid  $MNT  btrfs  noatime,compress=zstd:1,nofail,x-systemd.device-timeout=10  0 0" \
    | sudo tee -a /etc/fstab >/dev/null
  sudo systemctl daemon-reload
fi
mountpoint -q "$MNT" || sudo mount "$MNT"

sudo install -o root -g root -m 0755 backup.sh /usr/local/sbin/atlas-bulk-backup

. ../lib/install-unit.sh
install_unit atlas-bulk-backup.service atlas-bulk-backup.timer
sudo systemctl daemon-reload
sudo systemctl enable --now atlas-bulk-backup.timer
echo "Installed."
echo "  next run:   systemctl list-timers atlas-bulk-backup.timer"
echo "  run now:    sudo systemctl start --no-block atlas-bulk-backup.service"
echo "  history:    journalctl -u atlas-bulk-backup.service -n 50"
echo "  versions:   ls $MNT/snapshots"
