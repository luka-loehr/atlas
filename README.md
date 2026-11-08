![Atlas Banner](.github/assets/banner.png)

# Atlas – Your photos and files on your own server

[![Rust](https://img.shields.io/badge/Rust-server%20%26%20CLI-DEA584?style=flat&logo=rust&logoColor=white)](https://www.rust-lang.org) [![Swift](https://img.shields.io/badge/SwiftUI-iOS%20%26%20Mac%20app-F05138?style=flat&logo=swift&logoColor=white)](https://developer.apple.com/swiftui/) [![Postgres](https://img.shields.io/badge/Postgres%2017-pgvector-4169E1?style=flat&logo=postgresql&logoColor=white)](https://github.com/pgvector/pgvector) [![Platform](https://img.shields.io/badge/Platform-Ubuntu%20%7C%20macOS%20%7C%20iOS-lightgrey?style=flat)](docs/SETUP.md) [![License](https://img.shields.io/badge/License-MIT-orange?style=flat)](LICENSE)

**Atlas** is a self-hosted photo library and drive for a single home server, with one app for iPhone, iPad and Mac in front of it. The backend is Rust end to end; it runs on your own hardware and is reached over a Tailscale tailnet.

---

## Features

- **Photo library** timeline of every photo and video, albums, people, places, favorites, archive, a locked album and a trash
- **Search that understands you** "alex and sam at the beach", "rex in spain", "summer 2024 videos": names, pets, places, dates and video are read as filters, and the rest ranks by what the photos show and what text is in them
- **Faces, pets and text** every photo at full resolution and about one frame a second of every video: all the faces of a group photo, dogs and cats told apart individually, and every sign, screenshot and document made searchable; people and pets you can name, merge and hide
- **Backup** the iPhone uploads originals, deduplicated by content hash, and can clear backed-up items off the phone
- **Share links** albums or a few photos as a link (optional password), served from your own Cloudflare account so links work while the server sleeps, and gone after 7 days at the latest
- **Drive** folders over content-addressed files, with previews, full-text search and a trash
- **One app, native everywhere** one SwiftUI codebase: the iPhone app (library, albums, files, settings) and a true Mac app with a sidebar, menu bar commands, an inspector and drag and drop with the Finder; both with live server status, power control and a terminal
- **Built to feel instant** precomputed and compressed timeline, every grid drawn from small tiles kept on the device (no blank cells at any scroll speed), immutable media URLs, streaming uploads, video renditions on the GPU
- **Your GPU, safely shared** the vision models work within the card's memory less what search needs, and fall back to the CPU instead of ever running out
- **agentbrain sync** keep a copy of your agents' agentbrain memories on your server: every memory and version, hourly, verified and versioned ([setup](scripts/agentbrain-backup/README.md))
- **Wake-on-LAN CLI** `atlas boot` wakes the server, `atlas deploy` installs the services, `atlas build` and `atlas dev` build other projects on it
- **Tailnet-first security** one port, firewalled to loopback and the tailnet, one bearer token on every route

---

## Quick start

```bash
# Mac: install the CLI, then configure your machine values (see docs/SETUP.md)
cargo install --path crates/cli
mkdir -p ~/.config/atlas && $EDITOR ~/.config/atlas/env

atlas boot        # wake the server (Wake-on-LAN)

# Server: database, models, configuration
cd ~/atlas/db && cp .env.example .env && docker compose up -d
~/atlas/scripts/atlas/models.sh
sudo install -m600 ~/atlas/scripts/atlas/atlas.env.example /etc/atlas/atlas.env

# Mac again
atlas deploy      # build + install atlas-server and atlas-ml
atlas connect     # the link that connects the app
```

---

## Documentation

- [Overview](docs/OVERVIEW.md): repository layout, architecture, security
- [Setup](docs/SETUP.md): from-scratch machine setup (Ubuntu, Tailscale, Wake-on-LAN, GPU, models, the app)
- Components: [server](crates/server/README.md) · [ml](crates/ml/README.md) · [cli](crates/cli/README.md) · [app](app/README.md) · [db](db/README.md) · [builder](builder/README.md) · [scripts](scripts/README.md)

---

## License

MIT License - [View License](LICENSE)  
Model weights downloaded at setup keep their own licenses: WeMM-Embedding-2B, RF-DETR, pet-recognition-large and PP-OCRv6 under Apache-2.0; InsightFace's SCRFD (`buffalo_l`) and AdaFace's WebFace12M weights for non-commercial research. The Inter font in `crates/server/assets/fonts` is under the SIL Open Font License.

---

## Support

- [Report bugs](https://github.com/luka-loehr/atlas/issues)  
- [luka@lukaloehr.com](mailto:luka@lukaloehr.com)  

---

Developed by [Luka Löhr](https://github.com/luka-loehr)
