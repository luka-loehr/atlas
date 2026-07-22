# atlas-lightshow — Atlas Lightshow (iOS)

A standalone SwiftUI iPhone app (iOS 26, Liquid Glass) that remote-controls
the Atlas lightshow rig over a Tailscale tailnet. It talks exclusively to
[atlas-agent](../../agent/) via plain HTTP; the agent drives the
[Art-Net → Hue bridge](../../lightshows/bridge/) that owns the physical
fixtures, the fog Arduino and the laser/strobe smart plugs.

During a show the lights run on the server while the audio plays locally on
the phone (with an FFT-driven SceneKit visualizer), so light/sound sync
depends on the phone's audio latency — which the app can measure with its
camera and store server-side.

## Features

- **Shows** — browse shows on the server, play one (lights on the server,
  audio on the phone), stop. The player renders a 72-bar SceneKit ring
  visualizer fed by a 1024-point FFT (12 log-spaced bands) plus a
  music-reactive edge glow.
- **Show creation** — paste a YouTube URL; the server pipeline downloads the
  song, runs GPU beat analysis and either an AI composition pass
  (Gemini listens, Claude composes) or a rule-based compiler; the final
  commit-and-push only runs when the server opts in (`ATLAS_AUTOPUSH=1`
  in `lightshows/makeshow.py`). The sheet shows live phase progress (`download` → `analyze` →
  `gemini` → `claude` / `compile` → `commit` → `done`), including a streaming
  ticker of the AI output. The app polls status once per second for up to
  20 minutes.
- **Manual light board** ("Lichter" tab) — six RGB fixtures with tap-toggle
  and color picker, laser and strobe plug toggles, all-on/all-off. The board
  is pushed as a full 21-channel DMX frame (debounced 100 ms) that the agent
  holds and heartbeats to the bridge — no show required.
- **Fog** — hold-to-fog with a fail-safe protocol: while pressed, the app
  requests a short 1.5 s fog window every 0.5 s instead of one long window.
  If the release packet is lost or the app dies mid-press, fog self-stops
  within ~1.5 s. Release additionally sends two explicit stops 150 ms apart.
  Any refactor should preserve this invariant.
- **Latency calibration** — the server plays a dedicated `calibration` show
  (10 white flashes) while the phone plays the matching click track. The
  rear camera timestamps the flashes (top-3% luminance percentile, adaptive
  rising-edge detection, exposure biased dark and locked, 60 fps when
  supported); the audio engine timestamps the clicks including output
  latency (AirPods work). The median offset is saved on the server and
  applied to every future show.

The UI is German-language, portrait-only and dark-only.

## API surface

All requests go to `http://<host>/...` with an optional
`Authorization: Bearer <token>` header and an 8 s timeout
(`Sources/Model/AtlasClient.swift`; verified against `agent/src/main.rs`):

| Endpoint | Purpose |
|---|---|
| `GET /api/shows` | show list + bridge status |
| `POST /api/shows/start` (body: name) · `POST /api/shows/stop` | playback |
| `GET /api/shows/audio/<name>` · `GET /api/shows/thumb/<name>` | show audio / cover |
| `POST /api/shows/create` (body: `ai <url>` or `<url>`) | start the YouTube pipeline |
| `GET /api/shows/create/status` · `GET /api/shows/create/thumb` | live pipeline progress / thumbnail |
| `GET /api/lights` · `POST /api/lights/set` (body: 21 comma-separated 0–255 values) · `POST /api/lights/off` | manual board |
| `POST /api/fog` (body: window in ms) · `POST /api/fog/stop` | fog |
| `POST /api/calibrate/save` (body: latency in ms) | store measured audio latency |
| `POST /api/bridge/stop` | power off the bridge (toolbar power button) |

DMX channel map (1-based, must match the bridge): `1–18` six RGB fixtures ×
R,G,B; `19` fog (the manual board always sends 0 here — fog only via
`/api/fog`); `20` laser plug; `21` strobe plug.

Transport is deliberately plain HTTP: encryption and authentication come
from the tailnet (WireGuard). The App Transport Security exception in
`Sources/Info.plist` is scoped to `ts.net` only, so iOS blocks accidental
cleartext to any non-Tailscale host.

## Build & run

