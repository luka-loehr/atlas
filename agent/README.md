# atlas-agent

The little Rust server that makes atlas observable and controllable from the
phone. It is the backend of the [Atlas Command Center](../apps/atlas-admin)
and [Lightshow](../apps/atlas-lightshow) iOS apps.

Runs on atlas as the systemd unit `atlas-agent.service`, binary
`/usr/local/bin/atlas-agent`, bound to **`0.0.0.0:8787`** — reachable over the
tailnet (`atlas.your-tailnet.ts.net:8787`) and the LAN. No auth: it is only ever
exposed to the private tailnet, never to the internet.

Dependency: `rapl-readable.service` (oneshot) chmods the Intel RAPL energy
counters at boot so the agent can read CPU power without root. It shows as
`active (exited)` — that is the correct state for a oneshot, not a failure.

## Modules

| file | what it does |
|---|---|
| `main.rs` | tiny hand-rolled HTTP/WS router (no framework), thread per connection |
| `metrics.rs` | CPU/GPU/RAM/disk/load/temps + **power**: Intel RAPL for the CPU (`energy_uj` deltas), `nvidia-smi` for the GPU, plus baseline so idle isn't understated |
| `stream.rs` | `/ws/metrics` — pushes each new sample as the sampler produces it, after replaying a short history so charts render instantly |
| `terminal.rs` | `/term` — a **real PTY over WebSocket** (SwiftTerm on the client): keystrokes in, output out, plus resize control messages |
| `actions.rs` | power (shutdown/restart), docker inspection, and the lightshow control surface: shows, lights, fog, bridge, calibration |
| `activity.rs` | GitHub-style contribution heatmap of atlas' awake hours, reconstructed from the systemd journal, plus monorepo commits |
| `vpn.rs` | exit-node view: tailnet peers with rx/tx, AdGuard Home DNS/ad-block stats |

## Routes

**Status & live**

| route | |
|---|---|
| `GET /health` | liveness |
| `GET /api/metrics` | one full metrics snapshot (JSON) |
| `GET /ws/metrics` | WebSocket: history replay, then live samples |
| `GET /term` | WebSocket: interactive PTY |
| `GET /api/activity` | awake-hours heatmap + commits |
| `GET /api/vpn` | tailnet peers + AdGuard stats |
| `GET /api/docker`, `/api/docker/…` | containers, state, logs |

**Control**

| route | |
|---|---|
| `POST /api/power/shutdown`, `/api/power/restart` | power the box down / reboot |
| `GET /api/shows`, `POST /api/shows/start`, `/api/shows/stop` | lightshow playback |
| `POST /api/shows/create`, `GET /api/shows/create/status`, `/api/shows/create/thumb` | AI show creation + progress |
| `GET /api/shows/audio/…`, `/api/shows/thumb/…` | show assets |
| `POST /api/lights/set`, `/api/lights/off`, `GET /api/lights` | manual per-light control |
| `POST /api/fog`, `/api/fog/stop` | fog machine (hold-to-fog, fail-safe) |
| `POST /api/bridge/stop` | stop the Art-Net→Hue bridge |
| `GET /api/calibrate`, `POST /api/calibrate/save` | light calibration |

## Build & deploy

Built natively on atlas (not in Docker):

```bash
ssh atlas
cd ~/atlas/agent && cargo build --release
sudo install -m755 target/release/atlas-agent /usr/local/bin/atlas-agent
sudo systemctl restart atlas-agent
```

From the Mac, `atlas agent` (see [`../cli`](../cli)) wraps the common cases:
`atlas agent logs | status | stop | restart`.
