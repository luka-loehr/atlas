#!/usr/bin/env python3
"""Google-Takeout -> atlas photos library.

Reads media DIRECTLY from the takeout zips (no unpacking), merges the JSON
sidecars (which may live in a DIFFERENT zip — classic takeout), dedupes by
BLAKE3 content hash, writes originals + 256/1024 WebP thumbs and fills
Postgres (assets, albums, ingest_jobs).

    python3 ingest_takeout.py ~/takeout/photos/*.zip

Idempotent: re-running skips already-ingested hashes; album links are merged.
"""
import io
import json
import os
import re
import subprocess
import sys
import tempfile
import zipfile
from concurrent.futures import ProcessPoolExecutor
from datetime import datetime, timezone

import blake3
import psycopg
from PIL import Image, ImageOps
import pillow_heif

pillow_heif.register_heif_opener()
Image.MAX_IMAGE_PIXELS = None

PHOTOS = os.path.expanduser("~/photos")
ORIG = os.path.join(PHOTOS, "originals")
THUMBS = os.path.join(PHOTOS, "thumbs")

MEDIA_EXT = {".jpg", ".jpeg", ".png", ".heic", ".webp", ".gif", ".bmp", ".tif", ".tiff",
             ".mp4", ".mov", ".m4v", ".3gp", ".avi", ".mkv", ".webm", ".mts"}
VIDEO_EXT = {".mp4", ".mov", ".m4v", ".3gp", ".avi", ".mkv", ".webm", ".mts"}


def db():
    pw = ""
    with open(os.path.expanduser("~/atlas/backend/docker/.env")) as f:
        for line in f:
            if line.startswith("POSTGRES_PASSWORD="):
                pw = line.split("=", 1)[1].strip()
    return psycopg.connect(host="127.0.0.1", dbname="atlas", user="atlas", password=pw)


# ------------------------------------------------------------ sidecar map ---

def is_media(name):
    return os.path.splitext(name)[1].lower() in MEDIA_EXT


def sidecar_keys(media_basename):
    """All sidecar basenames google might have used for this media file.
    Rules: '<name>.json', '<name>.supplemental-metadata.json' (and truncated
    variants — takeout caps sidecar basenames at 51 chars), and the infamous
    duplicate swap: 'IMG(1).jpg' -> 'IMG.jpg(1).json'."""
    keys = set()
    base = media_basename
    m = re.match(r"^(.*)(\(\d+\))(\.[^.]+)$", base)         # name(1).ext
    swapped = f"{m.group(1)}{m.group(3)}{m.group(2)}" if m else None
    for b in filter(None, [base, swapped]):
        for suffix in (".json", ".supplemental-metadata.json", ".supplemental-metad.json",
                       ".suppl.json", ".sup.json"):
            keys.add(b + suffix)
        # truncation: total basename (incl '.json') capped at 51 chars
        for full in (b + ".supplemental-metadata.json", b + ".json"):
            if len(full) > 51:
                keys.add(full[:51 - 5] + ".json")
    return keys


def build_sidecar_index(zips):
    """basename -> (zip_path, entry_name) over ALL zips."""
    idx = {}
    for zp in zips:
        with zipfile.ZipFile(zp) as z:
            for n in z.namelist():
                if n.endswith(".json"):
                    idx[os.path.basename(n)] = (zp, n)
    return idx


def parse_sidecar(raw):
    try:
        d = json.loads(raw)
    except ValueError:
        return {}
    out = {}
    ts = (d.get("photoTakenTime") or {}).get("timestamp")
    if ts:
        out["taken_at"] = datetime.fromtimestamp(int(ts), tz=timezone.utc)
    geo = d.get("geoData") or {}
    if geo.get("latitude") or geo.get("longitude"):
        out["lat"], out["lon"] = geo.get("latitude"), geo.get("longitude")
    if d.get("description"):
        out["description"] = d["description"][:2000]
    if isinstance(d.get("favorited"), dict) or d.get("favorited") is True:
        out["favorite"] = True
    dev = ((d.get("cameraDetails") or {}).get("cameraModel")
           or (d.get("googlePhotosOrigin") or {}).get("mobileUpload", {}).get("deviceType"))
    if dev:
        out["camera"] = str(dev)[:120]
    return out


