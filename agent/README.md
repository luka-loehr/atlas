# atlas-agent

A small Rust daemon that makes the Atlas server observable and controllable
from a phone. It is the backend of the [Atlas Command Center](../apps/atlas-admin)
and [Lightshow](../apps/atlas-lightshow) iOS apps, but every route is plain
HTTP/JSON or WebSocket and works just as well from `curl`.

It is deliberately dependency-light: two crates (`tungstenite` for WebSocket
framing, `portable-pty` for the terminal), no async runtime, no web framework,
no serde. HTTP/1.1 parsing, routing and JSON output are hand-rolled, with one
thread per connection. The intended reachability boundary is a private
tailnet plus a host firewall — **never port-forward this service to the
internet.** See [docs/SETUP.md](../docs/SETUP.md) for the machine-level
setup (Ubuntu, Tailscale, Docker, CUDA).

## What it serves

| module | responsibility |
|---|---|
| `main.rs` | TCP listener, request parser (8 KiB line / 64 header / 16 KiB body caps, 10 s read timeout), auth gate, routing, static file serving, power endpoints |
| `metrics.rs` | machine snapshot: CPU/RAM/load/net from `/proc`, disk via `df`, CPU temp via `sensors`, GPU via `nvidia-smi`, CPU power via Intel RAPL, whole-system power estimate |
| `stream.rs` | `/ws/metrics`: a global sampler takes one sample every 500 ms into a 1200-entry ring (10 min); each client gets the full history as a bootstrap frame, then live pushes |
| `terminal.rs` | `/term`: a real PTY running `bash -l` (`TERM=xterm-256color`, cwd `$HOME`), bridged over WebSocket |
| `actions.rs` | Docker inspection and the whole lightshow control surface: shows, YouTube→show creation, manual lights, hold-to-fog via Art-Net, Hue plug fail-safe, calibration |
| `activity.rs` | per-day awake minutes/boots (reconstructed from the systemd journal's boot list) and commits/day — data for a GitHub-style heatmap |
| `vpn.rs` | Tailscale peer/exit-node status, persistent tunnel-usage accumulators, AdGuard Home DNS stats |

### Read routes (`GET`)

| route | returns |
|---|---|
| `/health` | `{"ok":true}` |
| `/api/metrics` (alias `/`) | full snapshot: hostname, uptime, load, cpu (usage/cores/temp), mem, gpu, power (`cpu_w`/`gpu_w`/`system_w`), disk, net counters, kernel/os, containers |
| `/ws/metrics` | WebSocket — one `{"history":[…]}` frame, then a sample every 500 ms: `{"ts_ms","cpu","mem","mem_gb","gpu","gpu_mem_mb","rx","tx"}` (`rx`/`tx` are cumulative bytes; derive rates client-side) |
| `/api/docker` | running containers (name/status/image) |
| `/api/docker/<name>` | one container: state, image, ports, restart count, last 200 log lines |
| `/api/shows` | bridge status + shows on disk (name, title, bpm, duration, running) |
| `/api/shows/create/status` | show-creation progress: phase, download percent, AI ticker, log tail |
| `/api/shows/create/thumb` · `/api/shows/thumb/<name>` · `/api/shows/audio/<name>` | media files of a show |
| `/api/lights` | manual-control state: bridge up, held 21-channel frame |
| `/api/calibrate` | saved audio latency |
| `/api/vpn` | Tailscale backend state, exit-node offer, peers (host/os/online/rx/tx), tunnel-usage accumulators, AdGuard stats |
| `/api/activity` | 154 days × `{"d","min","boots","commits"}` |

### State-changing routes

| route | body / effect |
|---|---|
| `GET /term` | WebSocket PTY: client→server `Binary` = keystrokes, `Text` = `{"resize":{"cols":C,"rows":R}}`; server→client `Binary` = terminal output. Shell is killed on disconnect |
| `POST /api/shows/start` | body: show name — stops any running player, starts the Art-Net→Hue bridge if needed, plays lights only (`--no-audio`; the app plays the song) |
| `POST /api/shows/stop` | stop the player; the bridge stays alive, effect plugs are forced off via the Hue REST API as a fail-safe |
| `POST /api/bridge/stop` | stop everything including the bridge |
| `POST /api/shows/create` | body: `<url>` or `ai <url>` — runs `makeshow.py --local [--ai]` in the background; poll `/api/shows/create/status` |
| `POST /api/fog` / `POST /api/fog/stop` | hold-to-fog: body = milliseconds (clamped 200–30000); fog Art-Net packets heartbeat at 30 Hz until stop/timeout |
| `POST /api/lights/set` | body: up to 21 channel values 0–255, separated by any non-digits; held and heartbeated to the bridge at 30 Hz (the fog channel is forced 0) |
| `POST /api/lights/off` | blackout, heartbeat off |
| `POST /api/calibrate/save` | body: audio latency in ms (0–2000) |
| `POST /api/power/shutdown` · `/api/power/restart` | runs `sudo poweroff` / `sudo reboot` (needs sudoers, see below) |

## Auth

Three modes, decided at startup:

- **Token (recommended):** set `ATLAS_AGENT_TOKEN`. Every request must carry
  `Authorization: Bearer <token>`; WebSocket clients may pass `?token=…`
  instead. Comparison is constant-time.
- **No token (default):** the agent fails closed — read-only `GET` routes are
  served, but the state-changing surface (the PTY terminal and everything
  non-`GET`) is refused with `403`.
- **`ATLAS_AGENT_OPEN=1`:** explicit opt-in to serve state-changing routes
  without a token, for deployments where the tailnet + firewall is the only
  boundary. Prefer the token.

There is no TLS: on the tailnet, WireGuard encrypts the path. On a plain LAN
the token travels in cleartext — bind to the Tailscale IP
(`ATLAS_AGENT_BIND`) if that matters.

## Build & run

Built natively on the server (no cross-compilation, no Docker). Requires
Rust ≥ 1.88 (edition 2024 + let-chains).

```bash
ssh your-server
cd ~/atlas/agent
cargo build --release
sudo install -m755 target/release/atlas-agent /usr/local/bin/atlas-agent
sudo cp atlas-agent.service /etc/systemd/system/   # first install: adjust User=
sudo systemctl daemon-reload
sudo systemctl enable --now atlas-agent            # later: systemctl restart atlas-agent
```

The unit runs the agent as `User=atlas` — change that to your service
account. Ad-hoc development run:

```bash
ATLAS_AGENT_OPEN=1 cargo run
curl localhost:8787/health
```

The [`atlas` CLI](../cli) wraps the common cases from a workstation:
`atlas agent` (build + install on the server over SSH), `atlas agent
logs|status|stop|restart`.

## Configuration

All optional, via environment variables — the unit loads
`/etc/atlas-agent.env` if present:

| Variable | Default | Purpose |
|---|---|---|
| `ATLAS_AGENT_TOKEN` | *(unset)* | bearer token; strongly recommended |
| `ATLAS_AGENT_OPEN` | *(unset)* | `1` allows state-changing routes without a token |
| `ATLAS_AGENT_BIND` | `0.0.0.0:<port>` | full listen address, e.g. a Tailscale IP; overrides `ATLAS_AGENT_PORT` |
| `ATLAS_AGENT_PORT` | `8787` | listen port when `ATLAS_AGENT_BIND` is unset |
| `ATLAS_LIGHTSHOWS_DIR` | `$HOME/atlas/lightshows` | the [lightshows](../lightshows) checkout the show/fog/lights routes drive |
| `ATLAS_REPO_DIR` | `$HOME/atlas` | git clone whose commits feed the activity heatmap |
| `ATLAS_HUE_PLUG_IDS` | `22,25` | Hue light ids of the effect plugs forced off on show stop |
| `ATLAS_ADGUARD_URL` | `http://127.0.0.1:3000` | AdGuard Home admin API base URL |
| `ATLAS_ADGUARD_AUTH` | *(unset)* | `user:pass` basic auth for AdGuard (passed to curl via stdin, never argv) |
| `ATLAS_POWER_BASELINE_W` | `35` | idle baseline (board/DRAM/fans) of the system-power estimate |
| `ATLAS_PSU_EFFICIENCY` | `0.88` | PSU efficiency divisor of the system-power estimate |

## Operational notes

Everything degrades gracefully: a missing tool or subsystem turns its fields
into `null`/empty instead of failing the request.

- **Docker** (`/api/docker`, `containers` in the snapshot): the service user
  must be in the `docker` group.
- **Power endpoints:** need passwordless sudo for exactly these two commands —
  `your-user ALL=(root) NOPASSWD: /usr/sbin/poweroff, /usr/sbin/reboot`.
- **CPU power (`cpu_w`, and with it `system_w`):** Intel-only, read from
  `/sys/class/powercap/intel-rapl:0/energy_uj`, which the kernel keeps
  root-only. Install a oneshot that makes it readable at boot (it shows as
  `active (exited)` — correct for a oneshot, not a failure):

  ```ini
  # /etc/systemd/system/rapl-readable.service
  [Unit]
  Description=Make the Intel RAPL energy counter readable
  [Service]
  Type=oneshot
  ExecStart=/bin/chmod a+r /sys/class/powercap/intel-rapl:0/energy_uj
  [Install]
  WantedBy=multi-user.target
  ```

  The system-power number is a calibrated estimate
  (`(cpu_w + gpu_w + baseline) / psu_efficiency`) — only a wall-plug meter is
  exact.
- **GPU metrics:** need `nvidia-smi`; **CPU temperature:** needs lm-sensors
  (`sensors`).
- **`/api/activity`:** reconstructs awake time from `journalctl --list-boots`,
  so the journal must be persistent (`Storage=persistent` in
  `journald.conf`); commit counts need the git clone at `ATLAS_REPO_DIR`.
- **`/api/vpn`:** needs Tailscale installed and logged in; AdGuard stats need
  a local AdGuard Home. Usage accumulators persist in
  `$HOME/.local/share/atlas-agent/vpn.json` across restarts.
- **Lightshow routes:** need the [lightshows](../lightshows) subsystem
  working at `ATLAS_LIGHTSHOWS_DIR` (Python 3, `yt-dlp`, a configured Hue
  bridge `bridge/credentials.json`, the fog hardware). The agent talks to the
  bridge via Art-Net UDP on loopback port 6454 and writes runtime logs to
  `/tmp/atlas-bridge.log`, `/tmp/atlas-play.log`, `/tmp/atlas-makeshow.log`.
- Container/show names are validated against a strict character allowlist
  before reaching `docker` or the filesystem, and thumbnail paths from
  the makeshow log are canonicalized and confined to the lightshows
  directory before being served.
