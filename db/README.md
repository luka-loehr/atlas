# db — Postgres and the schema

Postgres 17 with pgvector in one container, bound to loopback. It holds
everything Atlas knows that is not a file: assets, albums, people, places,
the drive tree, embeddings and the job queue.

```bash
cp .env.example .env        # set POSTGRES_PASSWORD (openssl rand -base64 24)
docker compose up -d
docker compose logs -f
```

The same password goes into `/etc/atlas/atlas.env`. The compose project is
named `atlas-backend`, so the data volume is `atlas-backend_pgdata`.

## Migrations

[`migrations/`](migrations/) is compiled into the binaries and applied by
`atlas-server` on start (or `atlas-server migrate`), under an advisory lock so
two processes never migrate at once. A migration is one SQL file plus one line
in `MIGRATIONS` in [`crates/core/src/db.rs`](../crates/core/src/db.rs).

| File | |
|---|---|
| `0007_baseline.sql` | the schema as it stood before the unified server (versions 1 to 7 folded into one) |
| `0008_unified.sql` | thumbhash and rendition columns, `NOTIFY` triggers on assets, jobs and embeddings |
| `0009_shares.sql` | the `shares` table: links shared through [atlas-share](../share/) |
| `0010_share_live.sql` | one link per album, its password kept for the link's lifetime, the `live` flag |
| `0011_perf.sql` | row-level `NOTIFY` triggers for the timeline cache, thumbnail recipe version, job healing columns (`defers`, `heals`, `stuck_at`) |
| `0012_wemm.sql` | the switch to WeMM-Embedding-2B: old vectors dropped, every asset queued to be embedded again |
| `0013_vision.sql` | the vision stage: animals next to people (`kind`, `look`), faces from video frames, text read off photos (`asset_text`) |
| `0014_hidden.sql` | `persons.hidden`: people kept out of People and search |
| `0015_clarity.sql` | `faces.clarity`: how recognizable a face is |
| `0016_vetoes.sql` | `faces.vetoed`: the people a face must never be assigned to again |

## Backups

[`scripts/pg-backup/`](../scripts/pg-backup/) dumps the database nightly and
ships a restore drill. The database is the only copy of albums, people and
names; the files themselves live under `ATLAS_PHOTOS_DIR` and
`ATLAS_DRIVE_DIR`.
