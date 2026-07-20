#!/usr/bin/env python3
"""Backfill missing thumbnails.

The upload path enqueues a 'thumb' ingest_job but nothing processed the queue,
so iPhone-uploaded (and a few failed-ingest) assets have no 256/1024 WebP on
disk and render blank in the grid. This generates the missing thumbs from each
asset's original, fills width/height/duration where absent, and clears the
processed thumb jobs.

    python3 make_thumbs.py            # generate for every asset missing a thumb
    python3 make_thumbs.py --all      # regenerate for ALL assets (force)

Reuses the ingest thumbnailers so output is byte-for-byte the same pipeline.
"""
import os
import sys
from concurrent.futures import ProcessPoolExecutor

from ingest_takeout import db, THUMBS, VIDEO_EXT, make_photo_thumbs, make_video_thumbs

FORCE = "--all" in sys.argv


def has_thumb(aid):
    return os.path.exists(os.path.join(THUMBS, f"{aid}.256.webp"))


def work(row):
    """Runs in a worker process: writes thumb files, returns dims. No DB here."""
    aid, path, typ = row
    if not path or not os.path.exists(path):
        return aid, "missing-file", None
    try:
        if typ == "video" or os.path.splitext(path)[1].lower() in VIDEO_EXT:
            w, h, dur = make_video_thumbs(path, aid)
            return aid, "ok", (w, h, dur)
        with open(path, "rb") as f:
            w, h = make_photo_thumbs(f.read(), aid)
        return aid, "ok", (w, h, None)
    except Exception as e:
        return aid, f"err:{type(e).__name__}:{e}", None


def main():
    conn = db()
    cur = conn.cursor()
    cur.execute("SELECT id, orig_path, type FROM assets")
    rows = [r for r in cur.fetchall() if FORCE or not has_thumb(r[0])]
    print(f"assets needing thumbnails: {len(rows)}")
    if not rows:
        return

    ok = err = 0
    with ProcessPoolExecutor(max_workers=6) as ex:
        for aid, status, dims in ex.map(work, rows):
            if status == "ok":
                ok += 1
                if dims and any(d is not None for d in dims):
                    w, h, dur = dims
                    cur.execute(
                        "UPDATE assets SET width=COALESCE(width,%s), "
                        "height=COALESCE(height,%s), duration_s=COALESCE(duration_s,%s) "
                        "WHERE id=%s", (w, h, dur, aid))
                cur.execute("DELETE FROM ingest_jobs WHERE kind='thumb' AND "
                            "owner_type='asset' AND owner_id=%s", (aid,))
            else:
                err += 1
                print(f"  {aid}: {status}")
            if (ok + err) % 200 == 0:
                conn.commit()
                print(f"  … {ok + err}/{len(rows)}")

    conn.commit()
    missing_now = sum(1 for r in rows if not has_thumb(r[0]))
    print(f"done: generated={ok} errors={err} still_missing={missing_now}")
    conn.close()


if __name__ == "__main__":
    main()
