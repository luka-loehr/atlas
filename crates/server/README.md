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
atlas-server openapi > openapi/openapi.json   # emit canonical OpenAPI 3.1 schema
```

Installed and restarted by [`scripts/atlas/install.sh`](../../scripts/atlas/)
(`atlas deploy` from the Mac). Logs: `journalctl -u atlas-server -f`.

## API

Routes live under `/v1` (JSON + streaming) and `/s3` (AWS S3 XML wire protocol).
Authentication accepts `Authorization: Bearer $ATLAS_TOKEN`, scoped API keys
(`Authorization: Bearer ATLK…:atls_…` or `X-Atlas-Key`), AWS SigV4
`Authorization: AWS4-HMAC-SHA256 …` headers, and AWS SigV4 presigned URLs
(read-only media/blob playback URLs also accept `?token=`). `/health` and
`/openapi.json` are open.

| Area | Routes |
|---|---|
| OpenAPI | `GET /openapi.json` · `GET /v1/openapi.json` (canonical OpenAPI 3.1 specification) |
| S3 Wire (`/s3`) | `GET /s3` (`ListBuckets`) · `PUT/DELETE/HEAD /s3/{bucket}` · `GET /s3/{bucket}` (`ListObjectsV2`, `ListObjects`, `?location`, `?versioning`, `?uploads`) · `POST /s3/{bucket}?delete` · `PUT/GET/HEAD/DELETE /s3/{bucket}/{*key}` (`PutObject`, `CopyObject`, Range `GetObject`, `UploadPart`, `ListParts`, `AbortMultipartUpload`) · `POST /s3/{bucket}/{*key}` (`?uploads`, `?uploadId=`) |
| Buckets | `GET/POST /v1/buckets` · `GET/DELETE /v1/buckets/{bucket}` · `GET /v1/buckets/{bucket}/objects` · `PUT/GET/HEAD/DELETE /v1/buckets/{bucket}/objects/{*key}` · `GET /v1/buckets/{bucket}/stat/{*key}` · `POST /v1/buckets/{bucket}/{copy,delete,presign}` |
| IAM & Keys | `GET /v1/auth/whoami` · `GET/POST /v1/accounts` · `GET/PATCH/DELETE /v1/accounts/{id}` · `GET/POST /v1/keys` · `GET/DELETE /v1/keys/{id}` · `POST /v1/keys/{id}/revoke` |
| Developer Media | `GET /v1/media/search?q=` · `GET /v1/media/similar/{id}` · `GET /v1/media/assets/{id}` |
| Library | `GET /server` · `/work` (what atlas is busy with) · `/stats` · `/heatmap` |
| Timeline | `GET /timeline` (month index: key, count, validator) · `GET /timeline/{YYYY-MM\|undated}` (one month, columnar) |
| Assets | `PUT /assets` (streaming upload) · `POST /assets/exists` · `GET /assets/{id}` · `/assets/{id}/thumb/{512\|2048}` · `/assets/{id}/tile` · `/assets/{id}/original` · `/assets/{id}/video` · `POST /assets/{favorite,archive,lock,trash,restore,delete}` |
| Collections | `GET /library/{favorites,videos,archive,locked,trash}` · `POST /library/trash/empty` · `/albums…` · `/people…` · `/faces/{id}/crop` · `/places…` · `/covers` |
| Search | `GET /search?q=` (people, places, albums, then meaning) · `POST /search/warm` |
| Drive | `GET /drive/folders/{id\|root}` · `PUT /drive/files` · `/drive/files/{id}/thumb` · `/drive/blobs/{hash}/{name}` · `/drive/{recent,search,move,trash,restore,delete}` |
| Shares | `GET/POST /shares` · `GET/DELETE /shares/{id}` (links through [atlas-share](../../share/), 7 days at most; the link preview is drawn in [`share/og.rs`](src/share/og.rs)) |
| System | `GET /system` · `WS /system/live` · `/system/{services,drives,containers,network,activity}` · `WS /system/terminal` · `POST /system/power/{shutdown\|restart}` |

The full list with one line each sits at the top of
[`photos/mod.rs`](src/photos/mod.rs), [`drive/mod.rs`](src/drive/mod.rs),
[`system/mod.rs`](src/system/mod.rs) and [`share/mod.rs`](src/share/mod.rs).

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
- **Vector index** ([`photos/search/vectors.rs`](src/photos/search/vectors.rs)). All
  embeddings in one contiguous `n × 2048` matrix, kept current by `NOTIFY`.
  Search is an exact dot-product scan, photos against the query's photo
  question and videos against its video question, ranked by z-score within
  their kind, so a query with no real match returns nothing rather than the
  least-bad photos, and videos do not crowd out better photos.
- **Job queue** ([`jobs/`](src/jobs/), protocol in
  [`atlas-core`](../core/src/queue.rs)). Rows in `ingest_jobs`, claimed with
  `FOR UPDATE SKIP LOCKED`, heartbeated, retried with backoff. Queues here:
  `thumb`, `meta`, `geocode`, `preview`, `drive_text`; `embed` and `faces`
  are worked by atlas-ml, queued by the thumbnail job.
- **Self-healing.** Nothing waits forever and nothing holds up anything
  else: every job and every external tool has a time limit, a job that
  crashes or hangs its worker spends an attempt (recovered at start, reaped
  by heartbeat), a clean shutdown hands its jobs back, and an hourly
  check-up ([`jobs/heal.rs`](src/jobs/heal.rs)) queues missing work, drops
  jobs whose photo is gone and retries failed jobs later. What fails for
  good is parked as `stuck` with its reason (listed under
  `GET /v1/system/services`) and starts over when its input is fixed.
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
| `ATLAS_POWER_BASELINE_W`, `ATLAS_PSU_EFFICIENCY` | `35`, `0.88` | calibrate the whole-system power estimate |
| `ATLAS_REPO_DIR` | `~/atlas` | checkout whose commits feed the activity heatmap |
| `ATLAS_SHARE_URL`, `ATLAS_SHARE_TOKEN` | unset | the atlas-share Worker; `atlas share setup` writes both |

External tools the workers call: `ffmpeg`/`ffprobe` (video), `pdftoppm` and
`pdftotext` (drive previews and text).

## Development

```bash
cargo test -p atlas-server
ATLAS_TOKEN=dev-token-0123456789 POSTGRES_PASSWORD=… cargo run -p atlas-server
```
