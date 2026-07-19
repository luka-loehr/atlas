# Atlas Command Center — iOS app

A native SwiftUI app (iOS 26, Liquid Glass) that shows atlas' live status —
CPU / GPU / RAM / temps / disk / load / docker containers — polled from
`atlas-agent` over the Tailnet. Your iPhone must be on the same tailnet.

<p>
  <img src="AtlasCommandCenter/screenshot-idle.png" width="240">
  <img src="AtlasCommandCenter/screenshot-load.png" width="240">
</p>

## Run it

```bash
# 1. the agent must be running on atlas (once; it's a systemd service):
atlas agent

# 2. generate the Xcode project + open it:
cd ios/AtlasCommandCenter
brew install xcodegen        # if needed
xcodegen generate
open AtlasCommandCenter.xcodeproj
```

Pick your iPhone as the run destination, set your signing team (the target is
`com.lukaloehr.AtlasCommandCenter`), and run. In-app **⋯ → Einstellungen** holds
the agent host (default `atlas.your-tailnet.ts.net:8787`) and an optional token.

## How it talks to atlas

`http://atlas.your-tailnet.ts.net:8787/api/metrics` → JSON snapshot, polled every
2 s. The agent is reachable only from your own devices (atlas is tailnet-isolated
via `autogroup:self`), so the metrics endpoint runs open. Power actions
(shutdown / restart) require a token — set `ATLAS_AGENT_TOKEN` in
`/etc/atlas-agent.env` on atlas and enter the same token in the app.

Plain HTTP over the tailnet needs an ATS exception for `ts.net` — it's in the
generated `Info.plist`.

## Layout

```
AtlasCommandCenter/
  project.yml            XcodeGen spec (source of truth; .xcodeproj is generated)
  Sources/
    App/                 @main app + root (nav, settings sheet, power menu)
    Model/               Metrics (Codable), AtlasClient (URLSession), DashboardModel (@Observable poller)
    Views/               Theme + GlassCard, RingGauge, StatChip, UsageBar,
                         StatusHero, LoadChart (Swift Charts), ContainersCard,
                         DashboardView, SettingsView
```

The matching server lives in [`../agent`](../agent) (`atlas-agent`, zero-dep Rust).
