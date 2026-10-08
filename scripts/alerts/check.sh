#!/usr/bin/env bash
# atlas-backup-check — hourly health check of the backup jobs and the disks,
# alerts through atlas-alert (once per problem per day, plus a "resolved" mail).
#
#   atlas-backup-check            check, mail new problems and resolutions
#   atlas-backup-check --weekly   also mail a summary, problems or not, so a
#                                 silent alert channel gets noticed
#
# OnFailure= on each job reports a failed run. This catches what OnFailure
# cannot: a job that stops running at all (timer gone, unit removed), a held
# backup, failed repos in an otherwise finished sync, dying disks, a full
# backup disk, and the mail key running out.
set -uo pipefail

ALERT=${ATLAS_ALERT:-/usr/local/sbin/atlas-alert}
BULK_STATUS=/var/lib/atlas-bulk-backup/status.json
BULK_HOLD=/var/lib/atlas-bulk-backup/hold
SYNC_STATUS=/var/lib/atlas-github-sync/status.json
DUMPS=/srv/backups/atlas-postgres
DEST=/srv/bulk-backup
KEY_EXPIRES=/etc/atlas/credentials/lmail-alerts.expires
UNITS=(atlas-bulk-backup atlas-github-sync atlas-pg-backup atlas-bulk-backup-scrub)
TIMERS=(atlas-bulk-backup.timer atlas-pg-backup.timer atlas-bulk-backup-scrub.timer)

now=$(date +%s)
# atlas is switched off whenever it is not needed. A job counts as late only
# if the box has been up long enough for it to have run since boot.
up=$(cut -d. -f1 /proc/uptime)

declare -A problems=()   # key -> one line
problem() { problems[$1]=$2; }

age_h() { echo $(( (now - $1) / 3600 )); }
json_time() { jq -r ".$2 // empty" "$1" 2>/dev/null | xargs -r -I{} date -d {} +%s 2>/dev/null; }

# --- jobs ------------------------------------------------------------------

for t in "${TIMERS[@]}"; do
  systemctl is-enabled -q "$t" && systemctl is-active -q "$t" || problem "timer:$t" "timer $t is not enabled and active"
done
systemctl show -p WantedBy atlas-github-sync.service 2>/dev/null | grep -q atlas-bulk-backup.service \
  || problem "hook:github-sync" "atlas-github-sync is no longer hooked into atlas-bulk-backup"

for u in "${UNITS[@]}"; do
  systemctl is-failed -q "$u.service" && problem "unit:$u.service" "$u.service is in failed state"
done

if [ -e "$BULK_HOLD" ]; then
  problem "bulk:hold" "bulk backup is held after a mass change: $(head -n 2 "$BULK_HOLD" | tr '\n' ' ')"
fi

t=$(json_time "$BULK_STATUS" last_ok)
if [ -z "$t" ]; then
  problem "bulk:stale" "bulk backup has no successful run on record"
elif [ $((now - t)) -gt 10800 ] && [ "$up" -gt 10800 ]; then
  problem "bulk:stale" "last successful bulk backup is $(age_h "$t") h old"
fi

t=$(json_time "$SYNC_STATUS" last_run)
if [ -z "$t" ]; then
  problem "sync:stale" "github sync has no finished run on record"
elif [ $((now - t)) -gt 10800 ] && [ "$up" -gt 10800 ]; then
  problem "sync:stale" "last finished github sync is $(age_h "$t") h old"
fi
failed=$(jq -r '(.failed // []) | join(", ")' "$SYNC_STATUS" 2>/dev/null)
[ -z "$failed" ] || problem "sync:failed" "github sync failed for: $failed"
ignored=$(jq -r '(.ignored_installations // []) | join(", ")' "$SYNC_STATUS" 2>/dev/null)
[ -z "$ignored" ] || problem "sync:ignored" "GitHub App installed on accounts not in the allowlist (not synced): $ignored"

newest=$(find "$DUMPS" -maxdepth 1 -name 'atlas_*.dump' -printf '%T@\n' 2>/dev/null | sort -n | tail -n1 | cut -d. -f1)
if [ -z "$newest" ]; then
  problem "pg:stale" "no Postgres dump in $DUMPS"
elif [ $((now - newest)) -gt 129600 ] && [ "$up" -gt 21600 ]; then
  problem "pg:stale" "newest Postgres dump is $(age_h "$newest") h old"
fi

# --- disks -----------------------------------------------------------------

