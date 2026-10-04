# Setup — from zero to a running atlas

This is the complete from-scratch guide for running the atlas platform on
your own hardware: one headless Linux server, a Mac as the control machine,
and an iPhone for the app. It covers everything below the individual
subsystems — OS, network, Wake-on-LAN, GPU, Docker, Tailscale — and then
walks through bringing up each subsystem in dependency order.
Subsystem internals live in the per-directory READMEs, linked throughout.

Placeholders used in every example — replace with your values:
`atlas.your-tailnet.ts.net` (tailnet hostname), `192.168.1.100` (server LAN
IP), `aa:bb:cc:dd:ee:ff` (server NIC MAC), `atlas` (server username, home
`/home/atlas`).

## 1. What you need

| Component | Required for | Notes |
|---|---|---|
| x86 server | everything | Any always-available box; idle power is irrelevant because the platform is designed to sleep (Wake-on-LAN). Ethernet strongly recommended — WoL over Wi-Fi is unreliable to nonexistent. |
| NVIDIA GPU in the server | fast semantic search and indexing (the embedding model) | Everything else — Postgres, the server, thumbnails, faces — runs fine without one, and the embedding model falls back to the CPU (`ATLAS_EMBED_GPU_LAYERS=0`), just slowly. 6 GB VRAM is enough. With a GPU, large videos also get their streaming renditions through NVENC. |
| Mac | the `atlas` CLI, building the iOS app | The CLI is Unix-only; any Linux workstation works for the CLI, but the iOS app needs Xcode. |
| iPhone | the Atlas app (photos, albums, files, settings) | iOS 26.1 or later; a free or paid Apple Developer team for device signing. |

## 2. Server preparation (Ubuntu Server)

Install a current Ubuntu Server (22.04 LTS or newer; everything is systemd +
netplan). During install, create the service user (examples here use `atlas`)
and enable OpenSSH.

### SSH

Copy your key and confirm non-interactive login works — the CLI, rsync and
`atlas deploy` all depend on it:

```bash
ssh-copy-id atlas@192.168.1.100
ssh atlas@192.168.1.100 true && echo ok
```

### Static DHCP lease

Give the server a fixed LAN IP via a static DHCP lease (router config, keyed
on the NIC MAC). The CLI probes `ATLAS_LAN_ADDR` and sends the WoL packet to
the LAN broadcast — both assume the address never moves.

### Wake-on-LAN

Two switches, both required:

