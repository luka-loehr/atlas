#!/usr/bin/env python3
"""CPU job handlers: thumb, meta, geocode, event_scan.

Every handler is idempotent (pure upserts / delete-then-insert per asset /
wipe-and-rebuild) so a crashed job re-run after reap() never duplicates
anything. Each handler runs on an autocommit connection and opens explicit
transactions only where multi-statement atomicity matters.
"""
import json
import math
import os
import re
import subprocess
import tempfile
import threading
from datetime import datetime, timedelta, timezone

from PIL import Image, ImageOps
import pillow_heif

import db  # noqa: F401  (thread-local conns are passed in by the worker)
import jobqueue as jobq

pillow_heif.register_heif_opener()
# Decompression-bomb guard: thumb jobs process untrusted upload bytes. High
# explicit ceiling instead of Pillow's default (a few KB of crafted PNG would
# otherwise expand to tens of GB of pixels and OOM-loop the worker).
# ATLAS_MAX_IMAGE_PIXELS: max decoded pixels per image (default 500 MP).
Image.MAX_IMAGE_PIXELS = int(os.environ.get("ATLAS_MAX_IMAGE_PIXELS", 500_000_000))

PHOTOS_DIR = os.environ.get("PHOTOS_DIR", os.path.expanduser("~/photos"))
THUMBS = os.path.join(PHOTOS_DIR, "thumbs")

SUBPROCESS_TIMEOUT = 120


def resolve_path(orig_path):
    """assets.orig_path is a host path (e.g. /home/atlas/photos/...); inside
    the containers the library is mounted at $PHOTOS_DIR (/photos). Remap."""
    if os.path.exists(orig_path):
        return orig_path
    marker = "/photos/"
    i = orig_path.find(marker)
    if i >= 0:
        cand = os.path.join(PHOTOS_DIR, orig_path[i + len(marker):])
        if os.path.exists(cand):
            return cand
    raise FileNotFoundError(orig_path)


# ------------------------------------------------------------------ thumb ---
# Ported from ingest/ingest_takeout.py make_photo_thumbs/make_video_thumbs.
# Idempotency: thumbnails are content-addressed (<sha256>.<size>.webp) and
# written atomically (tmp file + os.replace), overwriting is always safe;
# the width/height/duration backfill is fill-NULL only.

def _save_thumbs(img, hash_id):
    img = ImageOps.exif_transpose(img)
    w, h = img.size
    if img.mode not in ("RGB", "L"):
        img = img.convert("RGB")
    os.makedirs(THUMBS, exist_ok=True)
    # keep the source ICC profile (iPhone = Display P3) — dropping it makes
    # iOS read P3 values as sRGB and thumbnails turn pale/desaturated
    icc = img.info.get("icc_profile")
    kw = {"icc_profile": icc} if icc else {}
    for size in (512, 2048):
        t = img.copy()
        t.thumbnail((size, size), Image.LANCZOS)
        fd, tmp = tempfile.mkstemp(dir=THUMBS, suffix=".webp")
        os.close(fd)
        try:
            t.save(tmp, "WEBP", quality=88, method=6, **kw)
            os.replace(tmp, os.path.join(THUMBS, f"{hash_id}.{size}.webp"))
        finally:
            if os.path.exists(tmp):
                os.unlink(tmp)
    return w, h


def _photo_thumbs(path, hash_id):
    with Image.open(path) as img:
        img.load()
        return _save_thumbs(img, hash_id)


def _probe_video(path):
    probe = subprocess.run(
        ["ffprobe", "-v", "quiet", "-print_format", "json", "-show_streams",
         "-show_format", path],
        capture_output=True, text=True, timeout=SUBPROCESS_TIMEOUT)
    w = h = dur = None
    try:
        info = json.loads(probe.stdout)
        dur = float(info.get("format", {}).get("duration", 0)) or None
        for s in info.get("streams", []):
            if s.get("codec_type") == "video":
                w, h = s.get("width"), s.get("height")
                rot = 0
                for sd in (s.get("side_data_list") or []):
                    if "rotation" in sd:
                        rot = int(float(sd["rotation"]))
                        break
                if abs(rot) % 180 == 90:
                    w, h = h, w
                break
    except Exception:
        pass
    return w, h, dur


