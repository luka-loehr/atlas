![Atlas Banner](.github/assets/banner.png)

# Atlas — a self-hosted homelab platform

[![Rust](https://img.shields.io/badge/Rust-server%20%26%20CLI-DEA584?style=flat&logo=rust&logoColor=white)](https://www.rust-lang.org)
[![Swift](https://img.shields.io/badge/SwiftUI-3%20iOS%20apps-F05138?style=flat&logo=swift&logoColor=white)](https://developer.apple.com/swiftui/)
[![Python](https://img.shields.io/badge/Python-AI%20pipeline-3776AB?style=flat&logo=python&logoColor=white)](https://www.python.org)
[![Postgres](https://img.shields.io/badge/Postgres%2017-pgvector-4169E1?style=flat&logo=postgresql&logoColor=white)](https://github.com/pgvector/pgvector)
[![License](https://img.shields.io/badge/License-MIT-green?style=flat)](LICENSE)

**Atlas** is everything that runs on or controls a single headless home server:
a Wake-on-LAN Rust CLI for the Mac, a lightweight control-plane API with a real
terminal in your pocket, a self-built Google Photos + Drive replacement with
local AI search, a music-synced light-show system driving Philips Hue over
Art-Net, and a remote build & dev platform that runs any repo's builds on the
server — with dev servers at stable public URLs when you want them. No cloud
lock-in, no subscriptions — your hardware, your tailnet, your data.

> **Status: v0.0.1 — beta, proof of concept.** This is one person's real
> homelab, published as-is. Everything in the repo runs daily on the
> author's hardware, but it is a first release: interfaces may change
> without notice, and sharp edges exist.

---

## What's inside

| Directory | What it is |
|---|---|
| [`cli/`](cli/) | Rust CLI for the Mac: `atlas` \| `boot` (Wake-on-LAN) \| `shutdown` \| `restart` \| `status` \| `build` \| `dev` \| `test` \| `run` \| `secrets` \| `api` \| `doctor` \| `ls` \| `logs` \| any remote command — full table in [cli/README.md](cli/README.md) |
| [`api/`](api/) | `atlas-api` — Rust control-plane server (port 8787): metrics, WebSocket PTY terminal, Docker overview, power control, light-show & fog control |
| [`backend/`](backend/) | The data foundation: Postgres 17 + pgvector in Docker — media library, knowledge graph, embeddings, resumable ingest queue |
| [`infra/`](infra/) | Machine-level services that are not part of an app: [AdGuard Home](infra/adguard/), the tailnet's DNS resolver |
| [`apps/`](apps/) | The three SwiftUI iOS apps, one directory each — app sources, and for Photos the server and AI pipeline that back it |
| [`apps/atlas-admin/`](apps/atlas-admin/) | iOS app **Atlas Admin** (SwiftUI): dashboard, real terminal, Docker, VPN/exit-node stats, activity heatmap |
| [`apps/atlas-lightshow/`](apps/atlas-lightshow/) | iOS app **Atlas Lightshow**: play shows, AI show creation, manual per-light control, hold-to-fog |
| [`apps/atlas-photos/`](apps/atlas-photos/) | iOS app **Atlas Photos**: self-hosted Google Photos + Drive — Rust/axum server, SwiftUI client, GPU AI pipeline (faces, semantic photo *and* video search) |
| [`lightshows/`](lightshows/) | Show production: GPU song analysis, dark-gap compiler, AI composer, Art-Net→Hue bridge, fog hardware |
| [`builder/`](builder/) | The remote build images `atlas build` / `atlas dev` run in: one [universal Dockerfile](builder/universal/Dockerfile) with three targets (`build`, `dev`, `mobile`), base-pinned |
| [`proxy/`](proxy/) | Base configs for the dev-subdomain proxy — the host Caddy + named Cloudflare Tunnel behind `atlas dev --public`'s stable `*.your-domain.com` URLs; installed by [`scripts/proxy/`](scripts/proxy/) |
| [`scripts/`](scripts/) | Everything that keeps the box alive: [health check](scripts/healthcheck/), [firewall](scripts/firewall/), [disk guard](scripts/disk-guard/), [Postgres backups](scripts/pg-backup/), [tailnet DNS failover](scripts/tailnet-dns/), [power oneshots](scripts/power/), [power-button gesture](scripts/power-button/), [dev-subdomain proxy](scripts/proxy/), [CI-runner recorder](scripts/ci-health/), plus Takeout transfer, photo triage UI and embedding-space maps |
| [`docs/`](docs/) | [SETUP.md](docs/SETUP.md) — the from-scratch machine-level guide everything else builds on |
| [`.github/`](.github/) | Repo assets (the banner above) |

## Highlights

- **One command from asleep to shell** — `atlas boot` sends the Wake-on-LAN
  packet, waits for SSH, and drops you in. `atlas shutdown` puts the box back
  to sleep. Idle power is ~0 W because the server only runs when you need it.
- **Your photos, actually yours** — Takeout in, originals content-addressed on
  your disk, thumbnails, EXIF, faces, and 2048-d embeddings for semantic
  search over photos *and* videos. The iOS app does albums, favorites, backup,
  and natural-language search.
- **A terminal in your pocket** — the admin app speaks to the API server's
  WebSocket PTY: a real shell on the server, from the couch.
- **Light shows from a song file** — analysis extracts beats, energy and
  structure; the compiler builds a choreography; the bridge streams it to Hue
  lamps over Art-Net, beat-accurate, with fog.
- **Build on the server, not the laptop** — `atlas build` ships the working
  tree or a repo to the box and builds it in a pinned universal image;
  `atlas dev` serves it back over the tailnet, or publicly at a stable
  `https://<name>.your-domain.com` subdomain — any domain on your own
  Cloudflare account — through a named Cloudflare Tunnel.
- **Tailnet-first security** — nothing is port-forwarded to the internet. The
  two HTTP services are firewalled to loopback + tailnet by nftables and take a
  bearer token on top; the rest are confined by the address they bind. sshd and
  Art-Net are the deliberate exceptions and stay LAN-reachable, and
  `atlas dev --public` is the deliberate internet path — an *outbound* tunnel,
  not an open port ([security model](docs/SETUP.md#security-model) says which
  is which).

## Quickstart

```bash
# Mac: install the CLI, then configure your machine values
cargo install --path cli
mkdir -p ~/.config/atlas && $EDITOR ~/.config/atlas/env   # see docs/SETUP.md

atlas boot        # wake the server (Wake-on-LAN)
atlas api         # build + install the control-plane API
atlas status      # LAN / tailnet reachability

# Server: the database
cd backend/docker && cp .env.example .env && docker compose up -d
```

Full from-scratch setup — hardware, Ubuntu, Tailscale/tailnet, Wake-on-LAN,
CUDA, models, iOS builds: **[docs/SETUP.md](docs/SETUP.md)**

## Architecture

```
 Mac ──ssh/WoL──▶ ┌──────────────── server ────────────────┐
 (cli)            │ atlas-api   :8787   photos server :8788│
                  │ Postgres 17 + pgvector (Docker)        │
 iPhone ─tailnet─▶│ GPU pipeline (faces, embeddings)       │
 (3 SwiftUI apps) │ Art-Net→Hue bridge :6454 ──▶ 💡 lights │
 Internet ───CF──▶│ Caddy :8080 ← Cloudflare Tunnel (dev)  │
                  └────────────────────────────────────────┘
```

Everything meets on your private tailnet — except `atlas dev --public` URLs,
which ride an outbound Cloudflare Tunnel; the server sleeps until woken.

## Per-area docs

[cli](cli/README.md) ·
[api](api/README.md) ·
[backend](backend/README.md) ·
[infra/adguard](infra/adguard/README.md) ·
[builder](builder/README.md) ·
[atlas-admin](apps/atlas-admin/README.md) ·
[atlas-lightshow](apps/atlas-lightshow/README.md) ·
[atlas-photos](apps/atlas-photos/README.md) ·
[lightshows](lightshows/README.md) ·
[scripts](scripts/README.md)

> **Note:** docs and the CLI are English; the iOS app UIs are German (the
> author's daily drivers). Contributions translating them are welcome.

## License

[MIT](LICENSE) — use it, fork it, build your own.

The MIT license covers the code in this repository. Model weights downloaded
at runtime (e.g. InsightFace `buffalo_l`, non-commercial research license)
keep their own licenses.

## Support

- [Report an issue](https://github.com/luka-loehr/atlas/issues)
- [luka@lukaloehr.com](mailto:luka@lukaloehr.com)

---

Developed by [Luka Löhr](https://github.com/luka-loehr)
