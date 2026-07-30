# Setup — from zero to a running atlas

This is the complete from-scratch guide for running the atlas platform on
your own hardware: one headless Linux server, a Mac as the control machine,
and optionally an iPhone and a Philips Hue rig. It covers everything below
the individual subsystems — OS, network, Wake-on-LAN, GPU, Docker, Tailscale —
and then walks through bringing up each subsystem in dependency order.
Subsystem internals live in the per-directory READMEs, linked throughout.

Placeholders used in every example — replace with your values:
`atlas.your-tailnet.ts.net` (tailnet hostname), `192.168.1.100` (server LAN
IP), `aa:bb:cc:dd:ee:ff` (server NIC MAC), `atlas` (server username, home
`/home/atlas`).

## 1. What you need

| Component | Required for | Notes |
|---|---|---|
| x86 server | everything | Any always-available box; idle power is irrelevant because the platform is designed to sleep (Wake-on-LAN). Ethernet strongly recommended — WoL over Wi-Fi is unreliable to nonexistent. |
| NVIDIA GPU in the server | photo AI pipeline (`pipeline-gpu`: embeddings, faces, tags) and light-show song analysis | Everything else — Postgres, photo server, the API server, CPU pipeline, show playback — runs fine without one. ≥ 8 GB VRAM recommended for the vLLM caption stage. |
| Mac | the `atlas` CLI, building the iOS apps | The CLI is Unix-only; any Linux workstation works for the CLI, but the iOS apps need Xcode. |
| iPhone (optional) | the three SwiftUI apps (admin, photos, lightshow) | iOS 26; a free or paid Apple Developer team for device signing. |
| Philips Hue (optional) | light shows | Hue Bridge v2, six color-capable lights in an Entertainment area; optionally two smart plugs (laser/strobe), an Arduino Uno + fog machine. |

## 2. Server preparation (Ubuntu Server)

Install a current Ubuntu Server (22.04 LTS or newer; everything is systemd +
netplan). During install, create the service user (examples here use `atlas`)
and enable OpenSSH.

### SSH

Copy your key and confirm non-interactive login works — the CLI, rsync and
`atlas api` all depend on it:

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

### NVIDIA driver + container toolkit (GPU pipeline only)

The pipeline's GPU containers bring their own CUDA userspace — the host only
needs the driver and the NVIDIA Container Toolkit:

```bash
sudo ubuntu-drivers install            # proprietary driver, then reboot
nvidia-smi                             # must list the GPU

# NVIDIA Container Toolkit (official apt repo)
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
  | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#' \
  | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
sudo apt-get update && sudo apt-get install -y nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker

docker run --rm --gpus all ubuntu nvidia-smi   # GPU visible in a container
```

A full CUDA toolkit install on the host is only needed if you set up the
light-show analysis venv (its PyTorch wheel ships the CUDA runtime, so in
practice the driver is enough there too).

### Rust toolchain, repo clone, sudoers

```bash
# Rust (the API server needs >= 1.85: edition 2024)
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh

# the repo — several defaults assume this exact path
git clone https://github.com/your-fork/atlas.git ~/atlas
```

The clone at `~/atlas` matters: `atlas api` resets it to `origin/main` and
builds from it, `atlas build` builds its Docker builder images from it, and
the photo server/ingest default `PG_ENV_FILE` points into it.

