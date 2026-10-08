#!/usr/bin/env bash
# bulk-backup — mirror /srv/bulk (and the Postgres dumps) onto the USB backup
# disk, then take a read-only btrfs snapshot of the mirror.
#
# The backup disk is btrfs (label atlas-bulk-backup, mounted at
# /srv/bulk-backup):
#
#   current/             subvolume, rsync target, always the latest state
#     bulk/              = /srv/bulk
#     backups/           = /srv/backups (nightly pg_dump output)
#   snapshots/<stamp>Z/  read-only snapshots of current/, stamp in UTC
#
# Snapshots share every unchanged extent with current/, so a version costs only
# what changed since the previous one. A snapshot is taken only after every
# rsync succeeded, so a half-finished run never becomes a version. An idle hour
# adds no version; a run after a failed one always takes one, because the
# failed run may have changed current/ without a snapshot.
#
# Mass-change brake: if one run deletes or overwrites more than
# MASS_CHANGE_LIMIT existing files (outside bulk/github, whose clones churn by
# design), no snapshot is taken and the job holds: every later run fails until
# someone looks and removes $STATE_DIR/hold. The snapshots from before the
# incident stay untouched meanwhile.
#
# Retention keeps the newest snapshot per bucket (buckets in local time):
# KEEP_HOURLY hours, KEEP_DAILY days, KEEP_WEEKLY ISO weeks, KEEP_MONTHLY
# months; 0 means no limit (the default for days: one version of every day,
# forever). If the disk has less than MIN_FREE_PCT free, the oldest snapshots go
# next, but never one younger than MIN_AGE_DAYS and never below KEEP_MIN.
#
# Runs as root (ownership, ACLs, btrfs ioctls). Failures go to the journal at
# err priority, and the unit's OnFailure= mails them.
set -euo pipefail

DEST=${BULK_BACKUP_DEST:-/srv/bulk-backup}
DEST_LABEL=${BULK_BACKUP_LABEL:-atlas-bulk-backup}
# Each source is mirrored to current/<basename>.
read -r -a SOURCES <<< "${BULK_BACKUP_SOURCES:-/srv/bulk /srv/backups}"
# Sources that are their own filesystem. If one is not mounted, the directory
# underneath is empty and rsync --delete would wipe its mirror.
read -r -a MUST_BE_MOUNTED <<< "${BULK_BACKUP_MUST_BE_MOUNTED:-/srv/bulk}"
# Every source must carry this file (install.sh creates it). A freshly
# formatted or wrongly mounted disk does not, so it is never mirrored.
MARKER=.atlas-backup-source
STATE_DIR=${STATE_DIRECTORY:-/var/lib/atlas-bulk-backup}
# Shared with github-sync, so no snapshot catches a half-updated clone
# (created by tmpfiles, see install.sh). pg-backup needs none: it writes
# *.part, which is skipped, and renames atomically.
LOCK=${ATLAS_BACKUP_LOCK:-/run/lock/atlas-backup.lock}

KEEP_HOURLY=${KEEP_HOURLY:-24}
KEEP_DAILY=${KEEP_DAILY:-0}
KEEP_WEEKLY=${KEEP_WEEKLY:-8}
KEEP_MONTHLY=${KEEP_MONTHLY:-12}
KEEP_MIN=${KEEP_MIN:-2}
MIN_FREE_PCT=${MIN_FREE_PCT:-10}
MIN_AGE_DAYS=${MIN_AGE_DAYS:-30}
MASS_CHANGE_LIMIT=${MASS_CHANGE_LIMIT:-1000}
# make_room drops at most this many snapshots per run, and stops as soon as a
# drop frees less than 1 % (old snapshots share most blocks with current/).
MAX_SPACE_PRUNE=${MAX_SPACE_PRUNE:-8}
# Retention never drops more than this many snapshots in one run; more means
# a config or clock mistake, not normal ageing (1-2 per hour).
MAX_PRUNE=${MAX_PRUNE:-48}

die() { echo "<3>bulk-backup: $*" >&2; exit 1; }

# --- preflight -------------------------------------------------------------

exec 9<"$LOCK" || die "lock file $LOCK is missing (run install.sh)"
flock -w 3600 9 || die "another backup job held $LOCK for an hour"

[ ! -e "$STATE_DIR/hold" ] || die "held after a mass change: $(head -n 1 "$STATE_DIR/hold") Details in $STATE_DIR/hold."

read -r fstype label uuid < <(findmnt -n -o FSTYPE,LABEL,UUID --mountpoint "$DEST") || true
[ "${fstype:-}" = btrfs ] && [ "${label:-}" = "$DEST_LABEL" ] \
  || die "$DEST is not the mounted btrfs disk $DEST_LABEL (got '${fstype:-nothing}' '${label:-}') — is the USB disk plugged in?"
