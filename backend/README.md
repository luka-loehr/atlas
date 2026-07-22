# backend — one Postgres for everything

The shared data layer of the atlas monorepo: a single Postgres 17 + pgvector
instance (Docker image `pgvector/pgvector:pg17`). It stores the media
library, a personal knowledge graph, vector embeddings, a resumable work
queue, and a content-addressed file drive.

This directory contains only the container definition (`docker/`) and the SQL
schema (`schema/`). The consumers — the Rust photo server, the Python ingest
scripts, and the CPU/GPU pipeline workers — live in `apps/atlas-photos`.

## Schema

Plain numbered SQL migrations in `schema/` (`001` … `007`). Design in short:
domain tables are the graph nodes, one generic `edges` table links them, one
`embeddings` table holds all vectors.

**Media** — `assets` (photos/videos), `albums`, `album_assets`, `tags`.
`assets.id` is the file's SHA-256 content hash (dedupe key and stable asset
URL in one; the `BLAKE3` comment in `001_init.sql` is historical — every
ingest path computes SHA-256). Per-asset state lives in `archived`,
`trashed_at` and `locked` columns with matching partial indexes, so the main
timeline query is a single index scan. `exif` (JSONB) holds a curated subset
of exiftool output for the viewer's info sheet.

**Graph** — `persons`, `places`, `events`, `faces`, plus `edges`
(`src_type, src_id, rel, dst_type, dst_id` with JSONB `props` and a
`confidence` score). Any row in any domain can link to any other; consumers
resolve links with plain joins. Rels currently written: `taken_at`
(asset → place), `part_of` (asset → event), `depicts` (asset → person).
`faces` carries a 512-d ArcFace `embedding`; person
clustering runs in the worker (there is deliberately no vector index on it).
`persons` keeps an online `centroid`, `face_count` and a `cover_face_id`.

**Vectors** — `embeddings (owner_type, owner_id, model, vec)` with
`vec vector(2048)`: multimodal Qwen3-VL image/video embeddings, one text/image/
video space. Semantic search is an exact fp32 cosine scan — at a
tens-of-thousands library size an ANN index would only add approximation
error while the query embedding itself dominates latency.

**Queue** — `ingest_jobs`: every ingested file spawns its pending jobs;
workers claim them (`status`, `run_after`, `priority`, `locked_by`,
`heartbeat_at`) and drain the queue whenever the machine is awake. Powering
the box down pauses the pipeline; nothing breaks. Job kinds currently used by
the workers: `thumb`, `meta`, `geocode`, `event_scan` (CPU) and `embed`,
`faces`, `caption` (GPU; despite the name, the caption stage stores only
tags — `tags.source` defaults to `qwen2.5-vl`).

**Drive** — `drive_folders`, `drive_files`: a file domain with the same
philosophy as `assets`. Blobs are content-addressed by SHA-256 and stored
once on disk (e.g. `~/drive/blobs/<hash>`, managed by the atlas-photos
server); rows reference them by hash. `drive_files.text` holds extracted
document text for search, filled by
`apps/atlas-photos/ingest/extract_drive_text.py`.

The database stores metadata and vectors only — original media and drive
blobs live on the filesystem.

## Run

Requires Docker with Compose v2. Host provisioning (Ubuntu, Docker, GPU) is
covered in [docs/SETUP.md](../docs/SETUP.md).

```bash
cd backend/docker
cp .env.example .env        # set a real POSTGRES_PASSWORD
docker compose up -d

# apply ALL migrations, in order — there is no migration runner
for f in ../schema/0*.sql; do
  docker exec -i atlas-postgres psql -U atlas -d atlas < "$f"
done
```

Verify:

```bash
docker exec atlas-postgres psql -U atlas -d atlas -c 'TABLE schema_migrations;'
# expect versions 1 through 7
```

Every migration is idempotent (safe to re-run) and inserts its own version
into `schema_migrations`; nothing reads that table — it is bookkeeping, not a
runner. A fresh install must apply all seven files in numeric order. The
chain contains some churn (`003` creates objects that `005` drops again);
that is expected and harmless.

## Configuration

`docker/.env` (copy from `.env.example`, gitignored):

| Variable | Default | Purpose |
|---|---|---|
| `POSTGRES_PASSWORD` | *(none — required)* | Password for the `atlas` database role. Compose refuses to start without it. Generate one: `openssl rand -base64 24` |

Fixed in `docker/compose.yml`: database `atlas`, user `atlas`, container name
`atlas-postgres`, port `5432` bound to `127.0.0.1` only, named Docker volume
`pgdata`, `shm_size: 1g`, healthcheck via `pg_isready`, restart
`unless-stopped`.

## Consumers

| consumer | tables |
|---|---|
| `apps/atlas-photos/server` (Rust: axum, tokio-postgres, deadpool-postgres) | all of them: assets, albums, album_assets, tags, persons, faces, places, edges, embeddings, ingest_jobs, drive_* |
| `apps/atlas-photos/ingest` (Python: takeout + drive importers) | assets, albums, album_assets, drive_*, ingest_jobs |
| `apps/atlas-photos/pipeline` (CPU + GPU workers) | ingest_jobs, assets, embeddings, faces, persons, places, events, edges, tags |

All consumers share the single `atlas` role with full rights — acceptable for
a single-user homelab, not a multi-tenant setup. There is no row-level
security and no per-service role separation.

## Operational notes

- **Network model:** Postgres is bound to `127.0.0.1` only and the connection
  is not TLS-encrypted. Do not publish the port. For remote development,
  tunnel over SSH: `ssh your-server -L 5432:localhost:5432`, then connect to
  `localhost:5432`.
- **Persistence:** data lives in the `pgdata` Docker volume and survives
  restarts and reboots. No backup mechanism is included; if the data matters
  to you, schedule something like
  `docker exec atlas-postgres pg_dump -U atlas atlas | gzip > atlas.sql.gz`.
- **Port conflicts:** the compose file claims host port 5432; stop any
  host-side Postgres first or edit the port mapping.
