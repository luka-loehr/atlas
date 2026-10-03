# Overview

> **Status: v0.1.0, beta.** This is one person's homelab, published as-is.
> Everything in the repo runs daily on the author's hardware, but interfaces
> may change without notice.

## What's inside

| Directory | What it is |
|---|---|
| [`crates/server/`](../crates/server/) | `atlas-server`: the whole backend in one process. The HTTP API on :8787 (photos, drive, system) and the ingest workers (thumbnails, metadata, geocoding, drive text, video renditions) |
| [`crates/ml/`](../crates/ml/) | `atlas-ml`: the model worker. Semantic embeddings through llama.cpp, faces on ONNX Runtime |
| [`crates/core/`](../crates/core/) | What the two share: database setup, migrations, the job queue protocol |
| [`crates/cli/`](../crates/cli/) | `atlas`, the CLI for the Mac: `boot` (Wake-on-LAN) \| `shutdown` \| `status` \| `deploy` \| `connect` \| `build` \| `dev` \| `secrets` \| any remote command. Full table in its [README](../crates/cli/README.md) |
| [`app/`](../app/) | **Atlas**, the iOS app (SwiftUI): Fotos, Alben, Dateien, Einstellungen, search |
| [`db/`](../db/) | Postgres 17 + pgvector in Docker, and the schema migrations |
| [`builder/`](../builder/) | The images `atlas build` / `atlas dev` run in: one [universal Dockerfile](../builder/universal/Dockerfile) with three targets (`build`, `dev`, `mobile`), base-pinned |
| [`proxy/`](../proxy/) | Base configs for the dev-subdomain proxy (host Caddy + named Cloudflare Tunnel) behind `atlas dev --public` URLs; installed by [`scripts/proxy/`](../scripts/proxy/) |
| [`scripts/`](../scripts/) | The service units and their installer ([`atlas/`](../scripts/atlas/)), and server upkeep: [health check](../scripts/healthcheck/), [firewall](../scripts/firewall/), [disk guard](../scripts/disk-guard/), [Postgres backups](../scripts/pg-backup/), [power oneshots](../scripts/power/), [power-button gesture](../scripts/power-button/), [dev-subdomain proxy](../scripts/proxy/), [CI-runner recorder](../scripts/ci-health/) |
| [`docs/`](.) | [SETUP.md](SETUP.md), the from-scratch guide, and the [design reference](apple-design-guidelines.md) the app is built against |

## Architecture

```
 Mac ──ssh/WoL──▶ ┌──────────────── server ─────────────────┐
 (cli)            │ atlas-server :8787  API + ingest workers │
                  │      │  ▲                                │
 iPhone ─tailnet─▶│      ▼  │ jobs, vectors                  │
 (Atlas app)      │ Postgres 17 + pgvector (Docker)          │
                  │      ▲                                   │
                  │ atlas-ml :8786  embeddings, faces (GPU)  │
 Internet ───CF──▶│ Caddy :8080 ← Cloudflare Tunnel (dev)    │
                  └──────────────────────────────────────────┘
```

Everything meets on your private tailnet, except `atlas dev --public` URLs,
which use an outbound Cloudflare Tunnel. The server sleeps until woken.

## How it stays fast

- **The timeline is precomputed.** The server holds every month of the
  library as a ready-to-send gzip body with a validator. The app lays out the
  whole grid from a 6 KB index and keeps months on disk; a refresh fetches
  only months whose validator changed, and an unchanged one costs a 304.
- **Media URLs are immutable.** Assets are addressed by the SHA-256 of their
  bytes, so thumbnails and originals are cached forever and never revalidated.
- **Search is an exact scan in memory.** Every asset vector sits in one
  contiguous matrix in the server; a query is embedded on the GPU (about
  15 ms) and compared against all of them (a few ms), with no approximate
  index and no recall gap.
- **Uploads stream.** A body is hashed while it is written to disk; a
  multi-gigabyte video costs one buffer of memory on either side.
- **Work is queued, not awaited.** An upload returns as soon as the bytes are
  safe; thumbnails, metadata, places, embeddings, faces and video renditions
  follow from a crash-safe queue in Postgres (`FOR UPDATE SKIP LOCKED`,
  heartbeats, backoff).
- **Large videos get a streaming rendition** (1080p HEVC, encoded on the GPU
  where there is one), so a 4K recording starts instantly over a home uplink.

## Security

Nothing is port-forwarded to the internet. The one HTTP service is firewalled
to loopback + tailnet by nftables and takes a bearer token on every route
except `/health`; everything else is confined by the address it binds.
`atlas dev --public` is the deliberate internet path: an outbound tunnel, not
an open port. Details: [SETUP.md, security model](SETUP.md#security-model).

## Language

Docs and the CLI are English; the app's UI is German.

## Systemd units

Units under `scripts/` ship with the placeholder `SET-BY-INSTALLER` for the
account and home directory. The `install.sh` scripts (via
[`scripts/lib/install-unit.sh`](../scripts/lib/install-unit.sh)) replace it
with the installing user and `$HOME`, and expect the repo at `~/atlas`. If you
copy a unit by hand, replace it yourself.
