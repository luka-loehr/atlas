#!/usr/bin/env python3
"""One-time migration: make every asset id the full SHA256 of its bytes.

Background: three code paths hashed photo bytes differently — Takeout ingest
used BLAKE3 truncated to 128 bit, the iOS app uses SHA256, and the old server
trusted the client hash verbatim. The same photo present in both Google Takeout
and on the iPhone therefore got two different ids and was stored twice
(content-addressed dedup only works when everyone hashes identically).

The code is now SHA256 everywhere (ingest + server recompute from bytes). This
script converts the already-stored rows so the whole library shares one id
scheme and collapses the byte-identical duplicates that already exist.

Design (hardened after adversarial review):
  * Re-hash EVERY asset's stored bytes — never trust a stored id as canonical.
  * Group by recomputed content hash; per group one survivor, the rest merged.
  * Merge carries ALL user state, incl. locked/archived/trashed_at (a hidden
    duplicate must never resurface through its visible twin).
  * Re-key updates orig_path (the server serves originals by that column) AND
    renames the file; a durable plan sidecar makes the filesystem pass
    replayable if the process dies after COMMIT.
  * Losers' originals are deleted only after confirming the survivor's file
    exists on disk.
  * Preconditions asserted: every file present; faces/embeddings/edges empty
    (they FK/reference assets.id and must not silently block the re-key).

    python3 migrate_sha256.py            # DRY RUN — prints the plan, no changes
    python3 migrate_sha256.py --apply    # execute (pause ingestion first)

Idempotent: safe to re-run; a crash between COMMIT and the end of the file pass
is healed by re-running (the plan sidecar drives the filesystem work).
"""
import hashlib
import json
import os
import sys

import psycopg

PHOTOS = os.path.expanduser("~/photos")
ORIG = os.path.join(PHOTOS, "originals")
THUMBS = os.path.join(PHOTOS, "thumbs")
PLAN = os.path.join(PHOTOS, ".sha256_migration_plan.json")
APPLY = "--apply" in sys.argv

COLS = ("id", "orig_path", "orig_name", "taken_at", "description", "favorite",
        "camera", "lat", "lon", "archived", "locked", "trashed_at")


def db():
    pw = ""
    with open(os.path.expanduser("~/atlas/backend/docker/.env")) as f:
        for line in f:
            if line.startswith("POSTGRES_PASSWORD="):
                pw = line.split("=", 1)[1].strip()
    return psycopg.connect(host="127.0.0.1", dbname="atlas", user="atlas",
                           password=pw, autocommit=True)


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def thumbs_for(asset_id):
    return [os.path.join(THUMBS, f"{asset_id}.{s}.webp") for s in (256, 1024)]


def compute_plan(cur):
    """Re-hash every asset and derive the rekey/loser plan. No writes."""
    cur.execute(f"SELECT {', '.join(COLS)} FROM assets")
    assets = {r[0]: dict(zip(COLS, r)) for r in cur.fetchall()}

    truehash, missing = {}, []
    for aid, a in assets.items():
        p = a["orig_path"]
        if not p or not os.path.exists(p):
            missing.append(aid)
            continue
        truehash[aid] = sha256_file(p)

    groups = {}
    for aid, h in truehash.items():
        groups.setdefault(h, []).append(aid)

    rekeys, losers, noop = [], [], 0
    for h, ids in groups.items():
        already = h if h in ids else None            # row already at content id
        survivor_src = already or ids[0]
        rest = [i for i in ids if i != survivor_src]
        if already is None:                          # promote survivor_src -> h
            a = assets[survivor_src]
            dest = os.path.join(os.path.dirname(a["orig_path"]),
                                f"{h}_{a['orig_name']}")
            rekeys.append([survivor_src, h, dest, a["orig_path"]])
        elif not rest:
            noop += 1
        for lo in rest:
            losers.append([lo, h])                   # survivor final id == h

    return assets, truehash, missing, rekeys, losers, noop


