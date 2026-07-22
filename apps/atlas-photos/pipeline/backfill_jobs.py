#!/usr/bin/env python3
"""Backfill ingest_jobs for every existing asset.

Enqueues (ON CONFLICT DO NOTHING — safe to run repeatedly):
  - meta, embed, faces, caption   for every assets row
  - geocode                       where lat IS NOT NULL
  - thumb                         where the 512 WEBP is missing on disk
  - event_scan                    singleton ('system', 'singleton')

Prints per-kind inserted counts.  Run on atlas:  python3 backfill_jobs.py
"""
import os

import psycopg

# PHOTOS_DIR: photo library root (default ~/photos)
PHOTOS = os.environ.get("PHOTOS_DIR", os.path.expanduser("~/photos"))
THUMBS = os.path.join(PHOTOS, "thumbs")


def db():
    # POSTGRES_PASSWORD directly, or parsed from $PG_ENV_FILE (default:
    # /secrets/.env in-container, else the backend compose secrets file)
    pw = os.environ.get("POSTGRES_PASSWORD", "")
    if not pw:
        env_file = os.environ.get("PG_ENV_FILE") or (
            "/secrets/.env" if os.path.exists("/secrets/.env")
            else os.path.expanduser("~/atlas/backend/docker/.env"))
        with open(env_file) as f:
            for line in f:
                if line.startswith("POSTGRES_PASSWORD="):
                    pw = line.split("=", 1)[1].strip()
    return psycopg.connect(
        host=os.environ.get("PGHOST", "127.0.0.1"),
        port=int(os.environ.get("PGPORT", "5432")),
        dbname=os.environ.get("PGDATABASE", "atlas"),
        user=os.environ.get("PGUSER", "atlas"),
        password=pw, autocommit=True)


def main():
    conn = db()
    cur = conn.cursor()

    for kind in ("meta", "embed", "faces", "caption"):
        cur.execute(
            """INSERT INTO ingest_jobs (kind, owner_type, owner_id)
               SELECT %s, 'asset', id FROM assets
               ON CONFLICT DO NOTHING""", (kind,))
        print(f"{kind}: {cur.rowcount} enqueued", flush=True)

    cur.execute(
        """INSERT INTO ingest_jobs (kind, owner_type, owner_id)
           SELECT 'geocode', 'asset', id FROM assets WHERE lat IS NOT NULL
           ON CONFLICT DO NOTHING""")
    print(f"geocode: {cur.rowcount} enqueued", flush=True)

    # thumb only where the 512 file is missing on disk
    cur.execute("SELECT id FROM assets")
    missing = [r[0] for r in cur.fetchall()
               if not os.path.exists(os.path.join(THUMBS, f"{r[0]}.512.webp"))]
    cur.execute(
        """INSERT INTO ingest_jobs (kind, owner_type, owner_id)
           SELECT 'thumb', 'asset', unnest(%s::text[])
           ON CONFLICT DO NOTHING""", (missing,))
    print(f"thumb: {cur.rowcount} enqueued ({len(missing)} missing on disk)",
          flush=True)

    cur.execute(
        """INSERT INTO ingest_jobs (kind, owner_type, owner_id)
           VALUES ('event_scan', 'system', 'singleton')
           ON CONFLICT DO NOTHING""")
    print(f"event_scan: {cur.rowcount} enqueued", flush=True)

    conn.close()


if __name__ == "__main__":
    main()