def _video_thumbs(path, hash_id):
    """Poster frame at 1s; short clips (<1s) seek past the end and yield
    nothing, so fall back to the very first frame (-ss 0)."""
    w, h, dur = _probe_video(path)
    with tempfile.NamedTemporaryFile(suffix=".jpg", delete=False) as f:
        frame = f.name
    try:
        for seek in ("1", "0"):
            subprocess.run(
                ["ffmpeg", "-v", "quiet", "-ss", seek, "-i", path,
                 "-frames:v", "1", "-y", frame],
                capture_output=True, timeout=SUBPROCESS_TIMEOUT)
            if os.path.exists(frame) and os.path.getsize(frame) > 0:
                with Image.open(frame) as img:
                    img.load()
                    _save_thumbs(img, hash_id)
                break
        else:
            raise RuntimeError("ffmpeg produced no poster frame")
    finally:
        if os.path.exists(frame):
            os.unlink(frame)
    return w, h, dur


def thumb(conn, asset_id):
    row = conn.execute(
        "SELECT orig_path, type, width, height FROM assets WHERE id = %s",
        (asset_id,)).fetchone()
    if row is None:
        raise RuntimeError(f"asset {asset_id} not in db")
    # early exit: both thumbs on disk and dimensions known -> nothing to do.
    # (meta enqueues thumb as a blanket safety net; without this check every
    # such job would re-read the original and re-encode two webps.)
    if (row[2] is not None and row[3] is not None
            and all(os.path.exists(os.path.join(THUMBS, f"{asset_id}.{s}.webp"))
                    for s in (512, 2048))):
        return
    path = resolve_path(row[0])
    if row[1] == "video":
        w, h, dur = _video_thumbs(path, asset_id)
    else:
        w, h = _photo_thumbs(path, asset_id)
        dur = None
    conn.execute(
        """UPDATE assets
              SET width = COALESCE(width, %s),
                  height = COALESCE(height, %s),
                  duration_s = COALESCE(duration_s, %s)
            WHERE id = %s""",
        (w, h, dur, asset_id))


# ------------------------------------------------------------------- meta ---
# exiftool -j -n; fill-NULL semantics (COALESCE) => re-runs change nothing,
# follow-up enqueues are ON CONFLICT DO NOTHING => free on re-run.

_DT_RE = re.compile(
    r"^(\d{4}):(\d{2}):(\d{2})[ T](\d{2}):(\d{2}):(\d{2})(?:\.\d+)?\s*"
    r"(Z|[+-]\d{2}:?\d{2})?")


def _parse_offset(s):
    if not s or not isinstance(s, str):
        return None
    s = s.strip()
    if s == "Z":
        return 0
    m = re.match(r"^([+-])(\d{2}):?(\d{2})$", s)
    if not m:
        return None
    sign = -1 if m.group(1) == "-" else 1
    return sign * (int(m.group(2)) * 3600 + int(m.group(3)) * 60)


def _parse_taken(d):
    """(taken_at_utc | None, tz_offset_s | None). Prefer DateTimeOriginal /
    CreateDate; use OffsetTimeOriginal/OffsetTime when the timestamp itself
    carries no zone; no zone info at all => treat as UTC."""
    off = None
    for k in ("OffsetTimeOriginal", "OffsetTimeDigitized", "OffsetTime"):
        off = _parse_offset(d.get(k))
        if off is not None:
            break
    for key in ("DateTimeOriginal", "CreateDate", "DateTimeCreated",
                "MediaCreateDate"):
        s = d.get(key)
        if not isinstance(s, str):
            continue
        m = _DT_RE.match(s.strip())
        if not m:
            continue
        try:
            naive = datetime(int(m.group(1)), int(m.group(2)), int(m.group(3)),
                             int(m.group(4)), int(m.group(5)), int(m.group(6)))
        except ValueError:
            continue
        if naive.year < 1980:  # camera default dates
            continue
        inline = _parse_offset(m.group(7))
        use = inline if inline is not None else off
        tz = timezone(timedelta(seconds=use)) if use is not None else timezone.utc
        return naive.replace(tzinfo=tz).astimezone(timezone.utc), use
    return None, off


def _exif_dict(path):
    out = subprocess.run(
        ["exiftool", "-j", "-n", path],
        capture_output=True, text=True, timeout=SUBPROCESS_TIMEOUT)
    try:
        data = json.loads(out.stdout)
        if isinstance(data, list) and data and isinstance(data[0], dict):
            return data[0]
    except ValueError:
        pass
    return {}  # unreadable metadata is not an error — fill-NULL just no-ops


