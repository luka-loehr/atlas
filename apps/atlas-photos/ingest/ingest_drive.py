#!/usr/bin/env python3
"""Google-Takeout Drive -> atlas drive (the Storage app's "Dateien" tab).

Reads files DIRECTLY from the takeout zip(s) (no unpacking), hashes each with
SHA256 (the canonical content id, same function as the server upload path),
writes content-addressed blobs to ~/drive/blobs/<hash> and mirrors the
Takeout/Drive/ folder tree into Postgres (drive_folders, drive_files).
File mtimes come from the zip entries (Drive's modified time).

    python3 ingest_drive.py ~/takeout/drive/*.zip

Idempotent: re-running skips rows whose (folder, name) already carry the same
content hash; changed content updates the row in place. Duplicate names inside
one folder (Drive allows them, filesystems don't) get " (2)", " (3)", ...
"""
import hashlib
import mimetypes
import os
import sys
import unicodedata
import zipfile
from datetime import datetime, timezone

import psycopg

DRIVE = os.path.expanduser("~/drive")
BLOBS = os.path.join(DRIVE, "blobs")
PREFIX = "Takeout/Drive/"


def db():
    pw = ""
    with open(os.path.expanduser("~/atlas/backend/docker/.env")) as f:
        for line in f:
            if line.startswith("POSTGRES_PASSWORD="):
                pw = line.split("=", 1)[1].strip()
    return psycopg.connect(host="127.0.0.1", dbname="atlas", user="atlas", password=pw)


def write_blob(zf, info):
    """Stream the entry into the blob store, hashing on the way. Returns the
    hash; identical content that already exists is discarded, not rewritten."""
    h = hashlib.sha256()
    tmp = os.path.join(BLOBS, f".tmp-{os.getpid()}")
    with zf.open(info) as src, open(tmp, "wb") as out:
        while chunk := src.read(1 << 20):
            h.update(chunk)
            out.write(chunk)
    digest = h.hexdigest()
    dest = os.path.join(BLOBS, digest)
    if os.path.exists(dest):
        os.remove(tmp)
    else:
        os.replace(tmp, dest)
    return digest


def folder_id(cur, cache, parts):
    """Ensure the folder chain exists; returns the deepest folder's id
    (None for the drive root)."""
    parent = None
    for name in parts:
        key = (parent, name)
        if key not in cache:
            cur.execute(
                """INSERT INTO drive_folders (parent_id, name) VALUES (%s, %s)
                   ON CONFLICT (parent_id, name) DO UPDATE SET name = EXCLUDED.name
                   RETURNING id""",
                (parent, name),
            )
            cache[key] = cur.fetchone()[0]
        parent = cache[key]
    return parent


def main(zips):
    os.makedirs(BLOBS, exist_ok=True)
    conn = db()
    cur = conn.cursor()
    cache = {}          # (parent_id, name) -> folder id
    seen = set()        # (folder_id, name) handled in THIS run -> duplicate name
    added = updated = skipped = 0

    for zpath in zips:
        with zipfile.ZipFile(zpath) as zf:
            entries = [i for i in zf.infolist()
                       if i.filename.startswith(PREFIX) and not i.is_dir()]
            print(f"{os.path.basename(zpath)}: {len(entries)} files")
            for n, info in enumerate(entries, 1):
                rel = unicodedata.normalize("NFC", info.filename[len(PREFIX):])
                *dirs, name = rel.split("/")
                fid = folder_id(cur, cache, dirs)
                digest = write_blob(zf, info)
                size = info.file_size
                mime = mimetypes.guess_type(name)[0]
                mtime = datetime(*info.date_time, tzinfo=timezone.utc)

                # duplicate name within one folder in this run -> " (2)", ...
                base, dot, ext = name.rpartition(".")
                suffix = 2
                while (fid, name) in seen:
                    name = f"{base} ({suffix}).{ext}" if dot else f"{name} ({suffix})"
                    suffix += 1
                seen.add((fid, name))

                cur.execute(
                    """SELECT id, hash FROM drive_files
                       WHERE folder_id IS NOT DISTINCT FROM %s AND name = %s
                         AND trashed_at IS NULL""",
                    (fid, name),
                )
                row = cur.fetchone()
                if row is None:
                    cur.execute(
                        """INSERT INTO drive_files
                           (folder_id, name, hash, size_bytes, mime, modified_at, source)
                           VALUES (%s, %s, %s, %s, %s, %s, 'takeout')""",
                        (fid, name, digest, size, mime, mtime),
                    )
                    added += 1
                elif row[1] != digest:
                    cur.execute(
                        """UPDATE drive_files
                           SET hash=%s, size_bytes=%s, mime=%s, modified_at=%s
                           WHERE id=%s""",
                        (digest, size, mime, mtime, row[0]),
                    )
                    updated += 1
                else:
                    skipped += 1
                if n % 100 == 0:
                    conn.commit()
                    print(f"  {n}/{len(entries)}")
            conn.commit()

    cur.execute("SELECT count(*), coalesce(sum(size_bytes),0) FROM drive_files WHERE trashed_at IS NULL")
    total, size = cur.fetchone()
    print(f"done: +{added} added, {updated} updated, {skipped} unchanged "
          f"-> {total} files, {size / 1e9:.2f} GB")
    conn.close()


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit("usage: ingest_drive.py <takeout-drive.zip> [...]")
    main(sys.argv[1:])