Requires a Mac with Xcode 26 (iOS 26 SDK — the app uses `.glassEffect` /
`.glassProminent`) and an iPhone on iOS 26 for device runs. The generated
Xcode project is committed, so XcodeGen is only needed after editing
`project.yml`:

```bash
cd apps/atlas-lightshow/AtlasLightshow
open AtlasLightshow.xcodeproj

# only after changing project.yml:
brew install xcodegen
xcodegen generate
```

The committed project sets `CODE_SIGNING_ALLOWED=NO` and contains no team:

- **Simulator** builds run unsigned as-is.
- **Device** builds need signing enabled manually in Xcode (target →
  Signing & Capabilities: enable signing, pick your team). Forks should
  also change the bundle identifier (`com.lukaloehr.AtlasLightshow`).
  Note: `xcodegen generate` resets these changes.

There are no tests and no CI; this is an Xcode-only target.

On first launch the app opens the Settings sheet automatically (no host is
configured). Enter the agent host, e.g. `atlas.your-tailnet.ts.net:8787`,
and a token if the agent runs with `ATLAS_AGENT_TOKEN`. The iPhone must be
on the same tailnet as the server (Tailscale app installed and joined).

## Configuration

In-app settings (persisted via `@AppStorage` in `UserDefaults`):

| Key | Default | Purpose |
|---|---|---|
| `atlas.host` | empty (Settings opens on first launch) | `host:port` of atlas-agent, e.g. `atlas.your-tailnet.ts.net:8787` |
| `atlas.token` | empty | Bearer token; only needed when the agent sets `ATLAS_AGENT_TOKEN` |

Xcode scheme environment variables (demo/screenshot hooks, optional):

| Variable | Default | Purpose |
|---|---|---|
| `ATLAS_TAB` | `0` | initial tab index (`1` = Lichter) |
| `ATLAS_DEMO_SHOW` | unset | auto-open the named show's player after the list loads |

Server-side configuration (ports, tokens, hardware) belongs to
[atlas-agent](../../agent/) and the [lightshows](../../lightshows/) rig;
machine-level setup (Ubuntu, Tailscale, CUDA, Docker) is covered in
[docs/SETUP.md](../../docs/SETUP.md).

## Operational notes

- **Calibration prerequisites**: a show named `calibration` must exist on
  the server — the repo ships it (`lightshows/shows/calibration.show.json`
  + `calibration.wav`). `CalibrationView` hardcodes its click schedule
  (10 clicks at t = 1, 3, …, 19 s), so the show and the app must stay in
  sync. At least 4 of 10 flashes must be matched for a result; the saved
  value lands in `lightshows/calibration.json` and overrides each
  show's baked-in `audio_latency_ms` (see `lightshows/play.py`); the
  calibration show itself always runs uncalibrated. Camera
  permission is required (usage string in `Info.plist`).
- **Bridge cold start**: when the bridge is down, the first light/show
  command starts it and takes ~4 s; the Shows and Lichter tabs surface this
  as a status row.
- **Token storage**: the token lives in `UserDefaults`, not the Keychain,
  and is sent as a Bearer header over cleartext HTTP. That is acceptable
  inside a tailnet, but do not expose the agent beyond it.
- **Physical hardware**: anyone on the tailnet (with the token, if set) can
  trigger fog, strobe and laser. Keep the fog fail-safe protocol intact.

## Layout

```
AtlasLightshow/
  project.yml              XcodeGen spec (edit this, then regenerate)
  AtlasLightshow.xcodeproj Generated project (committed)
  Sources/
    Info.plist             ATS exception (ts.net), camera usage, portrait/dark
    App/AtlasLightshowApp.swift   @main, tabs (Shows/Lichter), settings sheet
    Model/
      AtlasClient.swift    URLSession client + API DTOs
      LightsModel.swift    manual board state, 21-channel frame, debounced push
      ShowAudio.swift      audio download/playback, FFT bands, latency anchor
    Views/
      ShowsScreen.swift    show list, bridge badge, create/calibration entry
      ShowPlayerView.swift player, EdgeGlow, FogHoldButton
      VisualizerView.swift SceneKit ring visualizer
      CreateShowSheet.swift YouTube pipeline UI
      CalibrationView.swift flash detection + offset math
      LightsScreen.swift   lamp grid, effect cards, fog
      SettingsView.swift   host + token form
      Theme.swift          colors, background, GlassCard
```