def _num(v):
    try:
        f = float(v)
        return f if math.isfinite(f) else None
    except (TypeError, ValueError):
        return None


def meta(conn, asset_id):
    row = conn.execute(
        "SELECT orig_path FROM assets WHERE id = %s", (asset_id,)).fetchone()
    if row is None:
        raise RuntimeError(f"asset {asset_id} not in db")
    d = _exif_dict(resolve_path(row[0]))

    w = d.get("ImageWidth")
    h = d.get("ImageHeight")
    orient = d.get("Orientation")
    rot = _num(d.get("Rotation"))
    if w and h and (orient in (5, 6, 7, 8) or (rot is not None and abs(int(rot)) % 180 == 90)):
        w, h = h, w
    dur = _num(d.get("Duration")) or _num(d.get("MediaDuration")) or _num(d.get("TrackDuration"))
    camera = d.get("Model") or d.get("CameraModelName") or d.get("Make")
    camera = str(camera)[:120] if camera else None
    lat, lon = _num(d.get("GPSLatitude")), _num(d.get("GPSLongitude"))
    if lat == 0 and lon == 0:  # (0,0) is junk, not the Gulf of Guinea
        lat = lon = None
    taken_at, tz_offset_s = _parse_taken(d)

    # capture-parameter subset for the app's info sheet (004: assets.exif)
    exp = d.get("ExposureTime")
    if isinstance(exp, (int, float)) and exp > 0:
        exp = f"1/{round(1 / exp)}" if exp < 1 else f"{exp:g}"
    exif_bits = {k: v for k, v in {
        "iso": int(_num(d.get("ISO")) or 0) or None,
        "f_number": _num(d.get("FNumber")),
        "exposure_time": exp if isinstance(exp, str) else None,
        "focal_len": _num(d.get("FocalLength")),
        "lens": (str(d.get("LensModel") or d.get("LensID") or "")[:120] or None),
    }.items() if v is not None}

    conn.execute(
        """UPDATE assets
              SET width = COALESCE(width, %s),
                  height = COALESCE(height, %s),
                  duration_s = COALESCE(duration_s, %s),
                  camera = COALESCE(camera, %s),
                  lat = COALESCE(lat, %s),
                  lon = COALESCE(lon, %s),
                  tz_offset_s = COALESCE(tz_offset_s, %s),
                  taken_at = COALESCE(taken_at, %s),
                  exif = COALESCE(exif, %s::jsonb)
            WHERE id = %s""",
        (w, h, dur, camera, lat, lon, tz_offset_s, taken_at,
         json.dumps(exif_bits) if exif_bits else None, asset_id))

    got = conn.execute(
        "SELECT lat, lon FROM assets WHERE id = %s", (asset_id,)).fetchone()
    if got and got[0] is not None and got[1] is not None:
        jobq.enqueue(conn, "geocode", asset_id)
    for kind in ("embed", "faces", "caption", "thumb"):  # safety net, free
        jobq.enqueue(conn, kind, asset_id)


# ---------------------------------------------------------------- geocode ---
# Offline reverse_geocoder (GeoNames). Idempotency: place upsert on the 003
# natural key UNIQUE(name, admin1, cc); the asset's taken_at->place edges are
# delete-then-insert in one transaction.

_rg_lock = threading.Lock()
_rg_ready = False
_place_cols = None


def _reverse(lat, lon):
    global _rg_ready
    with _rg_lock:  # dataset load once; searches serialized (cheap, rare)
        import reverse_geocoder as rg
        if not _rg_ready:
            rg.search([(0.0, 0.0)], mode=1)  # warm the GeoNames KD-tree
            _rg_ready = True
        return rg.search([(lat, lon)], mode=1)[0]


def _places_columns(conn):
    global _place_cols
    if _place_cols is None:
        rows = conn.execute(
            """SELECT column_name FROM information_schema.columns
                WHERE table_schema = 'public' AND table_name = 'places'""").fetchall()
        _place_cols = {r[0] for r in rows}
    return _place_cols