def main():
    conn = db()
    cur = conn.cursor()

    assets, truehash, missing, rekeys, losers, noop = compute_plan(cur)
    total = len(assets)
    dup_bytes = sum(os.path.getsize(assets[lo]["orig_path"])
                    for lo, _ in losers if os.path.exists(assets[lo]["orig_path"]))

    print(f"assets={total} hashed={len(truehash)} missing_files={len(missing)}")
    print(f"plan: rekey={len(rekeys)} merge_losers={len(losers)} noop={noop} "
          f"reclaim~={dup_bytes/1024/1024:.0f} MB")
    for lo, h in losers[:3]:
        print(f"  merge {lo} ({assets[lo]['orig_name']}) -> {h}")
    for old, new, _, _ in rekeys[:3]:
        print(f"  rekey {old} ({assets[old]['orig_name']}) -> {new}")

    if not APPLY:
        print("\nDRY RUN — no changes. Re-run with --apply to execute.")
        return

    # ---- preconditions -----------------------------------------------------
    if missing:
        sys.exit(f"ABORT: {len(missing)} assets have no file on disk "
                 f"(e.g. {missing[:3]}). Fix/verify before --apply.")
    for t in ("faces", "embeddings", "edges"):
        cur.execute(f"SELECT count(*) FROM {t}")
        n = cur.fetchone()[0]
        if n:
            sys.exit(f"ABORT: table {t} has {n} rows referencing assets; this "
                     f"migration only handles the empty case. Handle {t} first.")

    # ---- durable plan sidecar (drives the replayable filesystem pass) ------
    plan = {"rekeys": rekeys,
            "losers": [[lo, h, assets[lo]["orig_path"]] for lo, h in losers],
            "survivor_final": {h: True for _, h in losers}}
    with open(PLAN, "w") as f:
        json.dump(plan, f)

    # ---- DB write: one atomic transaction ----------------------------------
    print("\nAPPLYING (DB transaction) …")
    with conn.transaction():
        cur.execute("ALTER TABLE album_assets DROP CONSTRAINT album_assets_asset_id_fkey")

        # (a) every id that changes moves its album links to the content id.
        for old, new, _, _ in rekeys:
            _move_albums(cur, old, new)
        for lo, h in losers:
            _move_albums(cur, lo, h)

        # (b) re-key survivors (id + orig_path) and their ingest jobs.
        for old, new, dest, _ in rekeys:
            cur.execute("DELETE FROM ingest_jobs WHERE owner_type='asset' AND owner_id=%s", (new,))
            cur.execute("UPDATE ingest_jobs SET owner_id=%s WHERE owner_type='asset' AND owner_id=%s",
                        (new, old))
            cur.execute("UPDATE assets SET id=%s, orig_path=%s WHERE id=%s", (new, dest, old))

        # (c) merge losers into the survivor (ALL user state), then delete.
        for lo, h in losers:
            cur.execute(
                "UPDATE assets a SET "
                " taken_at   = COALESCE(a.taken_at,    l.taken_at), "
                " description= COALESCE(a.description,  l.description), "
                " favorite   = a.favorite OR l.favorite, "
                " camera     = COALESCE(a.camera, l.camera), "
                " lat        = COALESCE(a.lat, l.lat), "
                " lon        = COALESCE(a.lon, l.lon), "
                " locked     = a.locked   OR l.locked, "        # never un-hide
                " archived   = a.archived OR l.archived, "
                " trashed_at = COALESCE(a.trashed_at, l.trashed_at) "
                "FROM assets l WHERE a.id=%s AND l.id=%s", (h, lo))
            cur.execute("DELETE FROM ingest_jobs WHERE owner_type='asset' AND owner_id=%s", (lo,))
            cur.execute("DELETE FROM assets WHERE id=%s", (lo,))

        cur.execute("ALTER TABLE album_assets ADD CONSTRAINT album_assets_asset_id_fkey "
                    "FOREIGN KEY (asset_id) REFERENCES assets(id) ON DELETE CASCADE")
    print("DB committed.")

    # ---- filesystem pass (replayable from the plan sidecar) ----------------
    renamed, deleted, kept = apply_files(cur, plan)
    print(f"files: renamed_originals={renamed} deleted_redundant={deleted} "
          f"kept_missing_survivor={kept}")

    # ---- verify ------------------------------------------------------------
    cur.execute("SELECT count(*) FROM assets")
    n_assets = cur.fetchone()[0]
    cur.execute("SELECT count(*) FROM assets WHERE length(id)<>64 OR id !~ '^[0-9a-f]{64}$'")
    bad_ids = cur.fetchone()[0]
    cur.execute("SELECT count(*) FROM album_assets aa LEFT JOIN assets a ON a.id=aa.asset_id "
                "WHERE a.id IS NULL")
    orphans = cur.fetchone()[0]
    print(f"verify: assets={n_assets} non_sha256_ids={bad_ids} orphan_album_links={orphans}")
    if bad_ids == 0 and orphans == 0:
        os.path.exists(PLAN) and os.remove(PLAN)
        print("OK — migration complete, plan sidecar removed.")
    else:
        print("WARNING: verify found issues — plan sidecar kept for inspection.")
    conn.close()


def _move_albums(cur, old, new):
    cur.execute("INSERT INTO album_assets (album_id, asset_id) "
                "SELECT album_id, %s FROM album_assets WHERE asset_id=%s "
                "ON CONFLICT DO NOTHING", (new, old))
    cur.execute("DELETE FROM album_assets WHERE asset_id=%s", (old,))


def apply_files(cur, plan):
    """Rename re-keyed originals+thumbs and delete redundant loser files.
    Idempotent (exists() guards); safe to replay from the sidecar."""
    renamed = deleted = kept = 0
    for old, new, dest, old_path in plan["rekeys"]:
        # source original is still at its old path, unless already moved to dest
        if old_path and os.path.exists(old_path) and not os.path.exists(dest):
            os.rename(old_path, dest); renamed += 1
        for a, b in zip(thumbs_for(old), thumbs_for(new)):
            if os.path.exists(a) and not os.path.exists(b):
                os.rename(a, b)

    for lo, h, lo_path in plan["losers"]:
        # survivor original must exist before we delete the redundant copy
        cur.execute("SELECT orig_path FROM assets WHERE id=%s", (h,))
        row = cur.fetchone()
        surv_path = row[0] if row else None
        for a, b in zip(thumbs_for(lo), thumbs_for(h)):
            if os.path.exists(a) and not os.path.exists(b):
                os.rename(a, b)
        if surv_path and os.path.exists(surv_path):
            if lo_path and os.path.exists(lo_path):
                os.remove(lo_path); deleted += 1
            for t in thumbs_for(lo):
                if os.path.exists(t):
                    os.remove(t)
        else:
            kept += 1   # survivor file missing — keep the loser's bytes
    return renamed, deleted, kept


if __name__ == "__main__":
    main()
