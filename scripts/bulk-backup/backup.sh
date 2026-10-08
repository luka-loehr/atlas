#!/usr/bin/env bash
# bulk-backup — mirror /srv/bulk (and the Postgres dumps) onto the USB backup
# disk, then take a read-only btrfs snapshot of the mirror.
#
# The backup disk is btrfs (label atlas-bulk-backup, mounted at
# /srv/bulk-backup):
#
#   current/            subvolume, rsync target, always the latest state
#     bulk/             = /srv/bulk
#     backups/          = /srv/backups (nightly pg_dump output)
#   snapshots/<stamp>/  read-only snapshots of current/, one per good run
#
# Snapshots share every unchanged extent with current/, so a version costs only
# what changed since the previous one. A snapshot is taken only after every
# rsync succeeded, so a half-finished run never becomes a version, and only if
# rsync changed something, so an idle hour adds no version.
#
# Retention keeps the newest snapshot per bucket: KEEP_HOURLY hours,
# KEEP_DAILY days, KEEP_WEEKLY ISO weeks, KEEP_MONTHLY months; 0 means no
# limit (the default for days: one version of every day, forever). If the disk
# still has less than MIN_FREE_PCT free, the oldest snapshots go next, but
# never below KEEP_MIN.
#
# Runs as root (ownership, ACLs, btrfs ioctls). Failures go to the journal at
# err priority.
set -euo pipefail

DEST=${BULK_BACKUP_DEST:-/srv/bulk-backup}
DEST_LABEL=${BULK_BACKUP_LABEL:-atlas-bulk-backup}
# Each source is mirrored to current/<basename>.
read -r -a SOURCES <<< "${BULK_BACKUP_SOURCES:-/srv/bulk /srv/backups}"
# Sources that are their own filesystem. If one is not mounted, the directory
# underneath is empty and rsync --delete would wipe its mirror.
read -r -a MUST_BE_MOUNTED <<< "${BULK_BACKUP_MUST_BE_MOUNTED:-/srv/bulk}"
STATE_DIR=${STATE_DIRECTORY:-/var/lib/atlas-bulk-backup}

KEEP_HOURLY=${KEEP_HOURLY:-24}
KEEP_DAILY=${KEEP_DAILY:-0}
KEEP_WEEKLY=${KEEP_WEEKLY:-8}
KEEP_MONTHLY=${KEEP_MONTHLY:-12}
KEEP_MIN=${KEEP_MIN:-2}
MIN_FREE_PCT=${MIN_FREE_PCT:-10}

die() { echo "<3>bulk-backup: $*" >&2; exit 1; }

# --- preflight -------------------------------------------------------------

read -r fstype label < <(findmnt -n -o FSTYPE,LABEL --mountpoint "$DEST" || true)
[ "${fstype:-}" = btrfs ] && [ "${label:-}" = "$DEST_LABEL" ] \
  || die "$DEST is not the mounted btrfs disk $DEST_LABEL (got '${fstype:-nothing}' '${label:-}') — is the USB disk plugged in?"

for m in "${MUST_BE_MOUNTED[@]}"; do
  mountpoint -q "$m" || die "$m is not mounted; refusing to mirror an empty directory over the backup"
done
for s in "${SOURCES[@]}"; do
  [ -d "$s" ] || die "source $s does not exist"
  [ -n "$(ls -A "$s")" ] || die "source $s is empty; refusing to mirror it"
done

mkdir -p "$DEST/snapshots" "$STATE_DIR"
[ -d "$DEST/current" ] || btrfs -q subvolume create "$DEST/current"

# --- space -----------------------------------------------------------------

snapshots() {
  find "$DEST/snapshots" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' \
    | { grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{4}$' || true; } | sort
}

used_pct() { df --output=pcent "$DEST" | tail -n1 | tr -dc '0-9'; }

drop() {
  btrfs -q subvolume delete --commit-after "$DEST/snapshots/$1" >/dev/null
  echo "pruned snapshot $1"
}