# ------------------------------------------------------------- thumbnails ---

def make_photo_thumbs(data, hash_id):
    img = Image.open(io.BytesIO(data))
    img = ImageOps.exif_transpose(img)
    w, h = img.size
    if img.mode not in ("RGB", "L"):
        img = img.convert("RGB")
    for size in (256, 1024):
        t = img.copy()
        t.thumbnail((size, size))
        t.save(os.path.join(THUMBS, f"{hash_id}.{size}.webp"), "WEBP", quality=82)
    return w, h


def make_video_thumbs(tmp_path, hash_id):
    """Poster frame at 1s via ffmpeg + probe for dimensions/duration."""
    probe = subprocess.run(
        ["ffprobe", "-v", "quiet", "-print_format", "json", "-show_streams",
         "-show_format", tmp_path], capture_output=True, text=True)
    w = h = None
    dur = None
    try:
        info = json.loads(probe.stdout)
        dur = float(info.get("format", {}).get("duration", 0)) or None
        for s in info.get("streams", []):
            if s.get("codec_type") == "video":
                w, h = s.get("width"), s.get("height")
                rot = str((s.get("side_data_list") or [{}])[0].get("rotation", 0))
                if rot in ("90", "-90", "270"):
                    w, h = h, w
                break
    except Exception:
        pass
    with tempfile.NamedTemporaryFile(suffix=".jpg", delete=False) as f:
        frame = f.name
    r = subprocess.run(
        ["ffmpeg", "-v", "quiet", "-ss", "1", "-i", tmp_path,
         "-frames:v", "1", "-y", frame], capture_output=True)
    if r.returncode == 0 and os.path.getsize(frame) > 0:
        with open(frame, "rb") as f:
            make_photo_thumbs(f.read(), hash_id)
    os.unlink(frame)
    return w, h, dur


# ---------------------------------------------------------------- workers ---

def process_entry(args):
    """Worker: hash + write original + thumbs. Returns row dict or None."""
    zp, entry, meta = args
    try:
        with zipfile.ZipFile(zp) as z:
            data = z.read(entry)
    except Exception as e:
        return {"error": f"{entry}: read failed {e}"}
    hash_id = blake3.blake3(data).hexdigest()[:32]
    name = os.path.basename(entry)
    ext = os.path.splitext(name)[1].lower()
    is_video = ext in VIDEO_EXT

    taken = meta.get("taken_at")
    sub = taken.strftime("%Y/%m") if taken else "0000/00"
    dest_dir = os.path.join(ORIG, sub)
    os.makedirs(dest_dir, exist_ok=True)
    dest = os.path.join(dest_dir, f"{hash_id}_{name}")

    already = os.path.exists(dest)
    if not already:
        with open(dest, "wb") as f:
            f.write(data)

    w = h = dur = None
    thumb256 = os.path.join(THUMBS, f"{hash_id}.256.webp")
    if not os.path.exists(thumb256):
        try:
            if is_video:
                w, h, dur = make_video_thumbs(dest, hash_id)
            else:
                w, h = make_photo_thumbs(data, hash_id)
        except Exception as e:
            return {"error": f"{name}: thumb failed {type(e).__name__} {e}",
                    "row": _row(hash_id, is_video, meta, dest, name, len(data), None, None, None)}
    return {"row": _row(hash_id, is_video, meta, dest, name, len(data), w, h, dur)}


def _row(hash_id, is_video, meta, dest, name, size, w, h, dur):
    return dict(
        id=hash_id, type="video" if is_video else "photo",
        taken_at=meta.get("taken_at"), lat=meta.get("lat"), lon=meta.get("lon"),
        camera=meta.get("camera"), description=meta.get("description"),
        favorite=meta.get("favorite", False),
        orig_path=dest, orig_name=name, size_bytes=size,
        width=w, height=h, duration_s=dur, album=meta.get("album"),
    )