def geocode(conn, asset_id):
    row = conn.execute(
        "SELECT lat, lon FROM assets WHERE id = %s", (asset_id,)).fetchone()
    if row is None:
        raise RuntimeError(f"asset {asset_id} not in db")
    lat, lon = row
    if lat is None or lon is None:
        return  # nothing to do — success, job is done

    res = _reverse(float(lat), float(lon))
    name = res.get("name") or "unknown"
    admin1 = res.get("admin1") or ""
    cc = res.get("cc") or ""

    have = _places_columns(conn)
    cols, vals = ["name", "admin1", "cc"], [name, admin1, cc]
    for col, val in (("admin2", res.get("admin2") or None),
                     ("lat", _num(res.get("lat"))),
                     ("lon", _num(res.get("lon")))):
        if col in have:
            cols.append(col)
            vals.append(val)
    place_id = conn.execute(
        f"""INSERT INTO places ({', '.join(cols)})
            VALUES ({', '.join(['%s'] * len(cols))})
            ON CONFLICT (name, admin1, cc)
            DO UPDATE SET name = EXCLUDED.name
            RETURNING id""",
        vals).fetchone()[0]

    with conn.transaction():
        conn.execute(
            """DELETE FROM edges
                WHERE src_type = 'asset' AND src_id = %s
                  AND rel = 'taken_at' AND dst_type = 'place'""",
            (asset_id,))
        conn.execute(
            """INSERT INTO edges (src_type, src_id, rel, dst_type, dst_id, confidence)
               VALUES ('asset', %s, 'taken_at', 'place', %s, 1.0)
               ON CONFLICT (src_type, src_id, rel, dst_type, dst_id)
               DO UPDATE SET confidence = EXCLUDED.confidence""",
            (asset_id, str(place_id)))


# ------------------------------------------------------------- event_scan ---
# Singleton, self-perpetuating. Full wipe-and-rebuild of events + part_of
# edges in ONE transaction (idempotent by construction; <100k assets is fine).
# Never calls done(): reschedules its own job run_after = now() + 6h.

GAP_S = 3 * 3600
DIST_KM = 50.0


def _haversine_km(lat1, lon1, lat2, lon2):
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp = math.radians(lat2 - lat1)
    dl = math.radians(lon2 - lon1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 6371.0 * 2 * math.asin(math.sqrt(a))


def event_scan(conn, job_id):
    rows = conn.execute(
        """SELECT id, taken_at, lat, lon FROM assets
            WHERE taken_at IS NOT NULL AND trashed_at IS NULL
            ORDER BY taken_at, id""").fetchall()

    clusters = []  # (asset_ids, starts_at, ends_at)
    ids, start, prev_t, prev_geo = [], None, None, None
    for aid, taken, lat, lon in rows:
        geo = (float(lat), float(lon)) if lat is not None and lon is not None else None
        if ids:
            split = (taken - prev_t).total_seconds() > GAP_S
            if not split and geo and prev_geo:  # missing geo = no geo constraint
                split = _haversine_km(*prev_geo, *geo) > DIST_KM
            if split:
                clusters.append((ids, start, prev_t))
                ids, start = [], None
        if not ids:
            start = taken
        ids.append(aid)
        prev_t, prev_geo = taken, geo
    if ids:
        clusters.append((ids, start, prev_t))

    with conn.transaction():
        conn.execute("""DELETE FROM edges
                         WHERE rel = 'part_of' AND src_type = 'asset'
                           AND dst_type = 'event'""")
        # only OUR auto-derived events — never wipe manually created ones
        conn.execute("DELETE FROM events WHERE kind = 'auto'")
        cur = conn.cursor()
        for asset_ids, starts_at, ends_at in clusters:
            event_id = cur.execute(
                "INSERT INTO events (t_start, t_end, kind) "
                "VALUES (%s, %s, 'auto') RETURNING id",
                (starts_at, ends_at)).fetchone()[0]
            cur.executemany(
                """INSERT INTO edges (src_type, src_id, rel, dst_type, dst_id, confidence)
                   VALUES ('asset', %s, 'part_of', 'event', %s, 1.0)""",
                [(aid, str(event_id)) for aid in asset_ids])
        # self-perpetuate: back to pending in 6h instead of done
        conn.execute(
            """UPDATE ingest_jobs
                  SET status = 'pending', locked_by = NULL, heartbeat_at = NULL,
                      error = NULL, run_after = now() + interval '6 hours',
                      updated_at = now()
                WHERE id = %s""",
            (job_id,))
