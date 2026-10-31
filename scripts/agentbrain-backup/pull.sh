#!/usr/bin/env bash
# agentbrain-backup — copy your agentbrain memories to this server, hourly.
#
# Runs every hour: on its own timer, or, when scripts/bulk-backup is installed,
# right before each bulk backup, so every hour's snapshot on the backup disk
# holds that hour's archive. The files in $DEST are the newest archive plus the
# last one of every day:
#
#   $DEST/latest.json.gz             the newest archive
#   $DEST/daily/<YYYY-MM-DD>.json.gz  the last archive of each day (UTC)
#
# The archive is gzipped JSON (format agentbrain-backup/1) of every project,
# memory, relation, version, task and activity row plus the account's auth
# rows. It is fetched with a backup key, which can download the archive and do
# nothing else. Every download is checked before it replaces anything: the
# SHA-256 the server sends, gzip integrity, the format and the counts.
#
# Shrink brake: an archive with far fewer memories than the last one is kept
# under held/ instead, latest and daily stay as they were, and the run fails
# (mail). If the drop was intended: sudo touch $STATE_DIR/accept-shrink.
set -euo pipefail

DEST=${AGENTBRAIN_BACKUP_DEST:-/srv/bulk/agentbrain}
URL=${AGENTBRAIN_URL:?AGENTBRAIN_URL is not set (/etc/atlas/agentbrain-backup.env)}
KEY_FILE=${AGENTBRAIN_BACKUP_KEY_FILE:-${CREDENTIALS_DIRECTORY:-/nonexistent}/agentbrain-backup.key}
STATE_DIR=${STATE_DIRECTORY:-/var/lib/atlas-agentbrain-backup}
LOCK=${ATLAS_BACKUP_LOCK:-/run/lock/atlas-backup.lock}
# Keep latest/daily only when the new archive holds at least this share of the
# last one's memories (percent), once there are enough to compare.
MIN_KEEP_PCT=${AGENTBRAIN_BACKUP_MIN_KEEP_PCT:-75}
MIN_COMPARE=${AGENTBRAIN_BACKUP_MIN_COMPARE:-50}

die() { echo "<3>agentbrain-backup: $*" >&2; exit 1; }
log() { echo "agentbrain-backup: $*"; }

[ -r "$KEY_FILE" ] || die "backup key $KEY_FILE is not readable (LoadCredential)"
# A missing directory also catches a data disk that is not mounted (the unit
# has RequiresMountsFor= on $DEST as well): never write onto the root disk.
[ -d "$DEST" ] && [ -w "$DEST" ] || die "$DEST is missing or not writable (run install.sh)"
mkdir -p "$STATE_DIR" "$DEST/daily"

# The bulk backup must not snapshot a half-written archive. (Partial files end
# in .part, which it skips anyway.)
exec 9<"$LOCK" || die "lock file $LOCK is missing (run install.sh)"
flock -w 3600 9 || die "another backup job held $LOCK for an hour"

stamp=$(date -u +%Y-%m-%dT%H-%M-%SZ)
tmp="$DEST/.pull-$stamp.json.gz.part"
hdr=$(mktemp)
trap 'rm -f "$tmp" "$hdr"' EXIT

# The key reaches curl through a process substitution, never argv or the environment.
curl -fsS --max-time 600 --connect-timeout 30 --retry 4 --retry-all-errors --retry-delay 10 \
  -H @<(printf 'Authorization: Bearer %s\n' "$(<"$KEY_FILE")") \
  -H 'Accept: application/gzip' -D "$hdr" -o "$tmp" "$URL/archive" \
  || die "download failed"

header() { awk -F': ' -v k="$1" 'tolower($1) == k { gsub("\r", ""); v = $2 } END { print v }' "$hdr"; }
want=$(header x-agentbrain-sha256)
nodes=$(header x-agentbrain-nodes)
edges=$(header x-agentbrain-edges)
versions=$(header x-agentbrain-versions)
exported=$(header x-agentbrain-exported-at)
got=$(sha256sum "$tmp" | cut -d' ' -f1)
[ -n "$want" ] && [ "$want" = "$got" ] || die "checksum mismatch (server ${want:-none}, file $got)"
gzip -t "$tmp" || die "archive is not valid gzip"
check=$(gzip -dc "$tmp" | jq -r '[.format, (.nodes | length), (.edges | length), (.node_versions | length)] | @tsv') \
  || die "archive is not valid JSON"
[ "$check" = "agentbrain-backup/1	$nodes	$edges	$versions" ] || die "archive content ($check) does not match its headers ($nodes/$edges/$versions)"
bytes=$(stat -c %s "$tmp")
chmod 0640 "$tmp"

prev=$(jq -r '.nodes // 0' "$STATE_DIR/status.json" 2>/dev/null || echo 0)
if [ "$prev" -ge "$MIN_COMPARE" ] && [ $((nodes * 100)) -lt $((prev * MIN_KEEP_PCT)) ]; then
  if [ -e "$STATE_DIR/accept-shrink" ]; then
    log "memories dropped from $prev to $nodes; accepted (accept-shrink)"
    rm -f "$STATE_DIR/accept-shrink"
  else
    mkdir -p "$DEST/held"
    mv "$tmp" "$DEST/held/$stamp.json.gz"
    die "memories dropped from $prev to $nodes: kept as held/$stamp.json.gz, latest and daily unchanged. If intended: sudo touch $STATE_DIR/accept-shrink"
  fi
fi

day=${exported:0:10}
[[ $day =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || day=$(date -u +%F)
# Hard link first, then rename both into place: each path always holds a
# complete archive.
ln -f "$tmp" "$DEST/daily/.$day.json.gz.part"
mv -f "$DEST/daily/.$day.json.gz.part" "$DEST/daily/$day.json.gz"
mv -f "$tmp" "$DEST/latest.json.gz"

jq -n --arg t "$(date -u +%FT%TZ)" --arg e "$exported" --arg s "$got" \
  --argjson n "$nodes" --argjson r "$edges" --argjson v "$versions" --argjson b "$bytes" \
  '{last_ok: $t, exported_at: $e, sha256: $s, nodes: $n, edges: $r, versions: $v, bytes: $b}' \
  >"$STATE_DIR/status.json.tmp"
mv -f "$STATE_DIR/status.json.tmp" "$STATE_DIR/status.json"
log "archive of $exported: $nodes memories, $edges relations, $versions versions, $bytes bytes"
