# atlas-backend — one Postgres for everything

The data foundation of atlas: media library, personal knowledge graph and
vectors live in **one** `postgres:17 + pgvector` instance (Docker, NVMe
volume, `127.0.0.1:5432` — remote dev via `ssh atlas -L 5432:localhost:5432`).

## Design

- **Domain tables ARE the graph nodes** — `assets`, `persons`, `places`,
  `events`, `faces` (later: `mails`, `transactions`, `locations`, …).
- **`edges`** links any row to any row across domains
  (`('asset', <hash>) --shows--> ('person', 7)`), with `rel`, `props`,
  `confidence`. Traversals via `WITH RECURSIVE`; Apache AGE (Cypher) can be
  added later without moving data.
- **`embeddings`** holds all vectors (`vector(768)`, HNSW per model).
  First citizens: `siglip2` image vectors (semantic search), `arcface`
  face vectors (person clustering). Text models join with the mail/doc layers.
- **`ingest_jobs`** is the resumable work queue: every asset spawns its
  pending jobs (thumb, embed, faces, whisper, caption); GPU workers drain it
  whenever atlas is awake — pausing atlas pauses the pipeline, nothing breaks.
- IDs for media are **BLAKE3 content hashes** — dedupe key and immutable
  asset-URL key for `atlas-photos` in one.

## Run

```bash
cd backend/docker
cp .env.example .env       # set a real POSTGRES_PASSWORD
docker compose up -d
docker exec -i atlas-postgres psql -U atlas -d atlas < ../schema/001_init.sql
```

Migrations are plain numbered SQL files in `schema/`; applied versions are
tracked in `schema_migrations`.

## Consumers

| consumer | talks via |
|---|---|
| `apps/atlas-photos` server (Rust/axum + sqlx) | timeline, assets, albums |
| ingest workers (Python: takeout, mail, owntracks…) | assets, edges, ingest_jobs |
| ML workers (GPU: SigLIP, InsightFace, Whisper, VLM) | embeddings, faces, ingest_jobs |
| MCP `atlas-memory` (Hermes/Claude) | semantic_search, graph_query, add_fact |
