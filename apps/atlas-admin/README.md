# Atlas Command Center — iOS app

A native SwiftUI app (iOS 26, Liquid Glass) that shows atlas' live status —
CPU / GPU / RAM / temps / disk / load / docker containers — polled from
`atlas-agent` over the Tailnet. Your iPhone must be on the same tailnet.

Lightshow control lives in its own app now: [`../atlas-lightshow`](../atlas-lightshow).

<p>
  <img src="AtlasCommandCenter/screenshot-idle.png" width="240">
  <img src="AtlasCommandCenter/screenshot-load.png" width="240">
</p>

## Tabs

- **Command** — the dashboard: status hero, CPU/GPU/RAM rings, temp/power
  chips, rolling load chart, memory/disk bars, containers. Terminal (real PTY
  over WebSocket, SwiftTerm) top-left; settings + power actions top-right.
- **Exit Node** — atlas as the tailnet's safe tunnel: animated shield, ads
  blocked (AdGuard Home), hours in the tunnel, data protected, DNS query
  stats, every device on the tailnet with rx/tx.
- **Aktivität** — GitHub-style contribution heatmap of atlas' awake hours
  (reconstructed from the systemd journal) or monorepo commits, plus streak,
  online hours, boots and commits of the last 30 days.

## Run it

```bash
# 1. the agent must be running on the server (systemd service, see ../../agent):
systemctl status atlas-agent

# 2. generate the Xcode project + open it:
cd AtlasCommandCenter
brew install xcodegen        # if needed
xcodegen generate
open AtlasCommandCenter.xcodeproj
```

Pick your iPhone as the run destination, set your signing team (the target is
`com.lukaloehr.AtlasCommandCenter`), and run. In-app **⋯ → Einstellungen** holds
the agent host (e.g. `atlas.your-tailnet.ts.net:8787`) and an optional token.

## How it talks to atlas

`http://atlas.your-tailnet.ts.net:8787/api/metrics` → JSON snapshot, polled every
2 s; `/api/vpn` and `/api/activity` feed the two stats pages. The agent is
reachable only from your own devices (atlas is tailnet-isolated via
`autogroup:self`), so the read endpoints run open. Power actions
(shutdown / restart) require a token — set `ATLAS_AGENT_TOKEN` in
`/etc/atlas-agent.env` on atlas and enter the same token in the app.

Plain HTTP over the tailnet needs an ATS exception for `ts.net` — it's in the
generated `Info.plist`.

## Layout

```
AtlasCommandCenter/
  project.yml            XcodeGen spec (source of truth; .xcodeproj is generated)
  Sources/
    App/                 @main app + root (tabs, settings sheet, power menu)
    Model/               Metrics (Codable), AtlasClient (URLSession),
                         DashboardModel (@Observable poller), VPNModel,
                         ActivityModel
    Views/               Theme + GlassCard, RingGauge, StatChip, UsageBar,
                         StatusHero, LoadChart (Swift Charts), ContainersCard,
                         DashboardView, VPNScreen (shield hero + tiles),
                         ActivityScreen (contribution heatmap),
                         TerminalScreen, SettingsView
```

The matching server lives in [`../../agent`](../../agent) (`atlas-agent`, zero-dep Rust).
