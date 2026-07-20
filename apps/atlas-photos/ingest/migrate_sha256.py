#!/usr/bin/env python3
"""One-time migration: re-key legacy BLAKE3[:32] asset ids to full SHA256.

Background: three code paths hashed photo bytes with different functions —
Takeout ingest used BLAKE3 truncated to 128 bit, the iOS app uses SHA256, and
the server trusted the client hash verbatim. The same photo present in both
Google Takeout and on the iPhone therefore got two different ids and was stored
twice (content-addressed dedup only works when everyone hashes identically).

The code is now SHA256 everywhere (ingest + server recompute). This script
converts the already-stored BLAKE3 rows so the whole library shares one id
scheme, merging the byte-identical duplicates that already exist.

For every asset whose id is not a 64-char hex SHA256 (the legacy BLAKE3 rows):
  new_id = sha256(the exact bytes on disk at orig_path)
Rows are then grouped by new_id:
  * if a SHA256 row already exists for that content (an iPhone upload), it is
    the SURVIVOR; the legacy row(s) are merged into it and deleted.
  * otherwise one legacy row is re-keyed to new_id and the rest merged in.
Merging = move album links (dedup), fill NULL metadata from the loser, move
thumbnails if the survivor has none, delete the redundant original + row.

DB work runs in ONE transaction (FK on album_assets dropped/re-added around it);
filesystem renames/deletes happen after COMMIT and are idempotent.

    python3 migrate_sha256.py            # DRY RUN — prints the plan, no changes
    python3 migrate_sha256.py --apply    # execute

Safe to re-run: already-SHA256 rows are ignored.
"""
import hashlib
import os
import sys

import psycopg

PHOTOS = os.path.expanduser("~/photos")
ORIG = os.path.join(PHOTOS, "originals")
THUMBS = os.path.join(PHOTOS, "thumbs")
APPLY = "--apply" in sys.argv


def db():
    pw = ""
    with open(os.path.expanduser("~/atlas/backend/docker/.env")) as f:
        for line in f:
            if line.startswith("POSTGRES_PASSWORD="):
                pw = line.split("=", 1)[1].strip()
    return psycopg.connect(host="127.0.0.1", dbname="atlas", user="atlas", password=pw)


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def thumbs_for(asset_id):
    return [os.path.join(THUMBS, f"{asset_id}.{s}.webp") for s in (256, 1024)]


def is_sha256(i):
    return len(i) == 64


