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

## Backups

[`scripts/pg-backup/`](../scripts/pg-backup/) dumps the database nightly and
ships a restore drill. The database is the only copy of albums, people and
names; the files themselves live under `ATLAS_PHOTOS_DIR` and
`ATLAS_DRIVE_DIR`.