# The label alone could match a different disk; fstab names the one by UUID.
want=$(findmnt --tab-file "${BULK_BACKUP_FSTAB:-/etc/fstab}" -n -o SOURCE "$DEST" || true)
[ "$want" = "UUID=$uuid" ] || die "$DEST is UUID $uuid, fstab expects '${want:-nothing}'"
findmnt -n -o OPTIONS --mountpoint "$DEST" | grep -qw rw || die "$DEST is mounted read-only (btrfs errors?)"
btrfs device stats --check "$DEST" >/dev/null || die "btrfs reports device errors on $DEST: $(btrfs device stats "$DEST" | grep -v ' 0$' | tr '\n' ' ')"

for m in "${MUST_BE_MOUNTED[@]}"; do
  mountpoint -q "$m" || die "$m is not mounted; refusing to mirror an empty directory over the backup"
done
for s in "${SOURCES[@]}"; do
  [ -f "$s/$MARKER" ] || die "$s/$MARKER is missing; refusing to mirror what may be an empty or foreign disk"
done

mkdir -p "$DEST/snapshots" "$STATE_DIR"
[ -d "$DEST/current" ] || btrfs -q subvolume create "$DEST/current"

# --- snapshots -------------------------------------------------------------

# Snapshots used to be named in local time without the Z; rename them once.
# Local stamps repeat when the clock goes back, UTC ones never do.
shopt -s nullglob
for d in "$DEST"/snapshots/????-??-??T????; do
  s=${d##*/}
  [[ $s =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{4}$ ]] || continue
  # Parsed in local time (date -u would also parse as UTC), printed in UTC.
  u=$(date -u -d "@$(date -d "${s:0:10} ${s:11:2}:${s:13:2}" +%s)" +%Y-%m-%dT%H%MZ)
  [ -e "$DEST/snapshots/$u" ] || { mv -T "$d" "$DEST/snapshots/$u"; echo "renamed snapshot $s -> $u"; }
done
shopt -u nullglob

snapshots() {
  find "$DEST/snapshots" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' \
    | { grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{4}Z$' || true; } | sort
}

used_pct() { df --output=pcent "$DEST" | tail -n1 | tr -dc '0-9'; }

drop() {
  btrfs -q subvolume delete --commit-after "$DEST/snapshots/$1" >/dev/null
  echo "pruned snapshot $1"
}

# Oldest first, while the disk is too full, more than KEEP_MIN are left and
# the oldest is older than MIN_AGE_DAYS. Recent history is never traded for
# space: the run warns instead and the health check mails it.
make_room() {
  local s cutoff before n=0
  cutoff=$(date -u -d "-$MIN_AGE_DAYS days" +%Y-%m-%dT%H%MZ)
  while [ "$(used_pct)" -gt $((100 - MIN_FREE_PCT)) ]; do
    if [ "$n" -ge "$MAX_SPACE_PRUNE" ]; then
      echo "<4>bulk-backup: $DEST is $(used_pct)% full after pruning $n snapshots this run; stopping here" >&2
      return
    fi
    mapfile -t all < <(snapshots)
    s=${all[0]:-}
    if [ "${#all[@]}" -le "$KEEP_MIN" ] || [[ ! $s < $cutoff ]]; then
      echo "<4>bulk-backup: $DEST is $(used_pct)% full; ${#all[@]} snapshots, oldest $s, none older than $MIN_AGE_DAYS days to prune" >&2
      return
    fi
    before=$(used_pct)
    drop "$s"
    n=$((n + 1))
    # Space comes back only once the cleaner has run; without waiting, df
    # still reads full and the loop would take the next snapshot too.
    btrfs -q subvolume sync "$DEST"
    if [ $((before - $(used_pct))) -lt 1 ]; then
      echo "<4>bulk-backup: dropping $s freed less than 1 %; current/ itself fills $DEST, not the history — stopping" >&2
      return
    fi
  done
}

make_room

# --- mirror ----------------------------------------------------------------

start=$(date +%s)
# A run that dies after rsync touched current/ leaves this behind, so the next
# run snapshots even if it has nothing left to copy.
had_pending=0
[ -e "$STATE_DIR/pending" ] && had_pending=1
touch "$STATE_DIR/pending"

