#!/usr/bin/env bash
# Robust Takeout → atlas transfer watcher.
#
# Watches ~/Downloads for completed `takeout-*.zip` files and moves each to
# atlas:~/takeout/photos/. Fixes the previous version's bugs:
#   • filenames with spaces / "(1)" browser-duplicate suffixes no longer break
#     word-splitting (glob + quoted vars, no `for x in $(ls …)`).
#   • idempotent: a part already on atlas with matching size is treated as a
#     duplicate and the local copy is deleted instead of endlessly re-rsynced.
#   • only completed downloads are touched (skips *.crdownload and files whose
#     size is still growing).
# Emits one line per meaningful event (Monitor turns each into a notification).
set -u
DL="$HOME/Downloads"
REMOTE_DIR="takeout/photos"
# Direktes Heimnetz-LAN (Gigabit) statt Tailscale-Relay.
HOST="atlas-lan"
# NUR der Foto-Export. Die Google-Drive-Datei (20260720T115546Z-1-001.zip)
# bleibt bewusst lokal und wird nie angefasst.
PHOTOS_GLOB="takeout-20260719T213848Z-*.zip"

canonical() {            # "takeout-…-1-004 (1).zip" -> "takeout-…-1-004.zip"
  basename "$1" | sed -E 's/ \(([0-9]+)\)\.zip$/.zip/'
}

remote_size() { ssh -o ConnectTimeout=15 "$HOST" "stat -c%s 'takeout/photos/$1' 2>/dev/null" 2>/dev/null; }

while true; do
  shopt -s nullglob
  for zip in "$DL"/$PHOTOS_GLOB; do
    [ -e "$zip" ] || continue
    # skip if a matching part is still downloading
    [ -e "$zip.crdownload" ] && continue

    # size-stability check: same size across a short interval = download done
    s1=$(stat -f%z "$zip" 2>/dev/null || echo 0)
    sleep 3
    s2=$(stat -f%z "$zip" 2>/dev/null || echo 0)
    [ "$s1" != "$s2" ] && continue          # still growing
    [ "$s1" -lt 1000000 ] && continue        # too small / partial

    name=$(canonical "$zip")

    # already on atlas with identical size -> local is a duplicate
    rsize=$(remote_size "$name")
    if [ -n "$rsize" ] && [ "$rsize" = "$s1" ]; then
      rm -f "$zip"
      echo "DUPLICATE-SKIP $name ($((s1/1024/1024/1024))G) — bereits auf atlas, lokale Kopie gelöscht"
      continue
    fi

    echo "TRANSFER-START $name ($((s1/1024/1024/1024))G) → atlas (LAN)"
    if rsync -a --partial --timeout=120 "$zip" "$HOST:$REMOTE_DIR/$name"; then
      rsize=$(remote_size "$name")
      if [ "$rsize" = "$s1" ]; then
        rm -f "$zip"
        echo "TRANSFERRED $name → atlas (verifiziert, Mac-Kopie gelöscht)"
      else
        echo "TRANSFER-VERIFY-FAIL $name — atlas=$rsize lokal=$s1, behalte lokale Kopie"
      fi
    else
      echo "RSYNC-FEHLER $name (exit $?) — retry beim nächsten Durchlauf"
    fi
  done
  shopt -u nullglob
  sleep 30
done