Passwordless sudo: the API server's power endpoints and `atlas
shutdown/restart` need exactly `poweroff` and `reboot`; `atlas api`
additionally uses `systemctl`, `install` and `tee` non-interactively,
`atlas build` uses `chown`, and `atlas dev` uses `tailscale serve`.
Minimal power-only rule:

```
# /etc/sudoers.d/atlas  (visudo -f)
atlas ALL=(root) NOPASSWD: /usr/sbin/poweroff, /usr/sbin/reboot
```

Extend the list (or grant broader NOPASSWD, at your own judgment) if you use
the CLI's installer commands — the exact set is in
[cli/README.md](../cli/README.md#server-prerequisites).

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
- **iPhone:** Tailscale from the App Store — required for all three iOS apps
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
deliberate internet-facing path is `atlas dev --public` (section 7.3): an
*outbound* Cloudflare Tunnel that publishes a chosen dev container at
`<name>.lukaloehr.com` — nothing is forwarded on the router for it either.
Inside that, confinement is per service, and it is worth being precise about
which mechanism does the work: two ports are enforced by nftables, most of the
rest are confined by the address they bind, and a few — sshd, Art-Net and the
host Caddy — listen on every interface on purpose. The table below says which
is which. There is no TLS on the services themselves — WireGuard encrypts the
path inside the tailnet, and on the raw LAN you accept cleartext or bind to
the Tailscale IP.

| Port | Service | Binds | Auth |
|---|---|---|---|
| 22/tcp | sshd | all — **not** in the firewall table | SSH keys |
| 5432/tcp | Postgres | `127.0.0.1` only | password (loopback only — remote dev via SSH tunnel) |
| 8787/tcp | atlas-api | `0.0.0.0` (configurable), firewalled to lo + tailnet | `ATLAS_API_TOKEN` |
| 8788/tcp | atlas-photos server | `0.0.0.0` (configurable), firewalled to lo + tailnet | `ATLAS_PHOTOS_TOKEN` |
| 8093/tcp | embed-api sidecar | `127.0.0.1` only | none (loopback only) |
| 6454/udp | Art-Net (bridge host) | all — **not** in the firewall table | none — any host on the LAN can drive the lamps |
| 53/tcp+udp | AdGuard Home | the tailnet address only (`ATLAS_TAILNET_IP`) — **not** in the firewall table | none — tailnet only |
| 3053/tcp | AdGuard admin UI | `127.0.0.1` only (reach it via `ssh -L 3053:127.0.0.1:3053 atlas`) | AdGuard's own login |
| 8080/tcp | host Caddy (dev-subdomain proxy, section 7.3) | all — **not** in the firewall table | none — serves only the per-Host routes `atlas dev --public` adds, so without a matching `<name>.lukaloehr.com` Host header it answers nothing |
| 2019/tcp | Caddy admin API | `localhost` only | none (loopback only — `atlas dev` mutates it over ssh) |

`scripts/firewall/firewall.nft` matches exactly `{ 8787, 8788 }`, tcp only, so
every other row above is confined by its bind address alone — or, for sshd,
Art-Net and the host Caddy, not confined at all. Move any of them onto
`0.0.0.0` and nothing stops the LAN from reaching them. Art-Net is the one that is already there: 6454/udp
is unauthenticated and drives physical hardware, and the only thing keeping it
off the internet is that the router does not forward it.

Adding a port to that set is also not a general remedy. The nft table registers
`hook input` only, while AdGuard's `53` and `3053` are Docker-*published*
ports: LAN traffic to them is DNAT'd in `nat/prerouting` and then traverses the
forward hook, never `input`. A rule added for those two would silently match
nothing. Their bind address is the control.

Where the tokens fit:

- **`ATLAS_API_TOKEN`** (atlas-api): without it the API server fails closed —
  read-only GETs work, but the PTY terminal and every state-changing route are
  refused. `ATLAS_API_OPEN=1` is the explicit opt-in to run token-less and
  trust the tailnet + firewall instead. Prefer the token: it protects a
  root-adjacent shell.
- **`ATLAS_PHOTOS_TOKEN`** (photo server): the only thing that authorizes a
  mutation. Without it every write — favorite, trash, permanent delete, empty
  trash, upload, all drive writes — is refused, and `ATLAS_PHOTOS_OPEN=1` does
  not change that (it only opens *reads* on a trusted network). Set it, and
  put it in the iOS app under Einstellungen → Token.

Generate tokens with `openssl rand -hex 32`.

Tokens are not the whole story, because `ATLAS_PHOTOS_OPEN=1` deliberately
leaves **reads** unauthenticated for the iOS apps. That is safe only if the LAN
cannot reach the port, so the host firewall is not optional:

```bash
scripts/firewall/install.sh
```

It drops tcp/8787 and tcp/8788 on every interface except `lo` and
`tailscale0`, for IPv4 and IPv6 alike, and reloads at boot from
`atlas-firewall.service`. Details and the reasoning for the separate nftables
table are in `scripts/firewall/README.md`. Verify with:

```bash
sudo nft -a list table inet atlas-fw     # per-rule counters show what got dropped
```

Both services bind `0.0.0.0`, not `[::]`, so only IPv4 is reachable — but
the rules are `inet`, so changing a bind to `[::]` later cannot quietly
reopen the LAN.

## 4. Mac: the `atlas` CLI

```bash
cd ~/atlas          # your clone, on the Mac
# Rust toolchain, if you don't have one: https://rustup.rs (or `brew install rustup`)
cargo install --path cli        # installs `atlas` into ~/.cargo/bin
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
# atlas-api host:port (defaults to the tailnet host + :8787).
ATLAS_API_URL=atlas.your-tailnet.ts.net:8787
EOF
```

Smoke test:

```bash
atlas status      # up/down + route
atlas shutdown && atlas boot     # full WoL round-trip (from inside the LAN)
atlas nvidia-smi  # any command runs remotely
```

Commands, remote builds (`atlas build` / `atlas dev`) and the builder images:
[cli/README.md](../cli/README.md).

## 5. Backend: Postgres

One Postgres 17 + pgvector container is the data layer for the whole photo
stack. On the server:

```bash
cd ~/atlas/backend/docker
cp .env.example .env             # set POSTGRES_PASSWORD (openssl rand -base64 24)
docker compose up -d
```

Apply the schema — plain numbered SQL files, **all of them, in order**; there
is no migration runner:

```bash
for f in ../schema/0*.sql; do
  docker exec -i atlas-postgres psql -U atlas -d atlas < "$f"
