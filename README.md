# atlas — the monorepo

Everything that runs on or controls **atlas**, Luka's homelab server
(NZXT box · i7-12700K · 31 GB RAM · RTX 4060 Ti 8 GB · 936 GB NVMe ·
Ubuntu Server 26.04, headless, on-demand via Wake-on-LAN).

```
cli/          Rust CLI on the Mac:  atlas | boot | shutdown | restart | status
              | build | dev | agent | <any remote cmd>
agent/        atlas-agent (Rust, systemd :8787): metrics, WS PTY terminal,
              docker inspect, lightshow/fog/manual-light control, calibration,
              exit-node/VPN stats, activity history, ingest hooks
builder/      pinned Docker build images: lambda (Rust→Graviton via Zig),
              node (Next.js + cloudflared), flutter (Android SDK)
backend/      THE data foundation: postgres:17 + pgvector in Docker —
              media library, knowledge-graph (nodes=domain tables, edges),
              Qwen3-VL embeddings, resumable ingest queue  → backend/README.md
apps/
  atlas-admin/      iOS app "Atlas" (SwiftUI, iOS 26 Liquid Glass): dashboard,
                    real terminal, docker, exit-node/VPN stats page,
                    GitHub-style activity heatmap
  atlas-lightshow/  iOS app "Lightshow": shows + AI-show creation, manual
                    per-light control, fail-safe hold-to-fog, calibration
  atlas-photos/     self-built Google Photos (server: Rust/axum · ios: SwiftUI)
lightshows/   the full lightshow production system (merged with history):
              GPU song analysis, v6 dark-gap compiler, Gemini+Claude AI
              composer, Art-Net→Hue bridge, fog hardware  → lightshows/README.md
```

## The machine

| | |
|---|---|
| SSH | `ssh atlas` → tailnet `atlas.your-tailnet.ts.net` · LAN `192.168.1.100` |
| Power | `atlas boot` (WoL, LAN) / MyFRITZ wake (remote) · `atlas shutdown` |
| Stack | NVIDIA 595 + CUDA 13.3 · Docker + NVIDIA CT · Tailscale · Claude Code + Gemini auth |
| Layout on atlas | this repo at `~/atlas` · app repos at `~/projects` · data staging `~/takeout` |

## Quickstart

```bash
cargo install --path cli            # the `atlas` command (Mac)
atlas boot && atlas agent           # wake + metrics/terminal server
cd backend/docker && docker compose up -d   # the database (on atlas)
```

Per-area docs: [cli](cli/README.md) · [agent](agent/README.md) ·
[backend](backend/README.md) ·
[atlas-admin](apps/atlas-admin/README.md) ·
[atlas-photos](apps/atlas-photos/README.md) ·
[lightshows](lightshows/README.md)