def main():
    conn = db()
    cur = conn.cursor()

    # 1) Load every asset (id, file, richest metadata for merge decisions).
    cur.execute("SELECT id, orig_path, orig_name, taken_at, description, favorite, "
                "camera, lat, lon FROM assets")
    assets = {r[0]: r for r in cur.fetchall()}
    all_ids = set(assets)

    legacy = [i for i in all_ids if not is_sha256(i)]
    print(f"assets total={len(all_ids)} legacy(non-sha256)={len(legacy)} "
          f"sha256={len(all_ids) - len(legacy)}")

    # 2) Re-hash each legacy file -> new_id. Skip (leave untouched) if the file
    #    is missing so we never point the DB at a non-existent file.
    new_of = {}
    missing = []
    for i in legacy:
        path = assets[i][1]
        if not path or not os.path.exists(path):
            missing.append(i)
            continue
        new_of[i] = sha256_file(path)

    if missing:
        print(f"WARNING: {len(missing)} legacy assets have no file on disk — left as-is")

    # 3) Group legacy ids by their content id (new_id). The final surviving id
    #    for ANY legacy row is simply new_of[old]: either an existing iPhone
    #    SHA256 row already holds it, or one legacy row is re-keyed to it.
    groups = {}
    for old, new in new_of.items():
        groups.setdefault(new, []).append(old)

    rekeys = []   # (old_id, new_id): re-key this legacy row to new_id
    losers = []   #  old_id:          merge into new_of[old_id], then delete
    for new, olds in groups.items():
        if new in all_ids and is_sha256(new):
            losers.extend(olds)               # existing iPhone row survives
        else:
            rekeys.append((olds[0], new))     # promote first legacy row
            losers.extend(olds[1:])           # rest are dups of it

    dup_bytes = 0
    for lo in losers:
        try:
            dup_bytes += os.path.getsize(assets[lo][1])
        except OSError:
            pass

    print(f"plan: rekey={len(rekeys)} merge/delete_losers={len(losers)} "
          f"reclaim~={dup_bytes/1024/1024:.0f} MB")
    for lo in losers[:3]:
        print(f"  merge {lo} ({assets[lo][2]}) -> {new_of[lo]}")
    for old, new in rekeys[:3]:
        print(f"  rekey {old} ({assets[old][2]}) -> {new}")

    if not APPLY:
        print("\nDRY RUN — no changes made. Re-run with --apply to execute.")
        return

    # 4) DB transaction: repoint album links, re-key survivors, delete losers.
    #    Order matters: albums first (so no link references a legacy id), then
    #    re-key survivors (so every survivor row exists), then merge+delete
    #    losers (metadata merge needs the survivor row to be present).
    print("\nAPPLYING …")
    cur.execute("ALTER TABLE album_assets DROP CONSTRAINT album_assets_asset_id_fkey")

    # 4a) Every legacy id's album links move to its content id (dedup), old gone.
    for old, new in new_of.items():
        cur.execute(
            "INSERT INTO album_assets (album_id, asset_id) "
            "SELECT album_id, %s FROM album_assets WHERE asset_id = %s "
            "ON CONFLICT DO NOTHING", (new, old))
        cur.execute("DELETE FROM album_assets WHERE asset_id = %s", (old,))

    # 4b) Re-key survivors (legacy -> new). The server serves originals via the
    #     stored orig_path, so it MUST be updated to the renamed file too. Also
    #     move their ingest jobs (dedup any pre-existing new-id job first).
    for old, new in rekeys:
        old_path, name = assets[old][1], assets[old][2]
        new_path = os.path.join(os.path.dirname(old_path), f"{new}_{name}") if old_path else old_path
        cur.execute("DELETE FROM ingest_jobs WHERE owner_type='asset' AND owner_id=%s", (new,))
        cur.execute("UPDATE ingest_jobs SET owner_id=%s WHERE owner_type='asset' AND owner_id=%s",
                    (new, old))
        cur.execute("UPDATE assets SET id=%s, orig_path=%s WHERE id=%s", (new, new_path, old))

    # 4c) Losers: fill survivor NULL metadata from the loser, drop jobs, delete.
    for lo in losers:
        s = new_of[lo]
        cur.execute(
            "UPDATE assets a SET "
            " taken_at   = COALESCE(a.taken_at,   l.taken_at), "
            " description= COALESCE(a.description, l.description), "
            " favorite   = a.favorite OR l.favorite, "
            " camera     = COALESCE(a.camera, l.camera), "
            " lat        = COALESCE(a.lat, l.lat), "
            " lon        = COALESCE(a.lon, l.lon) "
            "FROM assets l WHERE a.id = %s AND l.id = %s", (s, lo))
        cur.execute("DELETE FROM ingest_jobs WHERE owner_type='asset' AND owner_id=%s", (lo,))
        cur.execute("DELETE FROM assets WHERE id = %s", (lo,))

    cur.execute("ALTER TABLE album_assets ADD CONSTRAINT album_assets_asset_id_fkey "
                "FOREIGN KEY (asset_id) REFERENCES assets(id) ON DELETE CASCADE")
    conn.commit()
    print("DB committed.")

    # 5) Filesystem (post-commit, idempotent).
    #    Re-key survivors: rename original + thumbs old->new.
    renamed = 0
    for old, new in rekeys:
        path, name = assets[old][1], assets[old][2]
        if path and os.path.exists(path):
            dest = os.path.join(os.path.dirname(path), f"{new}_{name}")
            if not os.path.exists(dest):
                os.rename(path, dest)
                renamed += 1
        for a, b in zip(thumbs_for(old), thumbs_for(new)):
            if os.path.exists(a) and not os.path.exists(b):
                os.rename(a, b)

    #    Losers: give the survivor the loser's thumbs if it has none, then delete
    #    the redundant original + any leftover loser thumbs.
    deleted_files = 0
    for lo in losers:
        s = new_of[lo]
        for a, b in zip(thumbs_for(lo), thumbs_for(s)):
            if os.path.exists(a) and not os.path.exists(b):
                os.rename(a, b)
        p = assets[lo][1]
        if p and os.path.exists(p):
            os.remove(p)
            deleted_files += 1
        for t in thumbs_for(lo):
            if os.path.exists(t):
                os.remove(t)

    print(f"files: renamed_originals={renamed} deleted_redundant={deleted_files}")

    # 6) Verify: no legacy ids remain, no orphan album links.
    cur.execute("SELECT count(*) FROM assets WHERE length(id) <> 64")
    left = cur.fetchone()[0]
    cur.execute("SELECT count(*) FROM album_assets aa "
                "LEFT JOIN assets a ON a.id = aa.asset_id WHERE a.id IS NULL")
    orphans = cur.fetchone()[0]
    cur.execute("SELECT count(*) FROM assets")
    total = cur.fetchone()[0]
    print(f"verify: assets={total} legacy_left={left} orphan_album_links={orphans}")
    conn.close()


if __name__ == "__main__":
    main()
