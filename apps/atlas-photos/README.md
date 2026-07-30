# atlas-photos

A self-hosted replacement for Google Photos and Google Drive: a Rust API
server, a Dockerized AI indexing pipeline and a SwiftUI iPhone app (shipped
under the display name "Atlas Photos"). Originals live on the server's disk;
Postgres (see [`backend/`](../../backend/README.md)) holds metadata, albums,
faces/persons, tags, places, events and 2048-dim multimodal embeddings for
semantic search.

Everything is content-addressed: an asset's id is the lowercase-hex SHA-256 of
its exact bytes, computed identically by the server upload path, the Takeout
ingest scripts and the iOS client. Identical content collapses to one id no
matter how it arrives, and media URLs never change, so clients cache them as
immutable.

| Directory | Contents |
|---|---|
| `server/` | axum HTTP server: timeline, albums, search, persons, state mutations, upload, drive (default port 8788) |
| `pipeline/` | CPU/GPU workers + text-embedding sidecar that index the library — see [pipeline/README.md](pipeline/README.md) |
| `ingest/` | Google Takeout import (photos + drive), drive text extraction, thumbnail recovery — see [Ingest](#ingest) |
| `ios/` | SwiftUI app, tabs "Fotos", "Alben", "Dateien" and search |

Machine-level setup (Ubuntu, NVIDIA driver, Docker, Tailscale) is covered in
[docs/SETUP.md](../../docs/SETUP.md). The database schema comes from
[`backend/schema/`](../../backend/schema) — apply migrations 001–007 before
running anything here.

## On-disk layout

```
$PHOTOS_DIR/                          # default $HOME/photos
  originals/YYYY/MM/<sha256>_<name>   # Takeout ingest ("0000/00" when undated)
  originals/YYYY/MM/<sha256>.<ext>    # iPhone uploads (whitelisted extension, else .bin)
  thumbs/<sha256>.512.webp            # grid thumbnail
  thumbs/<sha256>.2048.webp           # viewer thumbnail
  faces/<face_id>.webp                # square avatar crops (pipeline)
  vecmap/                             # optional static bundle for /map (experimental)

$DRIVE_DIR/                           # default $HOME/drive
  blobs/<sha256>                      # drive file content, deduplicated, refcounted
```

## Server

`server/` is a single-binary axum server (`tokio-postgres`/`deadpool`, no ORM).
What it does:

- **Timeline** — month summary plus cursor-paged, newest-first asset pages;
  archived/trashed/locked assets are excluded everywhere and live in their own
  buckets.
- **Search** — one query box covers person names, places (German/English
  country names resolve to ISO codes via `server/src/countries.rs`), tags,
  album titles, filenames and years. When structured hits are thin (< 150),
  the query is embedded by the `embed-api` sidecar and an exact fp32 cosine
  scan over the Qwen3-VL vectors fills in semantically similar photos and
  videos.
- **Media serving** — thumbs, originals and Range-capable streaming (works
  with AVPlayer) with `Cache-Control: immutable` and `nosniff`. Original paths
  are canonicalized and must resolve inside the photos root.
- **Upload/sync** — raw-body upload; the server hashes the received bytes
  itself and enqueues pipeline jobs. `POST /api/exists` lets clients skip
  content the library already has.
- **Drive** — folder tree over content-addressed blobs with rename/move/trash,
  filename + full-text search (snippets), refcounted blob GC and an upload
  hook that spawns `ingest/extract_drive_text.py` per file.

### API surface

| Route | Description |
|---|---|
| `GET /health` | liveness (always unauthenticated) |
| `GET /api/stats`, `/api/heatmap` | library totals; assets per day for the last ~53 weeks |
| `GET /api/timeline/summary` | `[{month:"2024-07", count}]` |
| `GET /api/timeline?before=&limit=` | newest-first cursor pages (limit ≤ 100 000) |
| `GET /api/albums`, `/api/albums/{id}/assets` | album list with cover + contents |
| `GET /api/search?q=` | structured + semantic search, returns `items` and `persons` chips |
| `GET /api/assets/{id}/thumb/{512\|2048}` | WebP thumbs, immutable |
| `GET /api/assets/{id}/original`, `/stream` | original bytes; Range streaming |
| `GET /api/assets/{id}/info`, `/faces` | EXIF/place/tags detail; detected faces |
| `GET /api/persons`, `/api/persons/{id}/assets` | person clusters and their photos |
| `POST /api/persons/{id}/rename`, `/cover` | name a person, pick an avatar face |
| `GET /api/faces/{id}/crop` | avatar crop written by the face worker |
| `GET /api/archive`, `/api/trash`, `/api/locked` | the three hidden buckets |
| `POST /api/mutate/favorite\|archive\|lock` | batch `{ids, value}` |
| `POST /api/mutate/trash\|restore\|delete`, `/api/trash/empty` | batch `{ids}`; delete/empty are permanent (files + all DB child rows) |
| `POST /api/exists` | `{hashes:[…]}` → `{have:[…]}` (client-side dedup) |
| `POST /api/upload` | raw body; headers `X-Filename`, `X-Taken-At` (unix s), optional `X-Content-Hash` integrity check |
| `GET /map`, `/map/*` | experimental UMAP mosaic; 404 unless a generated bundle sits in `$PHOTOS_DIR/vecmap` |
| `GET /api/drive/list?folder=`, `/search?q=` | folder browsing and search |
| `GET /api/drive/recent`, `/api/drive/stats` | newest files across all folders; drive totals. Served, but no shipped client calls them — they exist for ad-hoc use |
| `GET /api/drive/blob/{hash}/{name}` | immutable, Range-capable download; script-capable types are forced to `attachment` |
| `POST /api/drive/upload` | raw body; headers `X-Filename` (percent-encoded), `X-Folder-Id`, optional `X-Content-Hash`, `X-Modified-At` |
| `POST /api/drive/folders`, `…/{id}/rename`, `…/{id}/delete` | folder ops; delete is a permanent subtree delete + blob GC |
| `POST /api/drive/files/{id}/rename`, `/api/drive/move` | file ops; move rejects folder cycles |
| `GET/POST /api/drive/trash`, `/restore`, `/delete`, `/trash/empty` | drive trash lifecycle |

### Build & run

```bash
cd apps/atlas-photos/server
cargo build --release
sudo install -m755 target/release/atlas-photos /usr/local/bin/
sudo cp atlas-photos.service /etc/systemd/system/
sudo systemctl enable --now atlas-photos
```

Edit the unit first: set `User=` to the account that owns the library and add
`Environment=`/`EnvironmentFile=` lines as needed (examples are in the unit
file). The server needs `HOME` set and refuses to start without a Postgres
password.

### Configuration

| Variable | Default | Purpose |
|---|---|---|
| `PHOTOS_DIR` | `$HOME/photos` | photo library root (`originals/`, `thumbs/`, `faces/`, `vecmap/`) |
| `DRIVE_DIR` | `$HOME/drive` | drive blob root (`blobs/`) |
| `ATLAS_PHOTOS_BIND` | `0.0.0.0:8788` | listen address |
| `ATLAS_PHOTOS_TOKEN` | unset | bearer token, sent as `Authorization: Bearer <token>` or `?token=`. **Every mutation requires it**; reads require it too unless `ATLAS_PHOTOS_OPEN=1` |
| `ATLAS_PHOTOS_OPEN` | unset | `1` = reads (GET/HEAD) need no token, for a trusted network. Never authorizes a mutation |
| `ATLAS_PHOTOS_MAX_UPLOAD` | `512` | upload body cap in MiB (bodies are buffered in RAM) |
| `ATLAS_EMBED_API_ADDR` | `127.0.0.1:8093` | text-embedding sidecar (see pipeline); failures degrade search to structured-only |
| `ATLAS_DRIVE_EXTRACTOR` | `$HOME/atlas/apps/atlas-photos/ingest/extract_drive_text.py` | script run (fire-and-forget) after each drive upload |
| `PGHOST` / `PGPORT` / `PGDATABASE` / `PGUSER` | `127.0.0.1` / `5432` / `atlas` / `atlas` | Postgres connection |
| `POSTGRES_PASSWORD` | unset | DB password; if empty, parsed from `PG_ENV_FILE` |
| `PG_ENV_FILE` | `$HOME/atlas/backend/docker/.env` | file containing a `POSTGRES_PASSWORD=` line |

**Security note:** mutations fail closed. `/api/mutate/*`, `/api/trash/empty`,
`/api/upload` and the whole drive write surface require `ATLAS_PHOTOS_TOKEN`,
and no environment variable relaxes that — with no token configured they are
refused outright (`403`), because there would be nothing to tell an authorized
client apart from anyone else who can reach the port. This matters: permanent
deletes (`/api/mutate/delete`, `/api/trash/empty`, drive folder delete) remove
files from disk.

Reads are the part you choose. `ATLAS_PHOTOS_OPEN=1` serves the timeline,
thumbs, originals and search to anything that can reach the listen address —
fine on a tailnet, not fine on `0.0.0.0` with an untrusted LAN attached. Leave
it unset to require the token for reads as well, or narrow `ATLAS_PHOTOS_BIND`
to the tailnet address / `127.0.0.1` behind `tailscale serve`.

## iOS app

`ios/` is an XcodeGen project (`project.yml`, deployment target iOS 26).
Regenerate and build:

```bash
cd apps/atlas-photos/ios
xcodegen generate
open AtlasPhotos.xcodeproj   # set your own team/bundle prefix in project.yml
```

Like its siblings, the committed project ships `CODE_SIGNING_ALLOWED: NO`; for
a device build enable signing and set your team in `project.yml` — not in
Xcode, since `xcodegen generate` overwrites the project file.

The server host is configured inside the app (e.g.
`atlas.your-tailnet.ts.net:8788`) along with an optional bearer token; nothing
is compiled in. The app renders the timeline as a scrubbable grid backed by the
immutable asset URLs (URLCache does the rest), streams videos via AVPlayer,
browses the drive tab with QuickLook previews, and can back up the camera roll
automatically — foreground quick-sync on app activation plus a
`BGProcessingTask` in the background, deduplicated through `/api/exists`.
An ATS exception allows plain HTTP to `*.ts.net` hosts (in-tailnet traffic is
already encrypted by WireGuard).

### Naming

Same convention as the other Atlas apps: `*Screen` is a full-surface
destination that owns its own `NavigationStack` — a tab root, a pushed
destination or a sheet-presented one. `*Sheet` is a modal auxiliary
(`AccountSheet`, `InfoSheet`, `ShareSheet`). Everything else is a component
with a plain descriptive name (`PhotoPager`, `SelectionToolbar`,
`SelectableThumb`). The `View` suffix means one thing only: a type whose job is
to wrap UIKit (`PlayerLayerView`, `ZoomableScrollView`), plus the app shell's
`RootView`.

## Ingest

Host-side tooling, run on the server. Most of it is one-shot, but not all:
`ingest_watcher.sh` is a bash loop meant to run as a daemon, and
`extract_drive_text.py` is additionally spawned per upload by the Rust server
(`ATLAS_DRIVE_EXTRACTOR`) rather than being invoked by hand. They share the
Postgres settings and `PG_ENV_FILE` convention above.

Install the Python dependencies first:

```bash
pip install -r apps/atlas-photos/ingest/requirements.txt
```

That covers `psycopg`, `Pillow` and `pillow-heif`. The rest are system
binaries, not pip packages: `ffmpeg`/`ffprobe` for video poster frames and
`pdftotext` (poppler-utils) for PDF text.

| Script | Purpose |
|---|---|
| `ingest_takeout.py *.zip` | Google Takeout photos: reads media straight out of the zips (no unpacking), merges JSON sidecars across zips, dedups by SHA-256, writes originals + 512/2048 thumbs, fills `assets`/`albums` and enqueues pipeline jobs. Idempotent. |
| `ingest_watcher.sh` | loops over `$ATLAS_TAKEOUT_DIR` (default `$HOME/takeout/photos`), validates each zip, ingests sequentially, writes a `.ingested` marker and deletes the zip on success |
| `ingest_drive.py *.zip` | Takeout Drive: streams entries into `blobs/<sha256>` and mirrors the folder tree into `drive_folders`/`drive_files`. Idempotent. |
| `extract_drive_text.py` | fills `drive_files.text` for content search (plain text, PDF, docx/pptx/xlsx). Modes: no args = backfill NULLs, `--all`, `--file-id N` (used by the upload hook) |
| `make_thumbs.py [--all]` | manual recovery only: **does the thumbnailing itself** and deletes the processed thumb job rows, bypassing the queue protocol — run it with the pipeline workers **stopped**. `--all` force-regenerates every asset. This is the tool for when the pipeline is the thing that is broken |
| `../pipeline/backfill_jobs.py` | the opposite direction: only *enqueues* rows in `ingest_jobs` (`ON CONFLICT DO NOTHING`, safe to re-run) for the workers to pick up, so the pipeline must be **running**. Covers every stage, not just thumbs, but has no force path |

Ingest-specific knobs: `ATLAS_INGEST_WORKERS` (process pool, default: all
cores), `ATLAS_MAX_IMAGE_PIXELS` (decompression-bomb ceiling, default 500 MP),
`ATLAS_INGEST_LOG` (watcher log, default `$HOME/ingest_watcher.log`).

## Operational notes

- The server serves media directly from disk; it never blocks on the pipeline.
  A freshly uploaded photo appears in the grid as soon as its high-priority
  thumb job lands (typically seconds).
- Semantic search silently degrades to structured-only results whenever the
  embed sidecar is down or slower than 6 s — nothing breaks.
- Re-uploading previously purged bytes recreates the same asset id; purge
  removes every child row (embeddings, tags, faces, edges, jobs) precisely so
  stale data cannot re-attach to the new row.
- Pipeline operation, queue monitoring and crash-safety guarantees:
  [pipeline/README.md](pipeline/README.md).
