# bulk-backup — hourly versioned copy of /srv/bulk on the USB disk

`/srv/bulk` (photo originals and video previews, Drive blobs, models, Takeout,
the GitHub mirror) lives on one 4 TB SATA disk. This mirrors it, together with
the nightly Postgres dumps in `/srv/backups`, onto a second 4 TB disk on USB
(WD Elements, LUKS2 + btrfs, label `atlas-bulk-backup`, mounted at
`/srv/bulk-backup`) and keeps read-only versions of it.

| Path | What it is |
|---|---|
| `backup.sh` | preflight, `rsync --delete` into `current/`, mass-change brake, read-only btrfs snapshot, retention, status in `/var/lib/atlas-bulk-backup/status.json` |
| `atlas-bulk-backup.service` | oneshot as root (sandboxed: read-only system, no network, minimal capabilities), idle IO, 12 h timeout for the first full copy, `OnFailure=` mail |
| `atlas-bulk-backup.timer` | hourly ± 5 min, `Persistent=true` |
| `atlas-bulk-backup-scrub.{service,timer}` | monthly `btrfs scrub`: reads every block and fails (mail) on a checksum error |
| `install.sh` | crypttab + fstab entries, unlock + mount, source markers, shared lock, script copied root-owned to `/usr/local/sbin/atlas-bulk-backup`, units rendered and the timers enabled |

Failures are mailed to Luka through [`../alerts`](../alerts/README.md), which
also checks hourly that the backup is fresh, not held and the disks are healthy.

## Layout on the disk

```
/srv/bulk-backup/
  current/                 subvolume, latest state
    bulk/                  = /srv/bulk   (without lost+found)
      github/              every GitHub repo, see ../github-sync (runs first, each hour)
    backups/               = /srv/backups
  snapshots/
    2026-10-07T1405Z/      read-only, stamp in UTC
    …
```

btrfs snapshots share every unchanged block with `current/`, so a version costs
only what changed since the one before. A snapshot is only taken after every
rsync succeeded, so an interrupted run never becomes a version. An hour without
changes adds no version; the run after a failed one always takes one, since the
failed run may already have changed `current/`. Stamps are UTC, so the hour the
clock goes back in October gets two distinct names.

## Retention

The newest snapshot of each bucket (local time) is kept:

- hourly: 24 hours
- daily: every day, no limit

So any day can be restored as it was at its last run, as far back as the
backup goes. What a day costs on the disk is only what was deleted or
rewritten that day: new photos are in `current/` anyway, so in practice it is
the nightly Postgres dump (~230 MB) plus whatever was deleted or edited,
roughly 100 GB a year against 3 TB free.

If the disk has less than 10 % free, the oldest snapshots go first, but never
one younger than 30 days, never fewer than 2, at most 8 per run, and it stops
as soon as a drop frees less than 1 % (then `current/` itself is what fills the
disk, and deleting history would not help; it then prunes nothing more for
space until usage is back under the threshold): recent history is not traded for
space, the check mails at 85 % instead. Retention refuses to drop more
than 48 snapshots in one run (a config or clock mistake, not ageing). Weekly
and monthly tiers exist but are redundant while daily has no limit. All of
these are environment variables in `backup.sh` (`KEEP_*`, `MIN_FREE_PCT`,
`MIN_AGE_DAYS`, `KEEP_MIN`, `MAX_PRUNE`).

## Safety checks

The run refuses (unit fails, mail) when

- `/srv/bulk-backup` is not the mounted btrfs with the right label **and** the
  UUID from fstab, is mounted read-only, or btrfs has logged device errors;
- `/srv/bulk` is not mounted, or a source lacks its `.atlas-backup-source`
  marker (`install.sh` creates it) — a freshly formatted or wrong disk is never
  mirrored over the backup;
- github-sync holds `/run/lock/atlas-backup.lock` for over an hour (the two
  share it, so no snapshot catches a half-updated clone; pg-backup's dumps are
  written as `*.part`, which is skipped, and renamed atomically).

A failed run mails Luka. A missing USB disk fails the unit as a dependency,
which `OnFailure=` does not see; the hourly check mails it instead.

**Mass-change brake.** If one run deletes or overwrites more than 1000
existing files (outside `bulk/github/`, whose clones churn by design), it takes
no snapshot and writes `/var/lib/atlas-bulk-backup/hold`. Every later run fails
until someone has looked:

```bash
sudo cat /var/lib/atlas-bulk-backup/hold     # what changed
# broken? restore from the last snapshot (below). intended? release it:
sudo rm /var/lib/atlas-bulk-backup/hold      # the next run snapshots the new state
```

The snapshots from before stay untouched meanwhile, so a wiped or encrypted
photo library cannot push the good versions out. The list of changes is kept
in the state directory until a snapshot is taken, so a run that fails half-way
(after `--delete` already ran) cannot slip its deletions past the brake on the
next run.

`crypttab` and `fstab` use `nofail` with a 10 s device timeout, so atlas boots
normally with the disk unplugged.

## Restore

```bash
ls /srv/bulk-backup/snapshots/                          # pick a version
# one file or folder:
sudo cp -a /srv/bulk-backup/snapshots/2026-10-07T1405Z/bulk/photos/originals/IMG_1234.HEIC /srv/bulk/photos/originals/
# everything (new disk mounted at /srv/bulk):
sudo rsync -aHAX --numeric-ids /srv/bulk-backup/current/bulk/ /srv/bulk/
```

Postgres dumps are under `…/backups/atlas-postgres/`; restore them as in
[`../pg-backup/README.md`](../pg-backup/README.md).

On another machine the disk needs the key: `/etc/atlas/credentials/bulk-backup.key`
on atlas, with a copy in 1Password (`atlas-bulk-backup-luks-key`, a document).

## Install

One-time, for a new disk (erases it):

```bash
lsblk -o NAME,SIZE,MODEL,TRAN,LABEL              # find the USB disk, e.g. sdb1
K=/etc/atlas/credentials/bulk-backup.key
sudo install -d -m 0700 /etc/atlas/credentials
sudo sh -c "umask 077; head -c 64 /dev/urandom > $K"   # and store a copy in 1Password
sudo cryptsetup luksFormat -q --type luks2 --label atlas-bulk-backup-luks --key-file $K /dev/sdX1
sudo cryptsetup open --key-file $K /dev/sdX1 atlas-bulk-backup
sudo mkfs.btrfs -f -L atlas-bulk-backup /dev/mapper/atlas-bulk-backup
```

Then, and after every change to `backup.sh` (the unit runs the copy in
`/usr/local/sbin`, not the checkout):

```bash
../alerts/install.sh       # first, once
./install.sh
sudo systemctl start --no-block atlas-bulk-backup.service   # first full copy now
journalctl -fu atlas-bulk-backup.service
```

## Limits

Both disks sit in the same box: this covers a dead bulk disk, deleted files,
mass deletion and bit rot, not fire, theft of the whole box or a power surge.
Root on atlas can still delete snapshots; there is deliberately no off-site
copy.