done
docker exec atlas-postgres psql -U atlas -d atlas -c 'TABLE schema_migrations;'
# expect versions 1 through 7
```

Every file is idempotent (safe to re-run). The port is bound to `127.0.0.1`
only; for remote development tunnel it:
`ssh atlas -L 5432:localhost:5432`. Schema design, consumers and backup
notes: [backend/README.md](../backend/README.md).

### 5.1 Compose conventions

Three container stacks run on this box, and they follow the same three rules
so that `docker ps` is readable and a rebuild is reproducible:

| Stack | Directory | Project name |
|---|---|---|
| Postgres + pgvector | `backend/docker/` | `atlas-backend` |
| Photos AI pipeline | `apps/atlas-photos/pipeline/` | `atlas-pipeline` |
| AdGuard Home | `infra/adguard/` | `atlas-adguard` |

1. **The file is `compose.yml`.** Not `docker-compose.yml`, which is the v1
   spelling.
2. **The project name is set explicitly** with a top-level `name:`. Compose
   otherwise derives it from the directory, which here would yield a stack
   literally called `docker` — meaningless in `docker ps`, and worse, the
   project name prefixes the volume names, so renaming a directory can
   orphan a database.
3. **Images are pinned by tag *and* digest.** The tag is for humans, the
   digest is what gets pulled. A re-tagged upstream image cannot change what
   runs here. Bump both halves together.

Third-party images are pinned; the two pipeline images are built from local
Dockerfiles and carry no digest.

## 6. Photos stack

Order: pipeline (needs the schema from step 5) → Rust server → iOS app →
first ingest. Full details:
[apps/atlas-photos/README.md](../apps/atlas-photos/README.md).

### 6.1 AI pipeline (Docker, GPU)

```bash
cd ~/atlas/apps/atlas-photos/pipeline
cp .env.example .env
```

`.env` (read by docker compose):

| Variable | Default | Purpose |
|---|---|---|
| `ATLAS_PHOTOS_DIR` | none — **required** | host photo library root (`originals/`, `thumbs/`, `faces/`), e.g. `/home/atlas/photos` |
| `ATLAS_MODELS_DIR` | none — **required** | host model cache (~6 GB after first start), e.g. `/home/atlas/models` |
| `ATLAS_PG_ENV_FILE` | `../../../backend/docker/.env` | file with the `POSTGRES_PASSWORD=` line, mounted read-only |
| `ATLAS_PIPELINE_UID` / `ATLAS_PIPELINE_GID` | `1000` / `1000` | owner of the photo library on the host |
| `ATLAS_EMBED_REVISION` | `main` | git revision of the Qwen embedding repo — code from it is executed; pin a commit sha |

```bash
docker compose up -d --build
docker compose logs -f pipeline-gpu    # watch the first start
```

Three services start: `pipeline-cpu` (thumbs, EXIF, geocode, events),
`pipeline-gpu` (embeddings, faces, tags — needs the NVIDIA container
toolkit from section 2) and `embed-api` (text-embedding sidecar on
`127.0.0.1:8093` for search queries). On its first start the GPU container
runs `download_models.py`, which fetches **Qwen/Qwen3-VL-Embedding-2B** and
**Qwen/Qwen2.5-VL-3B-Instruct-AWQ** into `$ATLAS_MODELS_DIR/hf` and the
insightface **buffalo_l** pack into `$ATLAS_MODELS_DIR/insightface` (~6 GB
total, idempotent — later starts skip it). No GPU? Run
`docker compose build && docker compose up -d pipeline-cpu embed-api`
(building the GPU image needs no GPU; `embed-api` runs it CPU-only): you
lose semantic-search indexing, faces and tags, but the library, thumbs and
metadata work.

### 6.2 Rust server (systemd)

```bash
cd ~/atlas/apps/atlas-photos/server
cargo build --release
sudo install -m755 target/release/atlas-photos /usr/local/bin/
sudo cp atlas-photos.service /etc/systemd/system/
sudo systemctl daemon-reload
```

Edit `/etc/systemd/system/atlas-photos.service` before starting: set `User=`
to the library owner and configure via `Environment=` lines or an
`EnvironmentFile=/etc/atlas-photos.env`. Key variables (all defaults in
`server/src/main.rs`): `PHOTOS_DIR` (default `$HOME/photos` — point it at
`ATLAS_PHOTOS_DIR` from 6.1), `DRIVE_DIR` (`$HOME/drive`),
`ATLAS_PHOTOS_BIND` (`0.0.0.0:8788`), `ATLAS_PHOTOS_TOKEN` (set it — see the
security model), `PG_ENV_FILE` (`$HOME/atlas/backend/docker/.env`).

```bash
sudo systemctl enable --now atlas-photos
curl -s http://127.0.0.1:8788/health         # ok
```

### 6.3 iOS app ("Atlas Photos")

On the Mac:

```bash
cd ~/atlas/apps/atlas-photos/ios
# project.yml carries the author's bundle id — set your own first
$EDITOR project.yml           # bundleIdPrefix + PRODUCT_BUNDLE_IDENTIFIER
brew install xcodegen && xcodegen generate
open AtlasPhotos.xcodeproj    # no shared scheme is committed; Xcode autocreates one
```

Select your iPhone and build/run (Xcode 26, iOS 26 target). The server host
is configured inside the app — `atlas.your-tailnet.ts.net:8788` plus the
bearer token; nothing is compiled in. An ATS exception allows plain HTTP to
`*.ts.net` hosts (WireGuard already encrypts in-tailnet traffic).

**Schemes, once for all three apps:** no app commits a shared `.xcscheme` and
no `project.yml` declares a `scheme:`, so every `xcodebuild -scheme <Name>`
in these docs and in the app READMEs relies on Xcode autocreating the scheme
the first time the project is opened or built.

### 6.4 First ingest (Google Takeout)

Ingest scripts run on the server and need `python3` with `psycopg`,
`Pillow`, `pillow-heif`, plus `ffmpeg`/`ffprobe` (video thumbs) and
`pdftotext` (drive text search).

1. Order a Google Takeout export of Google Photos (50 GB zip parts).
2. On the Mac, run `~/atlas/scripts/takeout-transfer.sh` — it watches
   `~/Downloads` and moves each completed `takeout-*.zip` to
   `atlas:~/takeout/photos/`, verified, then deletes the local copy.
3. On the server, run the watcher (ingests each zip exactly once,
   sequentially, straight out of the zips):

   ```bash
   screen -dmS ingestwatch bash ~/atlas/apps/atlas-photos/ingest/ingest_watcher.sh
   # or one-shot: python3 ingest/ingest_takeout.py ~/takeout/photos/*.zip
   ```

Ingest fills `assets`/`albums`, writes originals + thumbs and enqueues
pipeline jobs; the workers drain the queue whenever the box is awake.
`ingest_drive.py` does the same for a Takeout **Drive** export, and
`pipeline/backfill_jobs.py` re-enqueues jobs for existing assets.

## 7. The API server, the iOS apps, and the dev proxy

### 7.1 atlas-api

From the Mac, one command builds and installs the control-plane server on the
box as a systemd service (it uses the `~/atlas` clone):

```bash
atlas api
```

It resets the server's checkout to `origin/main`, builds `api/`, installs the
binary and the unit, and restarts it — all in one `set -e` chain, so a failed
build leaves the running server untouched.

Manual equivalent: `cargo build --release` in `~/atlas/api`, install the binary
to `/usr/local/bin/atlas-api`, copy `atlas-api.service` — adjust `User=` — then
`systemctl enable --now atlas-api`. See [api/README.md](../api/README.md).

Token setup on the server:

```bash
echo "ATLAS_API_TOKEN=$(openssl rand -hex 32)" | sudo tee /etc/atlas-api.env
sudo chmod 600 /etc/atlas-api.env
sudo systemctl restart atlas-api
curl -s http://127.0.0.1:8787/health          # {"ok":true}
```

The unit loads `/etc/atlas-api.env` if present. Alternative:
`ATLAS_API_OPEN=1` (tailnet-trust mode, no token) — see the security model
in section 3. atlas-api also serves the light-show control routes; if your
lightshows checkout is not at `~/atlas/lightshows`, set
`ATLAS_LIGHTSHOWS_DIR`. The full variable table is in
[api/README.md](../api/README.md#configuration).

Day-to-day: `atlas api logs` (follow the journal), `atlas api status`,
`atlas api stop`, `atlas api restart`.

### 7.2 iOS apps ("Atlas Admin", "Atlas Lightshow")

Both projects are committed with signing disabled
(`CODE_SIGNING_ALLOWED: NO`), so they build for the simulator out of the box:

```bash
open ~/atlas/apps/atlas-admin/ios/AtlasAdmin.xcodeproj
open ~/atlas/apps/atlas-lightshow/ios/AtlasLightshow.xcodeproj
```

Both are generated by XcodeGen from the `project.yml` next to them; re-run
`xcodegen generate` in that directory after changing it.

For a device build: target → Signing & Capabilities → enable signing, pick
your team, and change the bundle identifier for your fork. Do it in
`project.yml`, not in Xcode — `xcodegen generate` overwrites the project file
and would discard an Xcode-local change. In each app's settings, point it at
the API server: host `atlas.your-tailnet.ts.net:8787` and the
`ATLAS_API_TOKEN` value. The iPhone must be on the tailnet.

### 7.3 Dev-subdomain proxy (optional — only for `atlas dev --public`)

`atlas build` / `atlas dev` over the tailnet need nothing beyond the CLI
prerequisites. Publishing a dev server on the internet at a stable
`https://<name>.lukaloehr.com` URL additionally needs the host-side proxy
infra: a persistent named Cloudflare Tunnel plus a host Caddy whose per-Host
routes `atlas dev` adds and removes at runtime.

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