# rsync itemizes every created, updated or deleted entry here, one per line,
# as "<flags> <source name>/<path>". The list lives in the state directory and
# keeps growing until a snapshot is taken, so a run that dies half-way (after
# --delete already ran) cannot hide its deletions from the brake next time.
changes=$STATE_DIR/changes
[ "$had_pending" = 1 ] || : > "$changes"
run_start=$(wc -l < "$changes")
failed_rc=""
for s in "${SOURCES[@]}"; do
  name=$(basename "$s")
  echo "mirroring $s -> $DEST/current/$name"
  rc=0
  # *.part: dumps and clones still being written by the other jobs.
  rsync -aHAX --numeric-ids --delete --delete-excluded \
        --exclude=/lost+found --exclude='*.part' --out-format="%i $name/%n" \
        "$s/" "$DEST/current/$name/" >> "$changes" || rc=$?
  # 24 = files vanished while rsync ran (the server deletes or moves files
  # all the time). The copy is still consistent for everything that stayed.
  # Anything else fails the run, but only after the brake below has looked.
  [ "$rc" = 0 ] || [ "$rc" = 24 ] || failed_rc+="$s:$rc "
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
shopt -u nullglob
n_changes=$(( $(wc -l < "$changes") - run_start ))

# Deleted entries and overwritten existing files ('>f' without the '+' of a new
# file). github/ is left out: its working trees and loose objects come and go
# with every pushed refactor and git gc, and its history is git's own.
# rsync pads "*deleting" with extra spaces, hence " +".
lost=$(grep -E '^(\*deleting|>f[^+])' "$changes" | grep -cEv '^[^ ]+ +bulk/github/' || true)
if [ "$lost" -gt "$MASS_CHANGE_LIMIT" ]; then
  {
    echo "$(date -Is): $lost files deleted or overwritten in one run (limit $MASS_CHANGE_LIMIT); no snapshot taken."
    echo "Check /srv/bulk. If this was intended: sudo rm $STATE_DIR/hold (the next run snapshots it)."
    echo "First entries:"
    grep -E '^(\*deleting|>f[^+])' "$changes" | grep -Ev '^[^ ]+ +bulk/github/' | head -n 20 || true
  } > "$STATE_DIR/hold"
  # Releasing the hold accepts these changes: start the list afresh, while
  # pending stays so the next run snapshots the accepted state.
  : > "$changes"
  die "mass change: $lost files deleted or overwritten, holding (see $STATE_DIR/hold)"
fi

[ -z "$failed_rc" ] || die "rsync failed (source:exit): $failed_rc"

# --- snapshot --------------------------------------------------------------

stamp=$(date -u +%Y-%m-%dT%H%MZ)
latest=$(snapshots | tail -n1)
if [ "$n_changes" = 0 ] && [ "$had_pending" = 0 ] && [ -n "$latest" ]; then
  echo "no changes since snapshot $latest, not taking another"
  stamp=$latest
else
  # Two runs within one minute: wait for a fresh stamp rather than skip.
  while [ -e "$DEST/snapshots/$stamp" ]; do sleep 5; stamp=$(date -u +%Y-%m-%dT%H%MZ); done
  btrfs -q subvolume snapshot -r "$DEST/current" "$DEST/snapshots/$stamp"
  echo "snapshot $stamp taken ($n_changes changed entries)"
fi
rm -f "$STATE_DIR/pending"
: > "$changes"

# --- retention -------------------------------------------------------------

mapfile -t newest_first < <(snapshots | sort -r)
declare -A keep=()

# Bucket keys in local time, one date call for all snapshots.
declare -A k_hour=() k_day=() k_week=() k_month=()
if [ "${#newest_first[@]}" -gt 0 ]; then
  i=0
  while IFS='|' read -r h d w m; do
    s=${newest_first[$i]}
    k_hour[$s]=$h; k_day[$s]=$d; k_week[$s]=$w; k_month[$s]=$m
    i=$((i + 1))
  done < <(for s in "${newest_first[@]}"; do echo "${s:0:10} ${s:11:2}:${s:13:2} UTC"; done \
             | date -f - +'%F %H|%F|%G-W%V|%Y-%m')
  [ "$i" = "${#newest_first[@]}" ] || die "could not parse snapshot names"
fi

# Keep the newest snapshot of each of the latest $2 buckets (0 = all of them).
tier() {
  local -n key=$1
  local n=$2 last="" count=0 s
  for s in "${newest_first[@]}"; do
    [ "$n" = 0 ] || [ "$count" -lt "$n" ] || break
    if [ "${key[$s]}" != "$last" ]; then
      keep[$s]=1
      last=${key[$s]}
      count=$((count + 1))
    fi
  done
}

tier k_hour  "$KEEP_HOURLY"
tier k_day   "$KEEP_DAILY"
tier k_week  "$KEEP_WEEKLY"
tier k_month "$KEEP_MONTHLY"

doomed=()
for s in "${newest_first[@]}"; do
  [ -n "${keep[$s]:-}" ] || doomed+=("$s")
done
[ "${#doomed[@]}" -le "$MAX_PRUNE" ] \
  || die "retention would prune ${#doomed[@]} snapshots at once (limit $MAX_PRUNE); check KEEP_* and the clock, or run once with MAX_PRUNE raised"
for s in "${doomed[@]}"; do drop "$s"; done

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
