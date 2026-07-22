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
| NVIDIA GPU in the server | photo AI pipeline (`pipeline-gpu`: embeddings, faces, tags) and light-show song analysis | Everything else — Postgres, photo server, agent, CPU pipeline, show playback — runs fine without one. ≥ 8 GB VRAM recommended for the vLLM caption stage. |
| Mac | the `atlas` CLI, building the iOS apps | The CLI is Unix-only; any Linux workstation works for the CLI, but the iOS apps need Xcode. |
| iPhone (optional) | the three SwiftUI apps (admin, photos, lightshow) | iOS 26; a free or paid Apple Developer team for device signing. |
| Philips Hue (optional) | light shows | Hue Bridge v2, six color-capable lights in an Entertainment area; optionally two smart plugs (laser/strobe), an Arduino Uno + fog machine. |

## 2. Server preparation (Ubuntu Server)

Install a current Ubuntu Server (22.04 LTS or newer; everything is systemd +
netplan). During install, create the service user (examples here use `atlas`)
and enable OpenSSH.

### SSH

Copy your key and confirm non-interactive login works — the CLI, rsync and
`atlas agent` all depend on it:

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
# Rust (agent needs >= 1.88: edition 2024)
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh

# the repo — several defaults assume this exact path
git clone https://github.com/your-fork/atlas.git ~/atlas
```

The clone at `~/atlas` matters: `atlas agent` resets it to `origin/main` and
builds from it, `atlas build` builds its Docker builder images from it, and
the photo server/ingest default `PG_ENV_FILE` points into it.

Passwordless sudo: the agent's power endpoints and `atlas shutdown/restart`
need exactly `poweroff` and `reboot`; `atlas agent` additionally uses
`systemctl`, `install` and `cp` non-interactively, and `atlas build` uses
`chown`. Minimal power-only rule:

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

The whole platform relies on one boundary: **services bind on the server and
are reachable over the tailnet only. Never port-forward any of them to the
internet.** There is no TLS on the services themselves — WireGuard encrypts
the path inside the tailnet, and on the raw LAN you accept cleartext or bind
to the Tailscale IP.

| Port | Service | Binds | Auth |
|---|---|---|---|
| 22/tcp | sshd | all | SSH keys |
| 5432/tcp | Postgres | `127.0.0.1` only | password (loopback only — remote dev via SSH tunnel) |
| 8787/tcp | atlas-agent | `0.0.0.0` (configurable) | `ATLAS_AGENT_TOKEN` |
| 8788/tcp | atlas-photos server | `0.0.0.0` (configurable) | `ATLAS_PHOTOS_TOKEN` |
| 8093/tcp | embed-api sidecar | `127.0.0.1` only | none (loopback only) |
| 6454/udp | Art-Net (bridge host) | all | none — LAN only |

Where the tokens fit:

- **`ATLAS_AGENT_TOKEN`** (agent): without it the agent fails closed —
  read-only GETs work, but the PTY terminal and every state-changing route
  are refused. `ATLAS_AGENT_OPEN=1` is the explicit opt-in to run token-less
  and trust the tailnet + firewall instead. Prefer the token: it protects
  a root-adjacent shell.
- **`ATLAS_PHOTOS_TOKEN`** (photo server): without it the entire photo/drive
  API — including permanent deletes — is unauthenticated. Acceptable only on
  a trusted network; set it.

Generate tokens with `openssl rand -hex 32`. Optionally add a host firewall
that drops LAN traffic to 8787/8788 and allows it on the `tailscale0`
interface — then the tailnet is the only way in even from your own LAN.

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
# metrics agent (defaults to the tailnet host + :8787)
ATLAS_AGENT_URL=atlas.your-tailnet.ts.net:8787
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
| `ATLAS_PHOTOS_DIR` | `/srv/atlas/photos` | host photo library root (`originals/`, `thumbs/`, `faces/`) |
| `ATLAS_MODELS_DIR` | `/srv/atlas/models` | host model cache (~6 GB after first start) |
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

### 6.3 iOS app ("Storage")

On the Mac:

```bash
cd ~/atlas/apps/atlas-photos/ios
# project.yml carries the author's bundle prefix + team — set your own first
$EDITOR project.yml           # bundleIdPrefix + DEVELOPMENT_TEAM
brew install xcodegen && xcodegen generate
open AtlasPhotos.xcodeproj
```

Select your iPhone and build/run (Xcode 26, iOS 26 target). The server host
is configured inside the app — `atlas.your-tailnet.ts.net:8788` plus the
bearer token; nothing is compiled in. An ATS exception allows plain HTTP to
`*.ts.net` hosts (WireGuard already encrypts in-tailnet traffic).

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

## 7. Agent + admin/lightshow apps

### 7.1 Agent

From the Mac, one command builds and installs the agent on the server as a
systemd service (uses the `~/atlas` clone):

```bash
atlas agent
```

(Manual equivalent: `cargo build --release` in `~/atlas/agent`, install the
binary to `/usr/local/bin/atlas-agent`, copy `atlas-agent.service` — adjust
`User=` — then `systemctl enable --now atlas-agent`. See
[agent/README.md](../agent/README.md).)

Token setup on the server:

```bash
echo "ATLAS_AGENT_TOKEN=$(openssl rand -hex 32)" | sudo tee /etc/atlas-agent.env
sudo chmod 600 /etc/atlas-agent.env
sudo systemctl restart atlas-agent
curl -s http://127.0.0.1:8787/health          # {"ok":true}
```

The unit loads `/etc/atlas-agent.env` if present. Alternative:
`ATLAS_AGENT_OPEN=1` (tailnet-trust mode, no token) — see the security
model in section 3. The agent also serves the light-show control routes; if
your lightshows checkout is not at `~/atlas/lightshows`, set
`ATLAS_LIGHTSHOWS_DIR`.

### 7.2 iOS apps (admin "Atlas", "Lightshow")

Both projects are committed with signing disabled:

```bash
open ~/atlas/apps/atlas-admin/AtlasCommandCenter/AtlasCommandCenter.xcodeproj
open ~/atlas/apps/atlas-lightshow/AtlasLightshow/AtlasLightshow.xcodeproj
```

For a device build: target → Signing & Capabilities → enable signing, pick
your team, and change the bundle identifier for your fork (`xcodegen
generate` resets these — they are Xcode-local changes). In each app's
settings, point it at the agent: host `atlas.your-tailnet.ts.net:8787` and
the `ATLAS_AGENT_TOKEN` value. The iPhone must be on the tailnet.

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
   `group`.
5. Adapt the rig constants at the top of `bridge/hue_stream.py`:
   `LIGHT_ORDER` (six Hue v1 light ids in DMX channel order), `LASER_V1` /
   `STROBEPLUG_V1` (smart-plug ids, if used), `FOG_PORT` (default
   `/dev/ttyACM0`).

### 8.2 Point the player at the bridge

On whatever machine plays shows (Mac or the agent host), set
`ATLAS_ARTNET_HOST` or write the bridge host's IP as a single line into
`lightshows/artnet_host.local` (gitignored).

### 8.3 Play

```bash
# bridge host — must be running during playback
python3 -u bridge/hue_stream.py

# control machine, in lightshows/
python3 play.py shows/party-rock.show.json     # hand-designed reference show
```

Audio files are not in the repo — put your own MP3 where the show's
`meta.song_file` expects it (the reference show: `lightshows/music.mp3`).
Producing shows from new songs (`makeshow.py`, YouTube ingestion, the GPU
analysis venv at `analyze/.venv`, AI mode) and the `ATLAS`/`ATLAS_DIR`
SSH constants are covered in the
[lightshows setup](../lightshows/README.md#setup).

### 8.4 Optional hardware

- **Fog:** flash `hardware/fog.ino` onto an Arduino Uno; pin D8 switches the
  fog machine's RF remote. The serial heartbeat auto-stops fog within 1.5 s
  if the bridge dies — fail-safe by design.
- **Laser / strobe:** plain devices on Hue smart plugs; the compiler solves
  their warm-up times, the agent force-stops them after shows.
- **Preview without hardware:** `scripts/export_fseq.py` renders any show
  for the xLights 3D layout in `lightshows/xlights/`.

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
[ ] iOS apps reach their hosts over the tailnet with tokens set
[ ] nothing is port-forwarded on the router
```