1. **Firmware:** enable Wake-on-LAN in the BIOS/UEFI (often "Power On By
   PCI-E/PCI", "Resume by LAN"). If your board has an ErP/EuP "deep sleep"
   mode, disable it — it cuts standby power to the NIC.
2. **OS:** the NIC must have wake mode `g` (MagicPacket). Check and set:

   ```bash
   sudo ethtool eno1 | grep Wake-on     # d = off, g = MagicPacket
   sudo ethtool -s eno1 wol g
   ```

   Make it persist across reboots via netplan (Ubuntu Server uses
   systemd-networkd; add `wakeonlan: true` to your ethernet):

   ```yaml
   # /etc/netplan/01-netcfg.yaml (adjust to your existing file)
   network:
     version: 2
     ethernets:
       eno1:
         dhcp4: true
         wakeonlan: true
   ```

   ```bash
   sudo netplan apply
   ```

Test the full loop from the Mac after section 4: `atlas shutdown`, then
`atlas boot`. WoL only works from inside the LAN; from elsewhere, wake the
box through your router's remote-access feature and then connect over the
tailnet.

### Docker

Docker Engine with Compose v2, and the service user in the `docker` group:

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker atlas          # re-login afterwards
sudo systemctl enable docker           # containers autostart after boot/WoL
```

### NVIDIA driver and CUDA toolkit (optional)

atlas-ml runs the embedding model through llama.cpp, which
[`scripts/atlas/models.sh`](../scripts/atlas/models.sh) builds with CUDA when
the toolkit is installed and for the CPU otherwise:

```bash
sudo ubuntu-drivers install            # proprietary driver, then reboot
nvidia-smi                             # must list the GPU
sudo apt-get install -y cuda-toolkit   # from NVIDIA's apt repo; provides nvcc
```

### Packages the server needs

```bash
sudo apt-get install -y build-essential cmake pkg-config \
     ffmpeg poppler-utils libheif-dev libheif-plugin-libde265
```

`ffmpeg` makes video posters and streaming renditions, `poppler-utils` reads
PDF text and renders PDF previews for the drive, and libheif decodes the HEIC
photos an iPhone takes.

### Rust toolchain, repo clone, sudoers

```bash
# Rust (>= 1.88: edition 2024, let chains)
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh

# the repo — several defaults assume this exact path
git clone https://github.com/your-fork/atlas.git ~/atlas
```

The clone at `~/atlas` matters: `atlas deploy` resets it to `origin/main` and
builds from it, `atlas build` builds its Docker builder images from it, and
the database password is read from `~/atlas/db/.env` by default.

Passwordless sudo: the server's power endpoints and `atlas
shutdown/restart` need `systemctl poweroff` and `systemctl reboot`;
`atlas deploy` additionally uses `systemctl`, `install` and `tee`
non-interactively, `atlas build` uses `chown`, and `atlas dev` uses
`tailscale serve`. Minimal power-only rule:

```
# /etc/sudoers.d/atlas  (visudo -f)
atlas ALL=(root) NOPASSWD: /usr/bin/systemctl poweroff, /usr/bin/systemctl reboot
```

Extend the list (or grant broader NOPASSWD, at your own judgment) if you use
the CLI's installer commands — the exact set is in
[crates/cli/README.md](../crates/cli/README.md#server-prerequisites).

## 3. Tailscale — the network layer

A **tailnet** is the private network Tailscale builds between your devices: a
WireGuard mesh where every logged-in machine gets a stable private IP
(`100.x.y.z`) and, with MagicDNS, a stable name like
`atlas.your-tailnet.ts.net` — reachable from anywhere, with all traffic
end-to-end encrypted. Nothing is exposed to the public internet; devices see
each other only if they are in the same tailnet.

Install on all three devices and log into the same account:

```bash
# server
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
tailscale status
```

- **Mac:** Tailscale from the App Store or `brew install --cask tailscale`.
- **iPhone:** Tailscale from the App Store — required for the Atlas app
  when you are not on the home LAN.

Enable **MagicDNS** in the Tailscale admin console so
`atlas.your-tailnet.ts.net` resolves everywhere.

Recommended `~/.ssh/config` on the Mac — everything in this repo (CLI,
rsync scripts, light-show tooling) uses the host alias `atlas`:

```
Host atlas
    HostName atlas.your-tailnet.ts.net
    User atlas
```

If you want big transfers (Takeout parts) to take the direct gigabit path at
home, add a second alias pointing at the LAN IP and pass it via
`ATLAS_SSH_HOST` where needed.

### Security model

The rule is **never port-forward any of this to the internet**. The one
deliberate internet-facing path is `atlas dev --public` (section 8): an
*outbound* Cloudflare Tunnel that publishes a chosen dev container at
`<name>.your-domain.com` — nothing is forwarded on the router for it either.
Inside that, confinement is per service. There is no TLS on the service
itself: WireGuard encrypts the path inside the tailnet.

| Port | Service | Binds | Auth |
|---|---|---|---|
| 22/tcp | sshd | all — **not** in the firewall table | SSH keys |
| 5432/tcp | Postgres | `127.0.0.1` only | password (loopback only — remote dev via SSH tunnel) |
| 8787/tcp | atlas-server | `0.0.0.0` (configurable), firewalled to lo + tailnet | `ATLAS_TOKEN` on every route except `/health` |
| 8786/tcp | atlas-ml | `127.0.0.1` only | none (loopback only; only atlas-server talks to it) |
| 8785/tcp | llama.cpp server (child of atlas-ml) | `127.0.0.1` only | none (loopback only) |
| 8080/tcp | host Caddy (dev-subdomain proxy, section 8) | all — **not** in the firewall table | none — serves only the per-Host routes `atlas dev --public` adds, so without a matching `<name>.your-domain.com` Host header it answers nothing |
| 2019/tcp | Caddy admin API | `localhost` only | none (loopback only — `atlas dev` mutates it over ssh) |

**`ATLAS_TOKEN`** is the one credential of the API: photos, files, machine
status, the power buttons and a shell on the machine all sit behind it, and
the server refuses to start without one. Generate it with
`openssl rand -hex 32`; the app keeps it in the iPhone's keychain.

The token is not the whole story, because one of the routes behind it is a
terminal. The host firewall keeps the port off the LAN altogether:

```bash
scripts/firewall/install.sh
```

It drops tcp/8787 on every interface except `lo` and `tailscale0`, for IPv4
and IPv6 alike, and reloads at boot from `atlas-firewall.service`. Details and
the reasoning for the separate nftables table are in
`scripts/firewall/README.md`. Verify with:

```bash
sudo nft -a list table inet atlas-fw     # per-rule counters show what got dropped
```

## 4. Mac: the `atlas` CLI

```bash
cd ~/atlas          # your clone, on the Mac
# Rust toolchain, if you don't have one: https://rustup.rs (or `brew install rustup`)
cargo install --path crates/cli        # installs `atlas` into ~/.cargo/bin
```

Configuration lives in `~/.config/atlas/env` (plain `KEY=VALUE`, `#`
comments; real environment variables override the file). Complete example
with every variable the CLI reads:

