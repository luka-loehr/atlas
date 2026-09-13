![Atlas Banner](.github/assets/banner.png)

# Atlas – Self-hosted homelab platform

[![Rust](https://img.shields.io/badge/Rust-server%20%26%20CLI-DEA584?style=flat&logo=rust&logoColor=white)](https://www.rust-lang.org) [![Swift](https://img.shields.io/badge/SwiftUI-3%20iOS%20apps-F05138?style=flat&logo=swift&logoColor=white)](https://developer.apple.com/swiftui/) [![Python](https://img.shields.io/badge/Python-AI%20pipeline-3776AB?style=flat&logo=python&logoColor=white)](https://www.python.org) [![Postgres](https://img.shields.io/badge/Postgres%2017-pgvector-4169E1?style=flat&logo=postgresql&logoColor=white)](https://github.com/pgvector/pgvector) [![Platform](https://img.shields.io/badge/Platform-Ubuntu%20%7C%20macOS%20%7C%20iOS-lightgrey?style=flat)](docs/SETUP.md) [![License](https://img.shields.io/badge/License-MIT-orange?style=flat)](LICENSE)

**Atlas** is the software for a single headless home server: a Wake-on-LAN CLI, a control-plane API, a self-hosted photo and file library with local AI search, a Philips Hue light-show system and a remote build platform. It runs on your own hardware and is reached over a Tailscale tailnet.

---

## Features

- **Wake-on-LAN CLI** `atlas boot` wakes the server and opens a shell, `atlas shutdown` puts it back to sleep
- **Control-plane API** Rust server with live metrics, Docker overview, power control and a WebSocket PTY terminal
- **Atlas Photos** self-hosted photo and file library with faces and semantic search over photos and videos
- **Light shows** song analysis, choreography compiler and an Art-Net to Hue bridge with fog control
- **Remote builds** `atlas build` and `atlas dev` build in a pinned Docker image on the server, optionally served through a Cloudflare Tunnel
- **iOS apps** SwiftUI apps for administration, light shows and photos
- **Tailnet-first security** HTTP services are firewalled to loopback and the tailnet and require a bearer token

---

## Quick start

```bash
# Mac: install the CLI, then configure your machine values (see docs/SETUP.md)
cargo install --path cli
mkdir -p ~/.config/atlas && $EDITOR ~/.config/atlas/env

atlas boot        # wake the server (Wake-on-LAN)
atlas api         # build + install the control-plane API
atlas status      # LAN / tailnet reachability

# Server: the database
cd backend/docker && cp .env.example .env && docker compose up -d
```

---

## Documentation

- [Overview](docs/OVERVIEW.md): repository layout, architecture, security, status
- [Setup](docs/SETUP.md): from-scratch machine setup (Ubuntu, Tailscale, Wake-on-LAN, CUDA, models, iOS builds)
- Components: [cli](cli/README.md) · [api](api/README.md) · [backend](backend/README.md) · [infra/adguard](infra/adguard/README.md) · [builder](builder/README.md) · [lightshows](lightshows/README.md) · [scripts](scripts/README.md)
- iOS apps: [atlas-admin](apps/atlas-admin/README.md) · [atlas-lightshow](apps/atlas-lightshow/README.md) · [atlas-photos](apps/atlas-photos/README.md)

---

## License

MIT License - [View License](LICENSE)  
Model weights downloaded at runtime (e.g. InsightFace `buffalo_l`, non-commercial research license) keep their own licenses.

---

## Support

- [Report bugs](https://github.com/luka-loehr/atlas/issues)  
- [luka@lukaloehr.com](mailto:luka@lukaloehr.com)  

---

Developed by [Luka Löhr](https://github.com/luka-loehr)