## 8. Light shows

Full subsystem docs: [lightshows/README.md](../lightshows/README.md).
The bridge (`bridge/hue_stream.py`) can run on the server or any always-on
LAN box near the Hue Bridge; it needs Python 3, the `openssl` CLI with
DTLS 1.2 + `PSK-AES128-GCM-SHA256`, and optionally `pyserial` for fog.

### 8.1 Hue pairing → `bridge/credentials.json`

1. In the Hue app, create an **Entertainment area** containing your six
   color lights.
2. Press the link button on the Hue Bridge, then within ~30 s:

   ```bash
   curl -s -X POST http://192.168.1.2/api \
     -d '{"devicetype":"atlas#setup","generateclientkey":true}'
   ```

   The response contains a whitelist `username` and the DTLS `clientkey`.
3. Find the Entertainment group's v1 id (`type: "Entertainment"`):

   ```bash
   curl -s http://192.168.1.2/api/<username>/groups
   ```
4. Copy `bridge/credentials.example.json` to `bridge/credentials.json`
   (gitignored) and fill in `host` (bridge IP), `username`, `clientKey`,
   `group`. On atlas this path is a symlink to `/etc/atlas/` — see
   [section 9](#9-secrets-and-mutable-state-live-outside-the-checkout).
5. Adapt the rig constants at the top of `bridge/hue_stream.py`:
   `LIGHT_ORDER` (six Hue v1 light ids in DMX channel order), `LASER_V1` /
   `STROBEPLUG_V1` (smart-plug ids, if used), `FOG_PORT` (default
   `/dev/ttyACM0`).

### 8.2 Point the player at the bridge

On whatever machine plays shows (Mac or the server), set
`ATLAS_ARTNET_HOST` or write the bridge host's IP as a single line into
`lightshows/artnet_host.local` (gitignored).

### 8.3 Play

```bash
# bridge host — must be running during playback
python3 -u bridge/hue_stream.py

# control machine, in lightshows/
python3 play.py shows/party-rock.show.json     # hand-designed reference show
```

Audio files are not in the repo. A show's `meta.song_file` is a bare basename
that is resolved against the media root `ATLAS_LIGHTSHOW_MEDIA_DIR` (default
`/var/lib/atlas/lightshow-media`) first, then against `shows/` as a
fallback — see [section 9](#show-media-a-media-root-not-a-symlink). The
reference show wants `music.mp3` there. Producing shows from new songs
(`makeshow.py`, YouTube ingestion, the GPU analysis venv at `analyze/.venv`,
AI mode), the `atlas` SSH alias and `LIGHTSHOW_REMOTE_DIR` are covered in the
[lightshows setup](../lightshows/README.md#setup).

### 8.4 Optional hardware

- **Fog:** flash `hardware/fog.ino` onto an Arduino Uno; pin D8 switches the
  fog machine's RF remote. The serial heartbeat auto-stops fog within 1.5 s
  if the bridge dies — fail-safe by design.
- **Laser / strobe:** plain devices on Hue smart plugs; the compiler solves
  their warm-up times, and atlas-api force-stops them after every show.

## 9. Secrets and mutable state live outside the checkout

Several files a running service needs are gitignored, so they are invisible
to `git status` and **`git clean -fdx` in the checkout would delete them** —
with no copy anywhere else. To stop that, the real files live outside the
working tree and the paths inside it are symlinks; cleaning the tree then
removes a link, not the credential.

| Path in the checkout (symlink) | Real file | Mode |
|---|---|---|
| `lightshows/bridge/credentials.json` | `/etc/atlas/lightshow-hue-credentials.json` | `0600 luka:luka` |
| `backend/docker/.env` | `/etc/atlas/backend-postgres.env` | `0600 luka:luka` |
| `apps/atlas-photos/pipeline/.env` | `/etc/atlas/photos-pipeline.env` | `0600 luka:luka` |
| `lightshows/artnet_host.local` | `/etc/atlas/lightshow-artnet-host` | `0644 luka:luka` |
| `lightshows/calibration.json` | `/var/lib/atlas/lightshow-calibration.json` | `0644 luka:luka` |

`/etc/atlas` holds configuration and secrets; `/var/lib/atlas` holds state a
service rewrites at runtime (`calibration.json` is written by atlas-api's
`POST /api/calibrate/save`, which writes *through* the symlink).

**These files are owned by the service account, not by `root`.** This differs
from `/etc/atlas-api.env`, which is root-owned `0600` — that is a systemd
`EnvironmentFile=` directive that *systemd* reads as root before dropping
privileges. The files above are opened by the service process itself, and
`lightshow-bridge` and `atlas-api` both run as an unprivileged `User=`, so
root-owned `0600` would make them unreadable and the bridge would crash on
import.

Adding another one: copy it into the store with the owner/mode above, verify
with `cmp`, then replace the original with `ln -s`. Do not commit the
symlink — the target path is machine-specific, so these stay gitignored.

### Show media: a media root, not a symlink

`lightshows/shows/` is a *mixed* directory: tracked `*.show.json` files sit
where gitignored media (`*.mp3`/`*.jpg`/`*.wav`) of the same basename would
land beside them — exactly the kind of file `git clean -fdx` takes. A
symlink cannot fix this one: linking the directory whole would drag the
tracked JSON out of the tree, and per-file links would rot as every new
show brings new media.

Instead there is a **media root**, `ATLAS_LIGHTSHOW_MEDIA_DIR`, defaulting to
`/var/lib/atlas/lightshow-media` (`0755 luka:luka`). The default points
outside the checkout unconditionally — that is the point, so that a shell
without the variable set still writes somewhere safe.

| | media root | `shows/` |
|---|---|---|
| audio + covers | written and read here | read only, as a fallback |
| `.show.json`, `.summary.md` | never | written here, tracked |

Writers (`makeshow.py`, `tools/make_calibration.py`) use the media root and
have **no** fallback, so new media can never land in the checkout. Readers
(`engine/sequence.py:song_path`, atlas-api's `audio_file()` and
`show_thumb()`) probe the media root first and then `shows/`, so files
dropped into `shows/` by hand play too. `meta.song_file` is a bare
basename; absolute paths are honoured as-is.

`makeshow.py` can drive the GPU host over ssh (`LIGHTSHOW_REMOTE_DIR`), but
only `analyze/` is used there — the song is copied in, analysed, and deleted.
Media is written on whichever machine runs `makeshow.py`, into that machine's
own media root; the GPU host needs no media root and nothing is synced back.

## Bring-up checklist

```text
[ ] ssh atlas works with keys, static DHCP lease set
[ ] atlas shutdown && atlas boot round-trips (WoL)
[ ] tailscale status green on server, Mac, iPhone; MagicDNS on
[ ] docker run --rm --gpus all ubuntu nvidia-smi   (GPU pipeline only)
[ ] atlas-postgres up, schema_migrations shows 1..7
[ ] pipeline containers up, models downloaded, queue draining
[ ] curl http://atlas.your-tailnet.ts.net:8788/health from the Mac
[ ] curl http://atlas.your-tailnet.ts.net:8787/health from the Mac
[ ] systemctl is-active atlas-api atlas-photos   (both active)
[ ] scripts/firewall/install.sh has run; nft list table inet atlas-fw shows rules
[ ] iOS apps reach their hosts over the tailnet with tokens set
[ ] nothing is port-forwarded on the router
```
