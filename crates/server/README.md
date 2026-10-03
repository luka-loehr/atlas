# atlas-server — the backend

One process: the HTTP API the app talks to, and the workers that turn an
uploaded file into something browsable. It owns the photo library, the drive
and the machine's status; the models live next door in
[atlas-ml](../ml/).

```bash
atlas-server                    # serve on :8787 and run the workers
atlas-server migrate            # apply schema migrations and exit
atlas-server import photos takeout-*.zip    # Google Takeout, read in place
atlas-server import drive takeout-*.zip
atlas-server backfill thumbs|dates|previews|drive-text|embeddings|faces
```

Installed and restarted by [`scripts/atlas/install.sh`](../../scripts/atlas/)
(`atlas deploy` from the Mac). Logs: `journalctl -u atlas-server -f`.

## API

Everything is under `/v1` and takes `Authorization: Bearer $ATLAS_TOKEN`
(media URLs also accept `?token=`). `/health` is open.

| Area | Routes |
|---|---|
| Library | `GET /server` · `/stats` · `/heatmap` |
| Timeline | `GET /timeline` (month index: key, count, validator) · `GET /timeline/{YYYY-MM\|undated}` (one month, columnar) |
| Assets | `PUT /assets` (streaming upload) · `POST /assets/exists` · `GET /assets/{id}` · `/assets/{id}/thumb/{512\|2048}` · `/assets/{id}/original` · `/assets/{id}/video` · `POST /assets/{favorite,archive,lock,trash,restore,delete}` |
| Collections | `GET /library/{favorites,videos,archive,locked,trash}` · `POST /library/trash/empty` · `/albums…` · `/people…` · `/faces/{id}/crop` · `/places…` |
| Search | `GET /search?q=` (people, places, albums, then meaning) · `POST /search/warm` |
| Drive | `GET /drive/folders/{id\|root}` · `PUT /drive/files` · `/drive/blobs/{hash}/{name}` · `/drive/{recent,search,move,trash,restore,delete}` |
| System | `GET /system` · `WS /system/live` · `/system/{services,containers,network,activity}` · `WS /system/terminal` · `POST /system/power/{shutdown\|restart}` |

The full list with one line each sits at the top of
[`photos/mod.rs`](src/photos/mod.rs), [`drive.rs`](src/drive.rs) and
[`system/mod.rs`](src/system/mod.rs).

## How it is built

- **Timeline cache** ([`photos/timeline.rs`](src/photos/timeline.rs)). Every
  month is held as a finished gzip body with an ETag and rebuilt only when a
  Postgres `NOTIFY` says an asset in it changed. A request is a hash lookup.
- **Columnar lists.** Asset lists are one array per field (`id[]`, `t[]`,
  `w[]`, `h[]`, …) instead of an array of objects: a third the size, and the
  thumbhash placeholder of every photo rides along.
- **Content addressing** ([`media.rs`](src/media.rs)). An asset's id is the
  SHA-256 of its bytes. Uploads are hashed while streaming to disk, duplicates
  cost nothing, and every media response is `immutable` with Range support.
- **Vector index** ([`photos/vectors.rs`](src/photos/vectors.rs)). All
  embeddings in one contiguous `n × 2048` matrix, kept current by `NOTIFY`.
  Search is an exact dot-product scan ranked by z-score, so a query with no
  real match returns nothing rather than the least-bad photos.
- **Job queue** ([`jobs/`](src/jobs/), protocol in
  [`atlas-core`](../core/src/queue.rs)). Rows in `ingest_jobs`, claimed with
  `FOR UPDATE SKIP LOCKED`, heartbeated, retried with backoff, reaped when a
  worker dies. Queues here: `thumb`, `meta`, `geocode`, `preview`,
  `drive_text`; `embed` and `faces` are worked by atlas-ml.
- **Imaging** ([`imaging.rs`](src/imaging.rs)). JPEG, PNG, WebP and HEIC are
  decoded in process, resized with SIMD, and written as WebP with the source's
  color profile kept, so wide-gamut photos stay wide-gamut.

## Configuration

Read from `/etc/atlas/atlas.env`
([template](../../scripts/atlas/atlas.env.example)). Each variable is
documented where it is read, in [`config.rs`](src/config.rs).

| Variable | Default | |
|---|---|---|
| `ATLAS_TOKEN` | required | bearer token, at least 16 characters |
| `POSTGRES_PASSWORD` | required | or a full `ATLAS_DATABASE_URL` |
| `ATLAS_BIND` | `0.0.0.0:8787` | the firewall confines it to loopback + tailnet |
| `ATLAS_PHOTOS_DIR` | `~/photos` | `originals/`, `thumbs/`, `faces/` |
| `ATLAS_PREVIEWS_DIR` | `$ATLAS_PHOTOS_DIR/previews` | video renditions |
| `ATLAS_DRIVE_DIR` | `~/drive` | `blobs/` |
| `ATLAS_TZ` | the machine's zone | the timezone days are grouped in |
| `ATLAS_WORKERS` | cores − 2, at most 8 | `0` runs the API without workers |
| `ATLAS_VIDEO_PREVIEWS` | on | `0` skips video renditions |
| `ATLAS_MAX_UPLOAD_GB` | `64` | largest accepted upload |
| `ATLAS_ML_URL` | `http://127.0.0.1:8786` | where query embeddings come from |

External tools the workers call: `ffmpeg`/`ffprobe` (video), `pdftoppm` and
`pdftotext` (drive previews and text).

## Development

```bash
cargo test -p atlas-server
ATLAS_TOKEN=dev-token-0123456789 POSTGRES_PASSWORD=… cargo run -p atlas-server
```
