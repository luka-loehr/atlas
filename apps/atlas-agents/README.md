# atlas-agents — Atlas Agents (iOS)

SwiftUI app for watching the agent fleet from a phone. Paperclip stays the
backbone (agents, runs, documents, Postgres) and its web UI still does
everything; this app answers the two questions that are worth a phone screen:
*is anything running* and *is anything waiting on me*.

Read-only by design. Nothing in the app creates, approves or reassigns an
issue — those actions live in the Paperclip web UI on the tailnet.

## Screens

Three tabs (`RootView` in `ios/Sources/App/AtlasAgentsApp.swift`):

| Tab | What it does |
|---|---|
| **Now** | One headline line: how many agents are working. Then the issues whose curated `needsLuka` text is set, the fleet's current work items, and a warning when the snapshot is over 15 minutes old. The tab badge is the count of issues waiting on you |
| **Board** | Every issue grouped by status in attention order (being worked on → awaiting your look → waiting → not started → parked → finished), searchable by title, headline or key. Tap through to the full curated text and the commits linked to that issue |
| **Settings** | Paperclip host, bridge host and board key; Live Activity and report-notification toggles; company counters (agents, open tasks, open questions, spend); browsable Skills, Routines and Projects lists, with a **Run** button per routine; connection diagnostics |

The issue detail screen renders text written by the Curator agent on atlas —
*what it is*, *why it matters*, *where it stands*, and which commits belong to
it. Nothing on that screen is inferred client-side.

## Where the data comes from

Two services on the tailnet, both plain HTTP:

- **paperclip-bridge** (`:3111`, see
  [`../../agents/paperclip-bridge`](../../agents/paperclip-bridge)) serves the
  curated board — `GET /board/issues`, `/board/issues/{key}`, `/board/fleet` —
  plus `GET /asks` and `GET /spend`. `BoardStore` polls it every 30 s and it is
  the only source the three screens read for board content.
- **Paperclip** (`:3100`) serves the raw company API. `AppModel` polls
  `/dashboard`, `/agents`, `/issues`, `/artifacts`, `/activity` every 20 s for
  the counters, the Live Activity and the new-report notification; Settings
  additionally loads projects, skills and routines.

The bridge's SSE endpoint (`GET /stream`) is subscribed to as a freshness hint:
a `snapshot` or `delta` event triggers an immediate refresh. If the bridge is
down the app falls back to its timers, so a dead bridge degrades rather than
breaks.

## Widget, Live Activity, notifications

- **Home-screen widget** (small and medium): running agents, open and in-review
  counts, and the newest report title on medium. Reloads every 5 min while
  agents run, 20 min when idle.
- **Live Activity + Dynamic Island**: starts when at least one agent is running
  and ends when the fleet goes idle. Compact shows one glyph and the running
  count; the expanded presentation adds the lead agent, its task and how many
  things wait on you.
- **Background refresh** (`com.lukaloehr.AtlasAgents.refresh`, ~15 min) fires a
  local notification for a new ask and — if the toggle is on — for a new
  report. The first run seeds state silently instead of replaying history.

## Setup

`ios/Sources/Shared/Secrets.swift` is gitignored and holds the connection
details. A fresh clone does not build without it — create it from the tracked
template first:

```bash
cd ios
cp Sources/Shared/Secrets.example.swift Sources/Shared/Secrets.swift
```

Then fill in the four values. Mint the board key on atlas (needs an existing
board session or key):

```bash
curl -X POST http://atlas.<tailnet>.ts.net:3100/api/board-api-keys \
  -H "Authorization: Bearer $EXISTING" -H 'Content-Type: application/json' \
  -d '{"name":"ios-agents","expiresAt":null}'
```

Host and key are also editable at runtime in **Settings** (stored in
`UserDefaults`), so rotating the key needs no app rebuild — but see the widget
caveat below.

Paperclip must allow the hostname you connect to; it rejects unknown `Host`
headers *before* auth:

