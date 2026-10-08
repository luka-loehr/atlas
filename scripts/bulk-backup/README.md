# bulk-backup — hourly versioned copy of /srv/bulk on the USB disk

`/srv/bulk` (photo originals and previews, Drive blobs, models, Takeout) lives
on one 4 TB SATA disk. This mirrors it, together with the nightly Postgres
dumps in `/srv/backups`, onto a second 4 TB disk on USB (WD Elements, btrfs,
label `atlas-bulk-backup`, mounted at `/srv/bulk-backup`) and keeps read-only
versions of it.

| Path | What it is |
|---|---|
| `backup.sh` | preflight, `rsync --delete` into `current/`, read-only btrfs snapshot, retention, status in `/var/lib/atlas-bulk-backup/status.json` |
| `atlas-bulk-backup.service` | oneshot as root (sandboxed: read-only system, no network), idle IO, 12 h timeout for the first full copy |
| `atlas-bulk-backup.timer` | hourly ± 5 min, `Persistent=true` |
| `install.sh` | fstab entry + mount, script copied root-owned to `/usr/local/sbin/atlas-bulk-backup`, units rendered and the timer enabled |

## Layout on the disk

```
/srv/bulk-backup/
  current/                 subvolume, latest state
    bulk/                  = /srv/bulk   (without lost+found)
    backups/               = /srv/backups
  snapshots/
    2026-10-07T1405/       read-only, one per run that changed something
    …
```

btrfs snapshots share every unchanged block with `current/`, so a version costs
only what changed since the one before. A snapshot is only taken after every
rsync succeeded, so an interrupted run never becomes a version, and only when
rsync created, changed or deleted something — an hour without changes adds no
version. btrfs also checksums every block, so a rotting backup disk shows up
as read errors instead of silently wrong photos.

## Retention

The newest snapshot of each bucket is kept:

- hourly: 24 hours
- daily: every day, no limit

So any day can be restored as it was at its last run, as far back as the
backup goes. What a day costs on the disk is only what was deleted or
rewritten that day: new photos are in `current/` anyway, so in practice it is
the nightly Postgres dump (~230 MB) plus whatever was deleted or edited,
roughly 100 GB a year against 3 TB free. If the disk ever has less than 10 %
free, the oldest snapshots are removed first, never fewer than 2. Weekly and
monthly tiers exist (`KEEP_WEEKLY`, `KEEP_MONTHLY`) but are redundant while
daily has no limit. All of these are environment variables in
`backup.sh` (`KEEP_*`, `MIN_FREE_PCT`, `KEEP_MIN`).

## Safety checks

The run refuses (unit fails, error in the journal) when

- `/srv/bulk-backup` is not the mounted btrfs disk with the right label — the
  USB disk is unplugged or another disk took its place;
- `/srv/bulk` is not mounted, or a source directory is empty — otherwise
  `rsync --delete` would mirror an empty directory over the backup.

`fstab` uses `nofail` with a 10 s device timeout, so atlas boots normally with
the disk unplugged.

## Restore

```bash
ls /srv/bulk-backup/snapshots/                          # pick a version
# one file or folder:
sudo cp -a /srv/bulk-backup/snapshots/2026-10-07T1405/bulk/photos/originals/IMG_1234.HEIC /srv/bulk/photos/originals/
# everything (new disk mounted at /srv/bulk):
sudo rsync -aHAX --numeric-ids /srv/bulk-backup/current/bulk/ /srv/bulk/
```

Postgres dumps are under `…/backups/atlas-postgres/`; restore them as in
[`../pg-backup/README.md`](../pg-backup/README.md).

## Install

One-time, for a new disk (erases it):

```bash
lsblk -o NAME,SIZE,MODEL,TRAN,LABEL              # find the USB disk, e.g. sdb1
sudo mkfs.btrfs -f -L atlas-bulk-backup /dev/sdX1
```

Then, and after every change to `backup.sh` (the unit runs the copy in
`/usr/local/sbin`, not the checkout):

```bash
./install.sh
sudo systemctl start --no-block atlas-bulk-backup.service   # first full copy now
journalctl -fu atlas-bulk-backup.service
```

## Limits

Both disks sit in the same box: this covers a dead bulk disk, deleted files
and bit rot, not fire, theft or a power surge. Off-site copies are a separate
step.
