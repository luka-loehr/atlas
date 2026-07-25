#!/usr/bin/env bash
# Nightly logical backup of the atlas Postgres (Docker container atlas-postgres).
#
# Writes a custom-format pg_dump (zstd-compressed) plus a globals-only dump
# to $BACKUP_DIR, verifies the archive is readable with `pg_restore -l`,
# then applies retention: daily dumps kept KEEP_DAILY_DAYS days, first-of-month
# dumps kept KEEP_MONTHLY_DAYS days.
#
# No host Postgres tools required — everything runs inside the container.
set -euo pipefail

BACKUP_DIR=${BACKUP_DIR:-/srv/backups/atlas-postgres}
CONTAINER=${CONTAINER:-atlas-postgres}
DB=${DB:-atlas}
DB_USER=${DB_USER:-atlas}
KEEP_DAILY_DAYS=${KEEP_DAILY_DAYS:-14}
KEEP_MONTHLY_DAYS=${KEEP_MONTHLY_DAYS:-183}

stamp=$(date +%F)
dump="$BACKUP_DIR/atlas_${stamp}.dump"
globals="$BACKUP_DIR/globals_${stamp}.sql"

mkdir -p "$BACKUP_DIR"

# Dump to a .part file first so a failed run never leaves a truncated file
# that looks like a valid backup.
docker exec "$CONTAINER" pg_dump -U "$DB_USER" -Fc --compress=zstd "$DB" > "$dump.part"

# Roles/grants (tiny, but needed for a from-scratch rebuild).
docker exec "$CONTAINER" pg_dumpall -U "$DB_USER" --globals-only > "$globals.part"

# Verify the archive TOC is readable before declaring success.
docker exec -i "$CONTAINER" pg_restore -l < "$dump.part" > /dev/null

mv "$dump.part" "$dump"
mv "$globals.part" "$globals"

# Retention. First-of-month dumps are the monthly tier; everything else is daily.
find "$BACKUP_DIR" -name 'atlas_????-??-01.dump'   -mtime +"$KEEP_MONTHLY_DAYS" -delete
find "$BACKUP_DIR" -name 'globals_????-??-01.sql'  -mtime +"$KEEP_MONTHLY_DAYS" -delete
find "$BACKUP_DIR" -name 'atlas_*.dump'  ! -name 'atlas_????-??-01.dump'  -mtime +"$KEEP_DAILY_DAYS" -delete
find "$BACKUP_DIR" -name 'globals_*.sql' ! -name 'globals_????-??-01.sql' -mtime +"$KEEP_DAILY_DAYS" -delete
find "$BACKUP_DIR" -name '*.part' -mtime +1 -delete

echo "backup ok: $dump ($(du -h "$dump" | cut -f1)), $(ls "$BACKUP_DIR"/atlas_*.dump | wc -l) dumps retained"