# ------------------------------------------------------------------- main ----

def main(zips):
    os.makedirs(ORIG, exist_ok=True)
    os.makedirs(THUMBS, exist_ok=True)
    conn = db()
    cur = conn.cursor()
    cur.execute("SELECT id FROM assets")
    known = {r[0] for r in cur.fetchall()}
    print(f"db kennt {len(known)} assets", flush=True)

    print("pass 1: sidecar-index über alle zips ...", flush=True)
    sidecars = build_sidecar_index(zips)
    print(f"  {len(sidecars)} json-sidecars indiziert", flush=True)

    todo = []
    for zp in zips:
        with zipfile.ZipFile(zp) as z:
            for n in z.namelist():
                if not is_media(n):
                    continue
                if "/Google Fotos/" not in n and "/Google Photos/" not in n:
                    continue
                base = os.path.basename(n)
                folder = os.path.basename(os.path.dirname(n))
                album = None if re.match(r"^Photos from \d{4}$", folder) else folder
                meta = {"album": album}
                for k in sidecar_keys(base):
                    if k in sidecars:
                        szp, sentry = sidecars[k]
                        with zipfile.ZipFile(szp) as sz:
                            meta.update(parse_sidecar(sz.read(sentry)))
                        break
                todo.append((zp, n, meta))
    print(f"pass 2: {len(todo)} medien-dateien zu verarbeiten", flush=True)

    albums = {}
    done = 0
    errors = 0
    with ProcessPoolExecutor(max_workers=14) as ex:
        for res in ex.map(process_entry, todo, chunksize=8):
            done += 1
            if res is None:
                continue
            if "error" in res:
                errors += 1
                if errors < 20:
                    print("  WARN:", res["error"], flush=True)
            row = res.get("row")
            if row:
                _insert(cur, row, albums, known)
            if done % 500 == 0:
                conn.commit()
                print(f"  {done}/{len(todo)} (neue assets: {len(known)}, fehler: {errors})",
                      flush=True)
    conn.commit()
    cur.execute("SELECT count(*) FROM assets")
    total = cur.fetchone()[0]
    print(f"FERTIG: {total} assets in der bibliothek ({errors} fehler)", flush=True)
    conn.close()


def _insert(cur, row, albums, known):
    if row["id"] not in known:
        cur.execute(
            """INSERT INTO assets (id, type, taken_at, lat, lon, camera, description,
                                   favorite, orig_path, orig_name, size_bytes,
                                   width, height, duration_s, source)
               VALUES (%(id)s, %(type)s, %(taken_at)s, %(lat)s, %(lon)s, %(camera)s,
                       %(description)s, %(favorite)s, %(orig_path)s, %(orig_name)s,
                       %(size_bytes)s, %(width)s, %(height)s, %(duration_s)s, 'takeout')
               ON CONFLICT (id) DO NOTHING""", row)
        for kind in ("embed", "faces"):
            cur.execute(
                """INSERT INTO ingest_jobs (kind, owner_type, owner_id)
                   VALUES (%s, 'asset', %s) ON CONFLICT DO NOTHING""",
                (kind, row["id"]))
        known.add(row["id"])
    if row.get("album"):
        title = row["album"]
        if title not in albums:
            cur.execute("INSERT INTO albums (title) VALUES (%s) ON CONFLICT (title) "
                        "DO UPDATE SET title=EXCLUDED.title RETURNING id", (title,))
            albums[title] = cur.fetchone()[0]
        cur.execute("INSERT INTO album_assets (album_id, asset_id) VALUES (%s, %s) "
                    "ON CONFLICT DO NOTHING", (albums[title], row["id"]))


if __name__ == "__main__":
    main(sys.argv[1:])
