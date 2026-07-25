#!/usr/bin/env bash
# Restore drill: restore the newest backup into a scratch database inside the
# atlas-postgres container and compare exact per-table row counts against the
# live database. Exits non-zero on any mismatch. Drops the scratch DB on
# success; pass --keep to leave it around for inspection.
#
# The scratch DB is named atlas_restore_drill — nothing else uses that name.
set -euo pipefail

BACKUP_DIR=${BACKUP_DIR:-/srv/backups/atlas-postgres}
CONTAINER=${CONTAINER:-atlas-postgres}
DB_USER=${DB_USER:-atlas}
DRILL_DB=atlas_restore_drill
KEEP=${1:-}

dump=$(ls -1 "$BACKUP_DIR"/atlas_*.dump | sort | tail -n1)
echo "drill: restoring $dump into $DRILL_DB"

psql_c() { docker exec "$CONTAINER" psql -U "$DB_USER" -d "$1" -Atc "$2"; }

docker exec "$CONTAINER" psql -U "$DB_USER" -d postgres -c "DROP DATABASE IF EXISTS $DRILL_DB" > /dev/null
docker exec "$CONTAINER" psql -U "$DB_USER" -d postgres -c "CREATE DATABASE $DRILL_DB TEMPLATE template0" > /dev/null

docker exec -i "$CONTAINER" pg_restore -U "$DB_USER" -d "$DRILL_DB" --no-owner --exit-on-error < "$dump"

# Exact row counts for every user table, source vs. restored.
count_sql="SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind='r' ORDER BY 1"
tables=$(psql_c "$DRILL_DB" "$count_sql")

fail=0
printf '%-20s %12s %12s\n' table live restored
while read -r t; do
  live=$(psql_c atlas "SELECT count(*) FROM \"$t\"")
  rest=$(psql_c "$DRILL_DB" "SELECT count(*) FROM \"$t\"")
  mark=""
  # Live counts can drift while the pipeline writes; flag but don't hard-fail
  # on ingest_jobs, hard-fail on everything else.
  if [ "$live" != "$rest" ]; then
    mark=" MISMATCH"
    [ "$t" = "ingest_jobs" ] || fail=1
  fi
  printf '%-20s %12s %12s%s\n' "$t" "$live" "$rest" "$mark"
done <<< "$tables"

# Sanity beyond counts: an embedding is readable and has the right dimension.
dim=$(psql_c "$DRILL_DB" "SELECT vector_dims(vec) FROM embeddings LIMIT 1")
echo "embeddings vector_dims: $dim (expect 2048)"
[ "$dim" = "2048" ] || fail=1

if [ "$KEEP" != "--keep" ]; then
  docker exec "$CONTAINER" psql -U "$DB_USER" -d postgres -c "DROP DATABASE $DRILL_DB" > /dev/null
  echo "drill: scratch DB dropped"
fi

if [ "$fail" = 0 ]; then echo "drill: PASS"; else echo "drill: FAIL"; exit 1; fi