```bash
npx paperclipai allowed-hostname atlas.<tailnet>.ts.net   # then restart the service
```

## Build

The Xcode project is generated from `ios/project.yml`, so regenerate after
adding or removing a source file:

```bash
cd ios
xcodegen generate
xcodebuild -scheme AtlasAgents \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath build-sim build
```

Device installs additionally need **Developer Mode** on the iPhone (Settings →
Privacy & Security → Developer Mode → on, then reboot):

```bash
xcodebuild -scheme AtlasAgents -destination 'id=<device-udid>' \
  -derivedDataPath build-device -allowProvisioningUpdates build
```

No shared `.xcscheme` is checked in; Xcode autocreates `AtlasAgents` from the
generated project on first open, and `xcodebuild` accepts it once it exists.

## Layout

```
ios/
  project.yml                 xcodegen spec — two targets, AtlasAgents + AtlasAgentsWidgets
  Sources/
    App/                      AtlasAgentsApp (@main, BGTask, RootView), AppModel,
                              BoardStore, Theme
    Shared/                   compiled into BOTH targets: PaperclipAPI, BridgeAPI,
                              BoardAPI, LiveStream, AgentActivityAttributes, Secrets
    Views/                    NowScreen, BoardScreen, IssueDetailScreen, SettingsScreen
    Assets.xcassets/          app icon slot (see Known gaps)
  Widgets/                    AtlasAgentsWidgets — widget bundle + Live Activity
```

### Naming

Same convention as the other Atlas apps: `*Screen` is a full-surface
destination that owns its own `NavigationStack` — here the three tabs and the
pushed issue detail. Everything else is a component with a plain descriptive
name. The `View` suffix means one thing only: a type whose job is to wrap
UIKit, plus the app shell's `RootView` and the WidgetKit entry view
(`FleetWidgetView`).

## Known gaps

These are real and deliberate; do not treat them as bugs to be surprised by.

- **The widget cannot see Settings.** The extension has its own `UserDefaults`
  container and the project declares no App Group, so the widget uses the host
  and key compiled in from `Secrets.swift`. A rotated key takes effect in the
  app immediately and in the widget only after a rebuild. Fixing this means
  adding an App Group to both targets.
- **No app icon.** `Assets.xcassets/AppIcon.appiconset` declares the 1024×1024
  slot but no PNG is checked in. The build stays green and silent, and the
  result ships with no icon at all — the bundle has no `Assets.car` and no
  `CFBundleIcons`. The three sibling apps each track an `AppIcon.png`; drop one
  in and add its `filename` to `Contents.json` to close this.
- **Asks are read-only.** The bridge publishes open asks over `GET /asks` but
  routes nothing that answers one, so the app surfaces them (the *Now* badge,
  the "Open questions" counter) and they are answered on atlas instead.
- **`PaperclipAPI.swift` is a fuller client than the app uses.** It covers the
  Paperclip board API — approve, reassign, comment, run events, interactions —
  and most of that is uncalled, kept because it is the wire surface of an
  external API rather than app code.
- **`Sources/Shared` is compiled into the widget wholesale**, so the extension
  links the bridge and SSE clients it never calls. That keeps `Secrets.swift`
  and the Live Activity attributes in one place, at the cost of some dead
  weight in the appex.

## Notes

- Cleartext HTTP over the tailnet is allowed via the same `ts.net` ATS
  exception the other atlas apps use — connect by MagicDNS name, **not** by a
  `100.x` IP (a domain exception does not cover IP literals).
- `project.yml` carries a `DEVELOPMENT_TEAM`. This is the one atlas app that
  signs for device installs; replace it with your own Apple Team ID.
- The widget's `StaticConfiguration` kind is `"AgentsStatus"`. That string is a
  persistence key — changing it orphans widgets already placed on a device.
- iPhone only, portrait only, dark appearance only. UI language is English.