```bash
mkdir -p ~/.config/atlas
cat > ~/.config/atlas/env <<'EOF'
# ssh/rsync host — an alias from ~/.ssh/config
ATLAS_SSH_HOST=atlas
# reachability probes, host:port ("" disables a route)
ATLAS_LAN_ADDR=192.168.1.100:22
ATLAS_TAILNET_ADDR=atlas.your-tailnet.ts.net:22
# Wake-on-LAN: the server NIC's MAC + LAN broadcast address
ATLAS_WOL_MAC=aa:bb:cc:dd:ee:ff
ATLAS_WOL_BROADCAST=192.168.1.255:9
# atlas-server host:port (defaults to the tailnet host + :8787).
ATLAS_SERVER_URL=atlas.your-tailnet.ts.net:8787
# Your Cloudflare-managed domain for `atlas dev --public` URLs
# (<name>.<domain>). Leave unset for tailnet-only dev; section 8 has the
# one-time server-side bring-up.
#ATLAS_DEV_DOMAIN=your-domain.com
EOF
```

Smoke test:

```bash
atlas status      # up/down + route
atlas shutdown && atlas boot     # full WoL round-trip (from inside the LAN)
atlas nvidia-smi  # any command runs remotely
```

Commands, remote builds (`atlas build` / `atlas dev`) and the builder images:
[crates/cli/README.md](../crates/cli/README.md).

## 5. Database

One Postgres 17 with pgvector holds everything: the media library, the
drive, the graph that links them, and every vector.

```bash
cd ~/atlas/db
cp .env.example .env && $EDITOR .env      # POSTGRES_PASSWORD
docker compose up -d
docker compose ps                         # atlas-postgres ... healthy
```

There is no schema step: atlas-server brings the schema up to date when it
starts (`atlas-server migrate` does only that). The migrations are in
[`db/migrations`](../db/migrations) and are compiled into the binary.

The compose project is named explicitly (`atlas-backend`), so the data volume
is `atlas-backend_pgdata` wherever the file lives, and the image is pinned by
tag **and** digest. Nightly dumps with retention and a restore drill:
[`scripts/pg-backup`](../scripts/pg-backup/).

## 6. The Atlas services

Two units, one installer:

- **atlas-server** — the API on :8787 (photos, drive, system) and the ingest
  workers: thumbnails, metadata, reverse geocoding, drive text, video
  renditions.
- **atlas-ml** — the model worker: semantic embeddings and faces.

### 6.1 Models

```bash
~/atlas/scripts/atlas/models.sh
```

