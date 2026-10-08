#!/usr/bin/env bash
# Install/refresh the hourly /srv/bulk backup onto the USB disk.
#
# Expects the disk already prepared (see README, one-time step): LUKS2 with
# label atlas-bulk-backup-luks and the key in /etc/atlas/credentials, btrfs
# labelled atlas-bulk-backup inside. Adds the crypttab and fstab entries if
# missing, unlocks and mounts the disk, marks the sources, installs the script
# root-owned to /usr/local/sbin, renders the units, enables the timer and the
# monthly scrub. Safe to re-run.
set -euo pipefail
cd "$(dirname "$0")"

LABEL=atlas-bulk-backup
MNT=/srv/bulk-backup
MAPPER=atlas-bulk-backup
KEY=/etc/atlas/credentials/bulk-backup.key
SOURCES=(/srv/bulk /srv/backups)

systemctl cat atlas-alert@.service >/dev/null 2>&1 \
  || { echo "install ../alerts first: failures of this job are mailed through it" >&2; exit 1; }

# One disk only: two filesystems with the same label would make it a guess.
luks=$(sudo blkid -t LABEL="$LABEL-luks" -o device || true)
[ "$(printf '%s' "$luks" | grep -c .)" -le 1 ] || { echo "more than one disk labelled $LABEL-luks: $luks" >&2; exit 1; }
if [ -n "$luks" ]; then
  sudo test -s "$KEY" || { echo "$luks is encrypted but $KEY is missing" >&2; exit 1; }
  luks_uuid=$(sudo blkid -s UUID -o value "$luks")
  if ! sudo grep -q "^$MAPPER[[:space:]]" /etc/crypttab 2>/dev/null; then
    # nofail + short device timeout: atlas must still boot with the disk unplugged.
    echo "$MAPPER  UUID=$luks_uuid  $KEY  luks,nofail,x-systemd.device-timeout=10" | sudo tee -a /etc/crypttab >/dev/null
    sudo systemctl daemon-reload
  fi
  [ -e "/dev/mapper/$MAPPER" ] || sudo systemctl start "systemd-cryptsetup@$(systemd-escape "$MAPPER").service"
fi

devs=$(for d in $(sudo blkid -t LABEL="$LABEL" -o device || true); do
         [ "$(sudo blkid -s TYPE -o value "$d")" = btrfs ] && echo "$d"; done)
[ "$(printf '%s' "$devs" | grep -c .)" = 1 ] \
  || { echo "need exactly one btrfs labelled $LABEL, found: ${devs:-none} — prepare the disk first (README)" >&2; exit 1; }
uuid=$(sudo blkid -s UUID -o value "$devs")

sudo mkdir -p "$MNT"
if ! grep -q "[[:space:]]${MNT}[[:space:]]" /etc/fstab; then
  echo "UUID=$uuid  $MNT  btrfs  noatime,compress=zstd:1,nofail,x-systemd.device-timeout=10  0 0" \
    | sudo tee -a /etc/fstab >/dev/null
  sudo systemctl daemon-reload
fi
grep -q "^UUID=$uuid[[:space:]]" /etc/fstab \
  || { echo "/etc/fstab mounts something else on $MNT; fix it to UUID=$uuid" >&2; exit 1; }
mountpoint -q "$MNT" || sudo mount "$MNT"

# backup.sh refuses a source without this file (an empty or foreign disk).
for s in "${SOURCES[@]}"; do
  sudo test -f "$s/.atlas-backup-source" || echo "mirrored hourly to $MNT by scripts/bulk-backup; do not delete" | sudo tee "$s/.atlas-backup-source" >/dev/null
done

# Shared lock of the backup jobs (bulk-backup, github-sync, pg-backup).
echo 'f /run/lock/atlas-backup.lock 0644 root root -' | sudo tee /etc/tmpfiles.d/atlas-backup.conf >/dev/null
sudo systemd-tmpfiles --create /etc/tmpfiles.d/atlas-backup.conf

sudo install -o root -g root -m 0755 backup.sh /usr/local/sbin/atlas-bulk-backup

. ../lib/install-unit.sh
install_unit atlas-bulk-backup.service atlas-bulk-backup.timer \
             atlas-bulk-backup-scrub.service atlas-bulk-backup-scrub.timer
sudo systemctl daemon-reload
sudo systemctl enable --now atlas-bulk-backup.timer atlas-bulk-backup-scrub.timer
echo "Installed."
echo "  next run:   systemctl list-timers 'atlas-bulk-backup*'"
echo "  run now:    sudo systemctl start --no-block atlas-bulk-backup.service"
echo "  history:    journalctl -u atlas-bulk-backup.service -n 50"
echo "  versions:   ls $MNT/snapshots"