# Oldest first, while the disk is too full and more than KEEP_MIN are left.
make_room() {
  local s
  while [ "$(used_pct)" -gt $((100 - MIN_FREE_PCT)) ]; do
    mapfile -t all < <(snapshots)
    if [ "${#all[@]}" -le "$KEEP_MIN" ]; then
      echo "<4>bulk-backup: $DEST is $(used_pct)% full with only ${#all[@]} snapshots left" >&2
      return
    fi
    s=${all[0]}
    drop "$s"
    # Space comes back only once the cleaner has run; without waiting, df
    # still reads full and the loop would take the next snapshot too.
    btrfs -q subvolume sync "$DEST"
  done
}

make_room

# --- mirror ----------------------------------------------------------------

start=$(date +%s)
# rsync itemizes every created, updated or deleted entry here, one per line.
# An empty list means nothing changed and no new version is needed.
changes=$(mktemp)
trap 'rm -f "$changes"' EXIT
for s in "${SOURCES[@]}"; do
  name=$(basename "$s")
  echo "mirroring $s -> $DEST/current/$name"
  rc=0
  rsync -aHAX --numeric-ids --delete --delete-excluded \
        --exclude=/lost+found --out-format='%i %n' \
        "$s/" "$DEST/current/$name/" >> "$changes" || rc=$?
  # 24 = files vanished while rsync ran (the server deletes or moves files
  # all the time). The copy is still consistent for everything that stayed.
  [ "$rc" = 0 ] || [ "$rc" = 24 ] || die "rsync of $s failed with exit $rc"
done

# Drop mirrors of sources that were removed from SOURCES, so they do not linger
# in every future snapshot.
shopt -s nullglob
for d in "$DEST/current"/*/; do
  name=$(basename "$d")
  keep=0
  for s in "${SOURCES[@]}"; do [ "$(basename "$s")" = "$name" ] && keep=1; done
  [ "$keep" = 1 ] || { echo "removing stale mirror current/$name"; echo "*deleting $name/" >> "$changes"; rm -rf --one-file-system "$d"; }
done
n_changes=$(wc -l < "$changes")

# --- snapshot --------------------------------------------------------------

stamp=$(date +%Y-%m-%dT%H%M)
latest=$(snapshots | tail -n1)
if [ "$n_changes" = 0 ] && [ -n "$latest" ]; then
  echo "no changes since snapshot $latest, not taking another"
  stamp=$latest
elif [ -e "$DEST/snapshots/$stamp" ]; then
  echo "snapshot $stamp already exists, not taking another"
else
  btrfs -q subvolume snapshot -r "$DEST/current" "$DEST/snapshots/$stamp"
  echo "snapshot $stamp taken ($n_changes changed entries)"
fi

# --- retention -------------------------------------------------------------

mapfile -t newest_first < <(snapshots | sort -r)
declare -A keep=()

# Keep the newest snapshot of each of the latest $2 buckets (0 = all of them),
# bucket = date +$1.
tier() {
  local fmt=$1 n=$2 last="" count=0 s key
  for s in "${newest_first[@]}"; do
    [ "$n" = 0 ] || [ "$count" -lt "$n" ] || break
    key=$(date -d "${s:0:10} ${s:11:2}:${s:13:2}" +"$fmt")
    if [ "$key" != "$last" ]; then
      keep[$s]=1
      last=$key
      count=$((count + 1))
    fi
  done
}

tier '%F %H'  "$KEEP_HOURLY"
tier '%F'     "$KEEP_DAILY"
tier '%G-W%V' "$KEEP_WEEKLY"
tier '%Y-%m'  "$KEEP_MONTHLY"

for s in "${newest_first[@]}"; do
  [ -n "${keep[$s]:-}" ] || drop "$s"
done

make_room

# --- report ----------------------------------------------------------------

count=$(snapshots | wc -l)
oldest=$(snapshots | head -n1)
avail=$(df --output=avail -B1 "$DEST" | tail -n1 | tr -dc '0-9')
took=$(( $(date +%s) - start ))

cat > "$STATE_DIR/status.json.part" <<EOF
{"last_ok":"$(date -Is)","snapshot":"$stamp","snapshots":$count,"oldest":"$oldest","used_pct":$(used_pct),"avail_bytes":$avail,"changes":$n_changes,"took_s":$took}
EOF
mv "$STATE_DIR/status.json.part" "$STATE_DIR/status.json"

echo "backup ok: $n_changes changes, snapshot $stamp in ${took}s, $count snapshots (oldest $oldest), disk $(used_pct)% used"