builds llama.cpp's server from a pinned commit (with CUDA if `nvcc` is
there) into `/usr/local/lib/atlas/llama-server`, and downloads into
`~/models` (`ATLAS_MODELS_DIR`):

| Model | Size | For |
|---|---|---|
| Qwen3-VL-Embedding-2B, GGUF Q8_0 + vision projector | 2.7 GB | photos, videos and search text in one 2048-d space |
| InsightFace buffalo_l (SCRFD + ArcFace, ONNX) | 190 MB | face detection and recognition — non-commercial research license |

Nothing generative runs anywhere. The embedding model is loaded on first use
and unloaded after ten idle minutes (`ATLAS_ML_IDLE_S`), which returns its
4.5 GB of GPU memory.

### 6.2 Configuration

```bash
sudo install -d /etc/atlas
sudo install -m600 ~/atlas/scripts/atlas/atlas.env.example /etc/atlas/atlas.env
sudoedit /etc/atlas/atlas.env             # ATLAS_TOKEN, POSTGRES_PASSWORD, paths
```

Every variable is documented where it is read:
[`crates/server/src/config.rs`](../crates/server/src/config.rs),
[`crates/ml/src/config.rs`](../crates/ml/src/config.rs) and
[`crates/core/src/db.rs`](../crates/core/src/db.rs). The ones that matter:

| Variable | Default | |
|---|---|---|
| `ATLAS_TOKEN` | — required | the bearer token of every API route |
| `POSTGRES_PASSWORD` | — required | or a full `ATLAS_DATABASE_URL` |
| `ATLAS_PHOTOS_DIR` | `~/photos` | `originals/`, `thumbs/`, `faces/` |
| `ATLAS_DRIVE_DIR` | `~/drive` | `blobs/` |
| `ATLAS_PREVIEWS_DIR` | `<photos>/previews` | streaming renditions of large videos; bulky |
| `ATLAS_MODELS_DIR` | `~/models` | what `models.sh` fills |
| `ATLAS_TZ` | the machine's zone | the timezone photos without their own offset are shown in |

### 6.3 Install

From the Mac, once and after every change:

```bash
atlas deploy                # reset ~/atlas to origin/main, build, install, restart
atlas deploy logs           # journalctl -f of both units
```

or on the server itself: `~/atlas/scripts/atlas/install.sh`. Then:

```bash
curl http://atlas.your-tailnet.ts.net:8787/health          # ok
curl -H "Authorization: Bearer $ATLAS_TOKEN" \
     http://atlas.your-tailnet.ts.net:8787/v1/server        # {"name":"atlas",...}
```

### 6.4 Bringing a library in

A Google Takeout export is read straight out of its archives:

```bash
atlas-server import photos ~/takeout/takeout-*.zip
atlas-server import drive  ~/takeout/drive/*.zip
```

Photos are deduplicated by content (the id of an asset is the SHA-256 of its
bytes, the same id a phone upload gets), sidecar JSON supplies dates, places
and albums, and everything else — thumbnails, metadata, embeddings, faces —
is queued for the workers. Progress is in the app under Einstellungen →
server → Verarbeitung, or in `atlas deploy logs`.

`atlas-server backfill <thumbs|dates|previews|drive-text|embeddings|faces>`
puts a stage back in the queue for assets that lack its result.

## 7. The iOS app

```bash
cd ~/atlas/app
xcodegen generate
xcodebuild -project Atlas.xcodeproj -scheme Atlas \
  -destination 'platform=iOS,name=<your iPhone>' \
  -allowProvisioningUpdates DEVELOPMENT_TEAM=<your team id> build
xcrun devicectl device install app --device <udid> \
  build/Build/Products/Debug-iphoneos/Atlas.app
```

`project.yml` carries the author's bundle id prefix — set your own first. The
iPhone must be on the tailnet. Connect the app in one step:

```bash
atlas connect               # prints an atlas://connect?... link
```

Open the link on the iPhone (or type the address and token on the app's
first screen). Details: [app/README.md](../app/README.md).

## 7b. Share links (optional)

