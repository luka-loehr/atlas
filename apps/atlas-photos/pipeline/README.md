# atlas-photos pipeline

The AI indexing pipeline for the photo library: three always-on Docker
services that drain the `ingest_jobs` queue in Postgres (container
`atlas-postgres`, `127.0.0.1:5432`, db/user `atlas` — see
[`backend/`](../../../backend/README.md)). Ingest and upload paths only insert
queue rows; everything below picks them up asynchronously.

| Service | Jobs | Base image |
|---|---|---|
| `pipeline-cpu` | `thumb`, `meta`, `geocode`, `event_scan` | `python:3.12-slim` |
| `pipeline-gpu` | `embed` (Qwen3-VL-Embedding-2B), `faces` (InsightFace buffalo_l), `caption` (vLLM Qwen2.5-VL-3B-Instruct-AWQ) | `vllm/vllm-openai` (pinned by digest) |
| `embed-api` | none — text-embedding sidecar for semantic search, loopback `127.0.0.1:8093` | GPU image, run CPU-only |

All services use `network_mode: host` (they reach Postgres and each other via
loopback) and `restart: unless-stopped`. The GPU container needs the NVIDIA
Container Toolkit — see [docs/SETUP.md](../../../docs/SETUP.md).

## What each job does

- **thumb** — 512/2048 WebP thumbnails (quality 88, source ICC profile kept so
  Display-P3 photos don't wash out), written atomically; video poster frame at
  1 s via ffmpeg (fallback: first frame); backfills width/height/duration.
- **meta** — `exiftool -j -n`: taken-at (with timezone handling), camera, GPS,
  dimensions and a capture-parameter subset into `assets.exif`. Fill-NULL
  semantics (`COALESCE`) — re-runs change nothing. Enqueues `geocode` when GPS
  is present, plus the other stages as a free safety net.
- **geocode** — offline reverse geocoding (`reverse_geocoder`, GeoNames) into
  `places` + `taken_at` edges.
- **event_scan** — clusters the whole timeline into events (split at > 3 h gap
  or > 50 km jump), wipe-and-rebuild of auto-derived events only. A singleton
  job that reschedules itself 6 h out instead of completing.
- **embed** — Qwen3-VL-Embedding-2B image and video embeddings into one joint
  text/image/video vector space (`embeddings`, `model='qwen3vl'`,
  `vector(2048)`). Photos embed the 2048 thumb; videos embed up to 12 frames
  sampled from the original file.
- **faces** — InsightFace SCRFD detection + ArcFace embeddings; incremental
  person clustering against per-person centroids (cosine similarity > 0.55
  joins, otherwise a new person), square avatar crops to
  `$PHOTOS_DIR/faces/<face_id>.webp`.
- **caption** — Qwen2.5-VL-3B-Instruct-AWQ via offline vLLM produces a JSON
  caption+tags object per photo; only the 5–12 lowercase English tags are
  stored (`tags`, `source='qwen2.5-vl'`), the caption is validation-only and
  discarded.

The `embed-api` sidecar (`embed_api.py`) answers
`POST /embed {"text": "..."}` with a 2048-float L2-normalized vector from the
same embedding model, CPU-only (~1–3 s per query) — the Rust server calls it
to embed search queries into the image/video vector space. `GET /health` for
liveness.

## Build & run

Prerequisite: `backend/schema` migrations 001–007 applied (queue columns,
faces/persons/tags, exif, qwen embeddings, drive tables).

```bash
cd apps/atlas-photos/pipeline
cp .env.example .env    # set host paths + uid/gid, pin the model revision
docker compose up -d --build
```

First-start expectations:

- The vLLM base image is a large pull (several GB); the CPU image is small.
- On its first start the GPU container downloads ~6 GB of models
  (Qwen3-VL-Embedding-2B, Qwen2.5-VL-3B-Instruct-AWQ, buffalo_l) into the
  `ATLAS_MODELS_DIR` mount before the worker loop begins — watch
  `docker compose logs -f pipeline-gpu`. Subsequent starts skip this
  (idempotent check in `download_models.py`).

**Deploying new code:** the pipeline source is mounted into the containers at
`/app` (read-only), not baked into the images:

```bash
cd ~/atlas && git pull
cd apps/atlas-photos/pipeline && docker compose restart
```

Rebuild (`docker compose up -d --build`) only when dependencies change, i.e.
after Dockerfile edits.

**Autostart:** all services are `restart: unless-stopped`; with the Docker
daemon enabled at boot, powering the box on brings the whole pipeline up with
no further action. A job that was mid-flight at power loss is re-queued
automatically (see crash safety). Note that `unless-stopped` also means an
explicit `docker compose stop` survives reboots.

**Backfill:** to enqueue jobs for assets that predate the pipeline, run
`python3 backfill_jobs.py` on the host (set `PHOTOS_DIR` to the library root;
safe to run repeatedly).

## Configuration

Host-side `.env` next to `docker-compose.yml` (compose interpolation):

| Variable | Default | Purpose |
|---|---|---|
| `ATLAS_PHOTOS_DIR` | `/srv/atlas/photos` | host photo library (`originals/`, `thumbs/`, `faces/`), mounted at `/photos` |
| `ATLAS_MODELS_DIR` | `/srv/atlas/models` | model cache (~6 GB), mounted at `/models` |
| `ATLAS_PG_ENV_FILE` | `../../../backend/docker/.env` | file with a `POSTGRES_PASSWORD=` line, mounted read-only at `/secrets/.env` |
| `ATLAS_PIPELINE_UID` / `ATLAS_PIPELINE_GID` | `1000` / `1000` | uid:gid `pipeline-cpu` writes thumbs as (match the library owner) |
| `ATLAS_EMBED_REVISION` | `main` | git revision of the Qwen embedding model repo. Its bundled `scripts/` code is imported and executed by the workers — pin a commit sha to freeze the supply chain |

Environment read inside the containers/scripts (compose sets the first four):

| Variable | Default | Purpose |
|---|---|---|
| `PHOTOS_DIR` | `/photos` in-container, `~/photos` bare-metal | library root |
| `MODELS_DIR` | `/models` | model cache root |
| `HF_HOME` | `$MODELS_DIR/hf` | Hugging Face cache |
| `PG_ENV_FILE` | `/secrets/.env`, fallback `~/atlas/backend/docker/.env` | Postgres password file |
| `PGHOST` / `PGPORT` / `PGDATABASE` / `PGUSER` | `127.0.0.1` / `5432` / `atlas` / `atlas` | Postgres connection |
| `EMBED_API_PORT` | `8093` | embed-api loopback listen port (must match the server's `ATLAS_EMBED_API_ADDR`) |
| `ATLAS_MAX_IMAGE_PIXELS` | `500000000` | decompression-bomb ceiling for image decoding |

## Watching it work

```bash
docker compose ps
docker compose logs -f pipeline-cpu
docker compose logs -f pipeline-gpu
nvidia-smi                  # exactly ONE model resident at a time by design
```

Queue depth by kind/status:

```bash
docker exec -it atlas-postgres psql -U atlas -d atlas -c \
  "SELECT kind, status, count(*) FROM ingest_jobs GROUP BY 1,2 ORDER BY 1,2;"
```

Failures (gave up after 5 attempts):

```bash
docker exec -it atlas-postgres psql -U atlas -d atlas -c \
  "SELECT id, kind, owner_id, attempts, left(error, 120) FROM ingest_jobs
   WHERE status='failed' ORDER BY updated_at DESC LIMIT 20;"
```

## Re-indexing a single asset

Every handler is idempotent, so re-running is always safe. Flip the job(s)
back to pending (`<sha256>` is `assets.id`):

```sql
-- one stage for one asset:
UPDATE ingest_jobs SET status='pending', attempts=0, error=NULL, run_after=now()
WHERE kind='caption' AND owner_type='asset' AND owner_id='<sha256>';

-- everything for one asset:
UPDATE ingest_jobs SET status='pending', attempts=0, error=NULL, run_after=now()
WHERE owner_type='asset' AND owner_id='<sha256>';
```

If no job row exists yet (new stage for an old asset), insert one — the unique
key makes it a no-op if it is already there:

```sql
INSERT INTO ingest_jobs (kind, owner_type, owner_id, status)
VALUES ('embed', 'asset', '<sha256>', 'pending')
ON CONFLICT (kind, owner_type, owner_id) DO NOTHING;
```

Workers pick pending jobs up within one loop iteration (≤ ~30 s).

## Crash safety

Power-off at any moment is fine:

- **Claiming** is a single atomic `UPDATE … FOR UPDATE SKIP LOCKED` statement:
  a job is claimed exactly once, no matter how many workers race.
- Running jobs **heartbeat every 60 s** from a daemon thread. A **reaper** (at
  every worker startup and every 5 min) resets jobs whose heartbeat is older
  than 10 minutes back to `pending`, so a job orphaned by a crash or power cut
  re-queues automatically at the next boot.
- Every handler is **idempotent** (pure upserts, or delete-then-insert per
  asset in one transaction) — a job that ran halfway and is retried produces
  the same end state, never duplicates.
- Failures retry with linear backoff (`attempts × 5 min`), giving up into
  `failed` after 5 attempts — visible via the SQL above, never silently
  looping. Jobs whose *input* isn't ready yet (thumb not generated) are
  requeued for 30 min later without an attempts penalty.
- `event_scan` is a self-perpetuating singleton (re-scheduled 6 h out instead
  of finishing); the CPU worker additionally revives a `failed` singleton on
  every start so it can never die permanently.
- Both workers wait for Postgres at startup instead of crash-looping, and
  claim priority order means fresh uploads (thumb priority 10, meta 20) jump
  ahead of backfill jobs (default 100).

## GPU sequencing (8 GB VRAM)

One GPU worker process drains stages strictly in sequence — all `embed`, then
all `faces`, then all `caption` — loading one model at a time and freeing VRAM
between stages (batch sizes 6/16/8). The vLLM engine only exists while caption
jobs are pending. A stage whose model fails to load backs off for 15 min
without blocking the other stages. If `nvidia-smi` ever shows two models
resident, that is a bug.
