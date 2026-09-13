# Overview

> **Status: v0.0.1, beta, proof of concept.** This is one person's homelab,
> published as-is. Everything in the repo runs daily on the author's hardware,
> but interfaces may change without notice.

## What's inside

| Directory | What it is |
|---|---|
| [`cli/`](../cli/) | Rust CLI for the Mac: `atlas` \| `boot` (Wake-on-LAN) \| `shutdown` \| `restart` \| `status` \| `build` \| `dev` \| `test` \| `run` \| `secrets` \| `api` \| `doctor` \| `ls` \| `logs` \| any remote command. Full table in [cli/README.md](../cli/README.md) |
| [`api/`](../api/) | `atlas-api`, the Rust control-plane server (port 8787): metrics, WebSocket PTY terminal, Docker overview, power control, light-show and fog control |
| [`backend/`](../backend/) | The data foundation: Postgres 17 + pgvector in Docker (media library, knowledge graph, embeddings, resumable ingest queue) |
| [`infra/`](../infra/) | Machine-level services that are not part of an app: [AdGuard Home](../infra/adguard/), the tailnet's DNS resolver |
| [`apps/`](../apps/) | The three SwiftUI iOS apps, one directory each; for Photos also the server and AI pipeline behind it |
| [`apps/atlas-admin/`](../apps/atlas-admin/) | iOS app **Atlas Admin**: dashboard, terminal, Docker, VPN/exit-node stats, activity heatmap |
| [`apps/atlas-lightshow/`](../apps/atlas-lightshow/) | iOS app **Atlas Lightshow**: play shows, AI show creation, manual per-light control, hold-to-fog |
| [`apps/atlas-photos/`](../apps/atlas-photos/) | iOS app **Atlas Photos**: self-hosted photo and file library with a Rust/axum server, SwiftUI client and GPU AI pipeline (faces, semantic photo and video search) |
| [`lightshows/`](../lightshows/) | Show production: GPU song analysis, dark-gap compiler, AI composer, Art-Net to Hue bridge, fog hardware |
| [`builder/`](../builder/) | The images `atlas build` / `atlas dev` run in: one [universal Dockerfile](../builder/universal/Dockerfile) with three targets (`build`, `dev`, `mobile`), base-pinned |
| [`proxy/`](../proxy/) | Base configs for the dev-subdomain proxy (host Caddy + named Cloudflare Tunnel) behind `atlas dev --public` URLs; installed by [`scripts/proxy/`](../scripts/proxy/) |
| [`scripts/`](../scripts/) | Server upkeep: [health check](../scripts/healthcheck/), [firewall](../scripts/firewall/), [disk guard](../scripts/disk-guard/), [Postgres backups](../scripts/pg-backup/), [tailnet DNS failover](../scripts/tailnet-dns/), [power oneshots](../scripts/power/), [power-button gesture](../scripts/power-button/), [dev-subdomain proxy](../scripts/proxy/), [CI-runner recorder](../scripts/ci-health/), plus Takeout transfer, photo triage UI and embedding-space maps |
| [`docs/`](.) | [SETUP.md](SETUP.md), the from-scratch machine-level guide everything else builds on |

## Architecture

```
 Mac ──ssh/WoL──▶ ┌──────────────── server ────────────────┐
 (cli)            │ atlas-api   :8787   photos server :8788│
                  │ Postgres 17 + pgvector (Docker)        │
 iPhone ─tailnet─▶│ GPU pipeline (faces, embeddings)       │
 (3 SwiftUI apps) │ Art-Net→Hue bridge :6454 ──▶ lights    │
 Internet ───CF──▶│ Caddy :8080 ← Cloudflare Tunnel (dev)  │
                  └────────────────────────────────────────┘
```

Everything meets on your private tailnet, except `atlas dev --public` URLs,
which use an outbound Cloudflare Tunnel. The server sleeps until woken.

## Security

Nothing is port-forwarded to the internet. The two HTTP services are
firewalled to loopback + tailnet by nftables and take a bearer token on top
(see [api/README.md](../api/README.md#auth)); the rest are confined by the
address they bind. sshd and Art-Net deliberately stay LAN-reachable, and
`atlas dev --public` is the deliberate internet path: an outbound tunnel, not
an open port. Details: [SETUP.md, security model](SETUP.md#security-model).

## Language

Docs and the CLI are English; the iOS app UIs are German.

## Systemd units

Units under `scripts/` and `lightshows/bridge/` ship with the placeholder
`SET-BY-INSTALLER` for the account and home directory. The `install.sh`
scripts (and [`scripts/lib/install-unit.sh`](../scripts/lib/install-unit.sh)
for hand-installed units) replace it with the installing user and `$HOME`, and
expect the repo at `~/atlas`. If you copy a unit by hand, replace it yourself.
