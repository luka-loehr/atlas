#!/usr/bin/env bash
# Watches ~/takeout/photos for takeout zips and ingests each exactly once,
# sequentially (never two ingests at once — they'd thrash CPU/IO/DB).
#
# A zip is considered done when a "<zip>.ingested" marker exists; the marker is
# only written after ingest_takeout.py exits 0, so a crashed/interrupted ingest
# re-runs on the next pass (the ingester itself is idempotent — known hashes
# are skipped). Runs forever; start via screen/systemd:
#   screen -dmS ingestwatch bash ~/atlas/apps/atlas-photos/ingest/ingest_watcher.sh
set -u
# ATLAS_TAKEOUT_DIR: where the takeout zips arrive (default $HOME/takeout/photos)
DIR="${ATLAS_TAKEOUT_DIR:-$HOME/takeout/photos}"
# ingester lives next to this script — no repo-location assumption
ING="$(cd "$(dirname "$0")" && pwd)/ingest_takeout.py"
# ATLAS_INGEST_LOG: watcher log file (default $HOME/ingest_watcher.log)
LOG="${ATLAS_INGEST_LOG:-$HOME/ingest_watcher.log}"

echo "$(date -Is) watcher up" >> "$LOG"
while true; do
  # never run two ingests at once — also covers manually started ones
  if pgrep -f "ingest_takeout.py" >/dev/null 2>&1; then
    sleep 60
    continue
  fi
  shopt -s nullglob
  for zip in "$DIR"/takeout-*.zip; do
    [ -e "$zip.ingested" ] && continue
    pgrep -f "ingest_takeout.py" >/dev/null 2>&1 && break
    # wait until the zip is stable (rsync may still be writing/replacing it)
    s1=$(stat -c%s "$zip" 2>/dev/null || echo 0)
    sleep 10
    s2=$(stat -c%s "$zip" 2>/dev/null || echo 0)
    [ "$s1" != "$s2" ] || [ "$s1" -lt 1000000 ] && continue

    # validate the archive before ingesting — a rsync --partial leftover under
    # the final name is stable-but-truncated and would crash the ingester
    # (BadZipFile) and burn a 5-min retry every pass. Skip until it's whole.
    if ! unzip -l "$zip" >/dev/null 2>&1; then
      echo "$(date -Is) SKIP $(basename "$zip") — noch kein vollstaendiges Zip (Transfer laeuft?)" >> "$LOG"
      continue
    fi

    echo "$(date -Is) INGEST-START $(basename "$zip") ($((s1/1024/1024/1024))G)" >> "$LOG"
    if python3 "$ING" "$zip" >> "$LOG" 2>&1; then
      touch "$zip.ingested"
      # zip is now redundant: originals are extracted to ~/photos + in the DB.
      # Delete it so the archive and its unpacked copy don't sit on disk at 2x.
      rm -f "$zip"
      echo "$(date -Is) INGEST-DONE $(basename "$zip") — Zip geloescht (Originale gesichert)" >> "$LOG"
    else
      echo "$(date -Is) INGEST-FAILED $(basename "$zip") — retry naechster Durchlauf" >> "$LOG"
      sleep 300
    fi
  done
  shopt -u nullglob
  sleep 60
done
