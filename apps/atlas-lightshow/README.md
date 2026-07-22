# Atlas Lightshow — iOS app

The standalone lightshow controller (SwiftUI, iOS 26 Liquid Glass), split out
of the Atlas admin app. Everything that makes the room glow lives here:

- **Shows** — browse, play (lights on atlas, sound on the iPhone, 3D
  visualizer + edge glow), create new shows from a YouTube link with the
  Gemini + Claude AI composer, live progress included.
- **Lichter** — manual control for every fixture, no show required: six RGB
  lamps with color picker, laser + strobe plugs, all held by the agent as a
  30 Hz Art-Net frame through the bridge.
- **Nebel** — hold-to-fog, fail-safe: while pressed the app renews short fog
  windows (1.5 s every 0.5 s), so fog stops within ~1.5 s even if the release
  packet is lost or the app dies mid-press.
- **Kalibrierung** — camera-based audio latency measurement (atlas flashes,
  the phone listens to its own clicks; the median offset tunes every show).

## Run it

```bash
cd AtlasLightshow
brew install xcodegen        # if needed
xcodegen generate
open AtlasLightshow.xcodeproj
```

Pick your iPhone, set your signing team (target
`com.lukaloehr.AtlasLightshow`), run. Settings (gear on the Shows tab) hold
the agent host (e.g. `atlas.your-tailnet.ts.net:8787` — empty on first launch,
the app opens Settings for you) and optional token — same agent, same tailnet
as the admin app.

Optional Xcode scheme environment variables for demos/screenshots:
`ATLAS_TAB=1` starts on the Lichter tab, `ATLAS_DEMO_SHOW=<name>` auto-opens
that show's player.

## How it talks to atlas

Everything goes through `atlas-agent` (`../../agent`):

| endpoint | what |
|---|---|
| `GET /api/shows` · `POST /api/shows/start|stop` | shows on disk, playback |
| `POST /api/shows/create` (+ `/status`, `/thumb`) | YouTube → show pipeline |
| `GET /api/lights` · `POST /api/lights/set|off` | manual 21-channel DMX frame |
| `POST /api/fog` · `POST /api/fog/stop` | hold-to-fog |
| `POST /api/calibrate/save` | audio latency |

The agent heartbeats the manual frame to the Art-Net→Hue bridge
(`../../lightshows/bridge`), which owns the Hue DTLS stream, the fog Arduino
and the laser/strobe plugs. Channel map: 6×RGB (1–18), fog (19), laser (20),
strobe plug (21).

## Layout

```
AtlasLightshow/
  project.yml            XcodeGen spec (source of truth; .xcodeproj is generated)
  Sources/
    App/                 @main app + tabs (Shows, Lichter) + settings sheet
    Model/               AtlasClient (URLSession), LightsModel (manual board),
                         ShowAudio (AVAudioEngine + FFT for the visualizer)
    Views/               Theme (violet/pink stage look), ShowsScreen,
                         ShowPlayerView (+ EdgeGlow, FogHoldButton),
                         VisualizerView (SceneKit), CreateShowSheet,
                         CalibrationView, LightsScreen (lamp grid + effects)
```