if ! mountpoint -q "$DEST"; then
  problem "disk:unmounted" "the USB backup disk is not mounted at $DEST"
else
  pct=$(df --output=pcent "$DEST" | tail -n1 | tr -dc '0-9')
  [ "$pct" -lt 85 ] || problem "disk:full" "USB backup disk is $pct% full"
  btrfs device stats --check "$DEST" >/dev/null 2>&1 \
    || problem "disk:btrfs" "btrfs device errors on $DEST: $(btrfs device stats "$DEST" | grep -v ' 0$' | tr '\n' ' ')"
  findmnt -n -o OPTIONS --mountpoint "$DEST" | grep -qw rw || problem "disk:ro" "$DEST is mounted read-only"
fi
mountpoint -q /srv/bulk || problem "disk:bulk" "/srv/bulk is not mounted"

while read -r dev _ type _; do
  [ -n "$dev" ] || continue
  out=$(smartctl -H -d "$type" "$dev" 2>&1); rc=$?
  # Bit 3: disk failing; bit 4: prefail attribute at or below threshold now.
  if [ $((rc & 24)) -ne 0 ] || grep -qiE 'FAILED|FAILING' <<<"$out"; then
    problem "smart:$dev" "SMART says $dev is failing: $(grep -iE 'result|status' <<<"$out" | head -n 2 | tr '\n' ' ')"
  fi
done < <(smartctl --scan-open 2>/dev/null | grep -v '^#')

for f in "$KEY_EXPIRES"; do
  [ -r "$f" ] || continue
  exp=$(date -d "$(cat "$f")" +%s 2>/dev/null) || continue
  [ $((exp - now)) -gt $((30 * 86400)) ] \
    || problem "key:lmail" "the alert mail key expires on $(cat "$f"); issue a new one (scripts/alerts/README.md)"
done

# --- report ----------------------------------------------------------------

STATE=${ATLAS_ALERT_STATE:-/var/lib/atlas-alerts}
rc=0
for k in "${!problems[@]}"; do
  echo "<4>problem: ${problems[$k]}"
  printf '%s\n\nChecked %s. Details: journalctl -u atlas-backup-check -n 50, and the README of the job in ~/atlas/scripts.\n' \
    "${problems[$k]}" "$(date '+%F %T %Z')" | "$ALERT" "$k" "${problems[$k]}" || rc=1
done

# A problem from an earlier run that is gone now. Unit keys belong to
# OnFailure mails; they resolve once the unit is no longer failed.
shopt -s nullglob
for f in "$STATE"/*; do
  k=$(basename "$f")
  key=$k
  for p in "${!problems[@]}"; do [ "$(printf '%s' "$p" | tr -c 'A-Za-z0-9._@:-' '_')" = "$k" ] && key=""; done
  [ -n "$key" ] || continue
  if [[ $k == unit:* ]]; then systemctl is-failed -q "${k#unit:}" && continue; fi
  "$ALERT" --resolve "$k" "$(cat "$f")" || rc=1
done

if [ "${1:-}" = --weekly ]; then
  {
    if [ "${#problems[@]}" = 0 ]; then echo "All backup checks pass."; else
      echo "Open problems:"; for k in "${!problems[@]}"; do echo "- ${problems[$k]}"; done; fi
    echo
    echo "Bulk backup:  $(jq -c . "$BULK_STATUS" 2>/dev/null || echo 'no status')"
    echo "GitHub sync:  $(jq -c 'del(.failed, .orphans) + {failed: (.failed|length), orphans: .orphans}' "$SYNC_STATUS" 2>/dev/null || echo 'no status')"
    echo "Newest dump:  $(ls -1t "$DUMPS"/atlas_*.dump 2>/dev/null | head -n1)"
    echo "USB disk:     $(df -h --output=used,avail,pcent "$DEST" 2>/dev/null | tail -n1)"
    echo "Snapshots:    $(ls "$DEST/snapshots" 2>/dev/null | wc -l), oldest $(ls "$DEST/snapshots" 2>/dev/null | head -n1)"
    echo
    echo "This mail comes every Monday. If it stops coming, the alerting itself is broken."
  } | ATLAS_ALERT_REPEAT_S=0 "$ALERT" "weekly" "weekly backup report: $([ "${#problems[@]}" = 0 ] && echo 'all good' || echo "${#problems[@]} problem(s)")" || rc=1
fi

echo "checked: ${#problems[@]} problem(s)"
exit $rc