Share links let the app send an album or a few photos to anyone as a link.
The files go to a Cloudflare Worker and R2 bucket on your own Cloudflare
account ([share/](../share/)), so links work while the server is asleep, and
each link expires after 7 days at the latest, which keeps the R2 bill near
zero (10 GB are free). You need a Cloudflare account with R2 enabled once
(dashboard → R2) and Node.js on the Mac. From the checkout:

```bash
atlas share setup     # logs in to Cloudflare, deploys, connects the server
atlas share status    # live? how many links
atlas share ls        # links, progress, time left · atlas share rm <id>
```

Then "Share Link…" appears in album menus and "Share as Link…" for selected
photos in the app. Details in [share/README.md](../share/README.md).

## 8. Dev-subdomain proxy (optional — only for `atlas dev --public`)

`atlas build` / `atlas dev` over the tailnet need nothing beyond the CLI
prerequisites. Publishing a dev server on the internet at a stable
`https://<name>.your-domain.com` URL additionally needs **a domain of your
own on Cloudflare** and the host-side proxy infra: a persistent named
Cloudflare Tunnel plus a host Caddy whose per-Host routes `atlas dev` adds
and removes at runtime.

The domain is fully yours to choose: any registrable domain whose nameservers
point at Cloudflare (the free plan is enough). Tell atlas about it in two
places — `CF_ZONE`/`CF_ZONE_ID` in the server-side token file below (both are
on the zone's Overview page in the Cloudflare dashboard), and
`ATLAS_DEV_DOMAIN=<the same domain>` in `~/.config/atlas/env` on the Mac
(section 4), which is what the CLI builds URLs from. Without
`ATLAS_DEV_DOMAIN`, `atlas dev` is tailnet-only and `--public` exits with the
remediation.

One-time bring-up, fully documented in
[scripts/proxy/README.md](../scripts/proxy/README.md): put a Cloudflare API
token in `~/atlas-secrets/cloudflare.env`, then run
`~/atlas/scripts/proxy/setup.sh` (idempotent — creates or reuses the tunnel,
sets its ingress to Caddy, upserts the wildcard DNS record, arms the
`caddy`/`cloudflared` units). Verify with `atlas doctor` from the Mac, or on
the box:

```bash
systemctl is-active caddy cloudflared
curl -sf localhost:2019/config/ >/dev/null && echo 'caddy admin ok'
```

Steady-state `atlas dev --public` never touches Cloudflare and needs no token.

## 9. Secrets and mutable state live outside the checkout

Files a running service needs are gitignored, so they are invisible to
`git status` and **`git clean -fdx` in the checkout would delete them**. To
stop that, the real files live in `/etc/atlas` and the path inside the working
tree is a symlink; cleaning the tree then removes a link, not the credential.

| Path | Real file | Mode |
|---|---|---|
| — (read by systemd) | `/etc/atlas/atlas.env` | `0600 root:root` |
| `db/.env` (symlink) | `/etc/atlas/backend-postgres.env` | `0600`, owned by the service account |

`atlas.env` is a systemd `EnvironmentFile=`, which systemd reads as root
before dropping privileges, so it can be root-only. The compose file is read
by `docker compose` run as the service account, so that one is owned by it.

## Bring-up checklist

```text
[ ] ssh atlas works with keys, static DHCP lease set
[ ] atlas shutdown && atlas boot round-trips (WoL)
[ ] tailscale status green on server, Mac, iPhone; MagicDNS on
[ ] atlas-postgres up and healthy
[ ] scripts/atlas/models.sh has run; ~/models holds the embedding and face models
[ ] /etc/atlas/atlas.env carries ATLAS_TOKEN and POSTGRES_PASSWORD
[ ] systemctl is-active atlas-server atlas-ml   (both active)
[ ] curl http://atlas.your-tailnet.ts.net:8787/health from the Mac
[ ] scripts/firewall/install.sh has run; nft list table inet atlas-fw shows rules
[ ] the app reaches the server over the tailnet and shows the library
[ ] nothing is port-forwarded on the router
```
