# atlas-agent

The little Rust server that makes the atlas homelab server observable and
controllable from the phone. It is the backend of the
[Atlas Command Center](../apps/atlas-admin) and
[Lightshow](../apps/atlas-lightshow) iOS apps.

Runs as the systemd unit `atlas-agent.service`, binary
`/usr/local/bin/atlas-agent`, listening on `0.0.0.0:8787` by default —
reachable over the tailnet (e.g. `atlas.your-tailnet.ts.net:8787`). The
intended reachability boundary is the tailnet plus a host firewall: **never
port-forward this service to the internet.**

## Auth

Set `ATLAS_AGENT_TOKEN` (usually in `/etc/atlas-agent.env`): every request
must then carry `Authorization: Bearer <token>` (WebSockets may pass
`?token=…` instead). The comparison is constant-time.

Without a token the agent fails closed: read-only GET routes still work, but
state-changing routes — the PTY terminal, power, docker-adjacent actions,
shows/fog/lights, everything non-GET — are refused with an error. Setting
`ATLAS_AGENT_OPEN=1` explicitly opts out of that protection for deployments
where the tailnet/firewall is the only boundary. Prefer the token.

## Configuration

Everything is optional, via environment variables (e.g. `/etc/atlas-agent.env`):

| var | default | what |
|---|---|---|
| `ATLAS_AGENT_TOKEN` | *(unset)* | bearer token — strongly recommended |
| `ATLAS_AGENT_OPEN` | *(unset)* | `1` allows state-changing routes without a token |
| `ATLAS_AGENT_BIND` | `0.0.0.0:8787` | listen address (e.g. a tailscale IP to avoid the LAN) |
| `ATLAS_AGENT_PORT` | `8787` | port shorthand, used when `ATLAS_AGENT_BIND` is unset |
| `ATLAS_LIGHTSHOWS_DIR` | `$HOME/atlas/lightshows` | the [lightshows](../lightshows) checkout |
| `ATLAS_REPO_DIR` | `$HOME/atlas` | git repo for the activity-heatmap commit counts |
| `ATLAS_HUE_PLUG_IDS` | `22,25` | Hue light ids of the fail-safe effect plugs |
| `ATLAS_ADGUARD_URL` | `http://127.0.0.1:3000` | AdGuard Home admin API |
| `ATLAS_ADGUARD_AUTH` | *(unset)* | `user:pass` for AdGuard basic auth |
| `ATLAS_POWER_BASELINE_W` | `35` | idle baseline of the system-power estimate |
| `ATLAS_PSU_EFFICIENCY` | `0.88` | PSU efficiency of the system-power estimate |

Host prerequisites (all optional-degrade): the service user in the `docker`
group for `/api/docker`; passwordless sudo for exactly `poweroff`/`reboot`
for the power endpoints; a persistent systemd journal for `/api/activity`;
`rapl-readable.service` — a oneshot that chmods
`/sys/class/powercap/intel-rapl:0/energy_uj` readable at boot so CPU power
works without root (it shows as `active (exited)`, which is correct for a
oneshot, not a failure).

## Modules

| file | what it does |
|---|---|
| `main.rs` | tiny hand-rolled HTTP/WS router (no framework), thread per connection |
| `metrics.rs` | CPU/GPU/RAM/disk/load/temps + **power**: Intel RAPL for the CPU (`energy_uj` deltas), `nvidia-smi` for the GPU, plus baseline so idle isn't understated |
| `stream.rs` | `/ws/metrics` — pushes each new sample as the sampler produces it, after replaying a short history so charts render instantly |
| `terminal.rs` | `/term` — a **real PTY over WebSocket** (SwiftTerm on the client): keystrokes in, output out, plus resize control messages |
| `actions.rs` | power (shutdown/restart), docker inspection, and the lightshow control surface: shows, lights, fog, bridge, calibration |
| `activity.rs` | GitHub-style contribution heatmap of the server's awake hours, reconstructed from the systemd journal, plus monorepo commits |
| `vpn.rs` | exit-node view: tailnet peers with rx/tx, AdGuard Home DNS/ad-block stats |

## Routes

**Status & live**

| route | |
|---|---|
| `GET /health` | liveness |
| `GET /api/metrics` | one full metrics snapshot (JSON) |
| `GET /ws/metrics` | WebSocket: history replay, then live samples |
| `GET /term` | WebSocket: interactive PTY (state-changing: needs the token) |
| `GET /api/activity` | awake-hours heatmap + commits |
| `GET /api/vpn` | tailnet peers + AdGuard stats |
| `GET /api/docker`, `/api/docker/…` | containers, state, logs |

**Control** (all state-changing: need the token, or `ATLAS_AGENT_OPEN=1`)

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

Built natively on the server (not in Docker), Rust ≥ 1.88:

```bash
ssh <your-server>
cd ~/atlas/agent && cargo build --release
sudo install -m755 target/release/atlas-agent /usr/local/bin/atlas-agent
sudo cp atlas-agent.service /etc/systemd/system/   # first install: edit User=
sudo systemctl daemon-reload
sudo systemctl enable --now atlas-agent            # later: systemctl restart
```

From the Mac, `atlas agent` (see [`../cli`](../cli)) wraps the common cases:
`atlas agent logs | status | stop | restart`.
