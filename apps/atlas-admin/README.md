# atlas-admin — Atlas Command Center (iOS)

A native SwiftUI iPhone app (iOS 26, Liquid Glass) that is the mobile control
panel for the atlas homelab server. It streams live system metrics — CPU, GPU,
RAM, temperatures, power draw, disk, network, Docker containers — from the
companion Rust agent ([`../../agent`](../../agent), default port 8787) over a
Tailscale tailnet, and adds an exit-node/AdGuard stats page, a GitHub-style
activity heatmap, a Face-ID-gated PTY terminal (SwiftTerm over WebSocket), and
token-authenticated remote shutdown/restart.

The UI is in German. Lightshow control lives in its own app:
[`../atlas-lightshow`](../atlas-lightshow).

<p>
  <img src="AtlasCommandCenter/screenshot-idle.png" width="240">
  <img src="AtlasCommandCenter/screenshot-load.png" width="240">
</p>

## Tabs

- **Command** — status hero, CPU/GPU/RAM rings, temp/power/load chips, rolling
  60 s CPU+GPU and network charts, memory/disk bars, running containers,
  system info. Toolbar: terminal (top-left), settings and power actions
  (top-right, "⋯" menu).
- **Exit Node** — the server as the tailnet's exit node: animated shield, ads
  blocked and DNS query stats (AdGuard Home), tunnel hours, bytes protected,
  every tailnet peer with rx/tx.
- **"Aktivität"** — contribution heatmap of the server's awake hours
  (reconstructed from the systemd journal) or monorepo commits, plus streak,
  online hours, boots and commits over the last 30 days.

The terminal opens as a full-screen cover and requires Face ID (or the device
passcode) on every open; the WebSocket to the shell is only created after a
successful unlock.

## How it talks to the agent

All traffic is plain HTTP/WebSocket to `http://<host>` inside the tailnet
(see the trust model below). Endpoints used:

| Endpoint | Use |
|---|---|
| `GET /api/metrics` | Full metrics snapshot (2 s poll, fallback + hero data) |
| `GET /ws/metrics` (WebSocket) | Primary live stream: one JSON frame every 500 ms, preceded by a `{"history":[...]}` bootstrap of the agent's 10-minute ring buffer so charts are filled instantly |
| `GET /api/vpn` | Exit-node/AdGuard/peers payload (10 s poll) |
| `GET /api/activity` | Per-day online minutes/boots/commits |
| `POST /api/power/shutdown`, `POST /api/power/restart` | Power actions (confirmation alert in the app) |
| `GET /term` (WebSocket) | PTY: binary frames are terminal I/O, resize is sent as a text frame `{"resize":{"cols":C,"rows":R}}` |

Chart samples are smoothed with an EMA (α = 0.30); network rates are derived
client-side from the agent's cumulative rx/tx byte counters. While the socket
is down the app falls back to the 2 s HTTP poll and reconnects with a 2 s
backoff.

The token (if set) is sent as an `Authorization: Bearer` header on HTTP
requests and additionally as a `?token=` query parameter on the two WebSocket
URLs.

## Build & run

Requirements: macOS with Xcode 26+ (the code uses iOS 26 APIs — `.glassEffect`,
`.buttonStyle(.glassProminent)`, `Tab(value:)`, Swift Charts), an iPhone on
iOS 26.0+ (the target is iPhone-only, portrait), and an Apple Developer team
for signing. The agent must be running on the server — see
[`../../agent`](../../agent) and [docs/SETUP.md](../../docs/SETUP.md)
for the machine/Tailscale setup.

```bash
cd AtlasCommandCenter
open AtlasCommandCenter.xcodeproj     # the generated project is committed
```

The project is generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen)
from `project.yml`; regenerate only after editing the spec:

```bash
brew install xcodegen
xcodegen generate
```

In Xcode: select your iPhone as the destination, then **enable signing** — the
committed project ships with `CODE_SIGNING_ALLOWED = NO` and no team, so you
must actively turn signing on, pick your team, and typically change the bundle
id (`com.lukaloehr.AtlasCommandCenter`). SwiftTerm (1.14.0) resolves via SPM on
first build.

On first launch the settings sheet opens automatically: enter the agent host
(e.g. `atlas.your-tailnet.ts.net:8787`) and, if the agent runs with a token,
the token. The iPhone must be on the same tailnet as the server.

## Configuration

The app has no config files; everything lives in the in-app settings
("⋯ → Einstellungen") plus one debug hook:

| Setting | Default | Purpose |
|---|---|---|
| Host (`@AppStorage "atlas.host"`) | empty (settings sheet opens on first launch) | Agent address as `host:port`, e.g. `atlas.your-tailnet.ts.net:8787` |
| Token (`@AppStorage "atlas.token"`) | empty | Bearer token; must match the agent's `ATLAS_AGENT_TOKEN` |
| `ATLAS_TAB` (Xcode scheme env var) | `0` | Startup tab override: `0` Command, `1` Exit Node, `2` "Aktivität" |

Agent-side configuration (`ATLAS_AGENT_TOKEN`, `ATLAS_AGENT_PORT`,
`ATLAS_AGENT_BIND`, `ATLAS_AGENT_OPEN`) is documented in
[`../../agent`](../../agent).

## Security model

- **Transport** is plain HTTP/WS with an App Transport Security exception for
  `ts.net` (declared in `project.yml`, baked into `Sources/Info.plist`).
  Inside a tailnet this rides on WireGuard encryption; if your agent is not
  reachable under a `*.ts.net` name you need your own ATS exception.
- **Auth** is enforced by the agent, not the app: with `ATLAS_AGENT_TOKEN` set
  every request needs the token; without one, reads are open but power actions
  and the terminal are refused unless the agent explicitly runs with
  `ATLAS_AGENT_OPEN=1`. Anyone who can reach the agent can do whatever the
  agent's auth mode allows — restrict reachability with your tailnet ACL
  (e.g. `autogroup:self`).
- The **Face ID gate** on the terminal only locks the phone's UI. It is not
  server-side security; that is the agent token.
- The token is stored in `UserDefaults` (not the Keychain) and appears as a
  URL query parameter on the WebSocket URLs — use a dedicated token, not a
  shared secret.

## Layout

```
AtlasCommandCenter/
  project.yml              XcodeGen spec (bundle id, iOS 26 target, SwiftTerm,
                           Info.plist properties); the .xcodeproj it generates
                           is committed too
  Sources/
    App/                   @main + RootView (3 tabs, settings sheet, PowerAction)
    Model/                 Metrics (Codable mirror of /api/metrics), AtlasClient
                           (URLSession + WS URL builder), DashboardModel
                           (WS stream + poll fallback, EMA, net rates),
                           VPNModel, ActivityModel, Biometric (Face ID)
    Views/                 Theme + GlassCard, Components (RingGauge, StatChip,
                           UsageBar), StatusHero, DashboardScreen/DashboardView,
                           LoadChart + NetChart + ChartLive (Swift Charts,
                           live-interpolated), ContainersCard, VPNScreen,
                           ActivityScreen, TerminalScreen (SwiftTerm bridge),
                           SettingsView
```
