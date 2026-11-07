# Atlas — the app for iPhone, iPad and Mac

One app for the whole server: the photo library, the drive, and the machine
itself. SwiftUI, English UI, one Xcode target with two destinations:

- **iPhone and iPad** (iOS 26.1): the tabs below.
- **Mac** (macOS 26): a native Mac app, not Mac Catalyst and not the iPad
  app in a window. It shares the model, cache and network layer with the
  iPhone app and has its own interface, see [The Mac app](#the-mac-app).

| Tab | |
|---|---|
| **Fotos** | the timeline as one grid, newest at the bottom, with pinch zoom, a month scrubber, the system context menu, multi-select and the full-screen viewer (zoom, swipe, video, info sheet with map, people and EXIF) |
| **Alben** | laid out like the Albums tab of Photos: your albums as a carousel of large covers (See All for the grid), people as round faces, then Media Types (favorites, videos) and Utilities (archive, locked with Face ID, recently deleted) as lists with counts |
| **Dateien** | the drive: folders, upload, previews, move, rename, trash |
| **Einstellungen** | backup status, what Atlas keeps on the phone (by kind), and the server: live status, services, containers, activity, network, power, a terminal (Face ID) |
| **Suche** | from Dateien it searches files; from every other tab people, places and albums by name, everything else by what is in the picture |

## Build

```bash
brew install xcodegen
cd app && xcodegen                      # regenerates Atlas.xcodeproj from project.yml
open Atlas.xcodeproj                    # pick your team under Signing, then run
```

Pick the run destination: an iPhone (or simulator), or **My Mac**. From the
command line:

```bash
xcodebuild -project app/Atlas.xcodeproj -scheme Atlas -destination 'platform=macOS' \
  -derivedDataPath build-mac -configuration Release \
  DEVELOPMENT_TEAM=<team> -allowProvisioningUpdates build
# build-mac/Build/Products/Release/Atlas.app
```

A debug build on the Mac connects from the environment, like the simulator:
`ATLAS_URL=… ATLAS_TOKEN=… build-mac/Build/Products/Debug/Atlas.app/Contents/MacOS/Atlas`.

The app embeds a widget extension (`AtlasWidget`) and shares the App Group
`group.com.lukaloehr.atlas.ios` with it, so signing needs a team that can
register the group: sign in under Xcode > Settings > Accounts, then build
with `DEVELOPMENT_TEAM=<team> -allowProvisioningUpdates`. A wildcard
profile cannot carry an App Group.

No server address or token is compiled in. On first launch the app asks for
both; `atlas connect` on the Mac prints an `atlas://connect?…` link that fills
them in. The address lives in the app's preferences, the token in the
keychain.

## Layout

`Atlas/` compiles for both platforms, `Atlas/iOS/` for iPhone and iPad only,
`Mac/` for the Mac only (`destinationFilters` in `project.yml`).

| Path | |
|---|---|
| `Atlas/iOS/AtlasApp.swift` | iOS entry point, tabs, the connect screen, background backup task, `atlas://photo|album` links |
| `Atlas/iOS/` | the iPhone interface (`Photos/Views`, `Settings`), `BackupService`, `WidgetShelf`, `SyncStatus` |
| `Atlas/Core/` | `Session` (server address + token), `API` (JSON and WebSocket client), formatting, `Platform` (UIKit/AppKit differences: images, colors, pasteboard, haptics, memory pressure) |
| `Atlas/Photos/Model/` | `Library` (timeline state and its on-disk cache), `PhotoClient` and `DriveClient`, `DeviceSync` (iPhone backup) |
| `Atlas/Photos/Model/Cache/` | the media cache: `MediaStore` (disk), `MediaFetch` (download queue), `MediaCache` (RAM, decoding, viewer look-ahead), `VideoCache` (streaming through the cache), `ThumbFill`, `CacheWarmer` |
| `Atlas/Photos/Model/ShareFiles.swift` | what Share hands the share sheet: originals named by date and people |
| `Atlas/Photos/Model/WidgetShelf.swift` | stages the Album widgets' photos in the App Group |
| `Shared/` | compiled into app and widget: `WidgetData` (the App Group layout), the widget's configuration intent and album entity |
| `AtlasWidget/` | the Album widget (WidgetKit extension) |
| `Atlas/Photos/Views/` | shared views: info sheet (the Mac's inspector), share links, add to album, face avatars |
| `Atlas/Settings/` | server status, storage bar, the terminal bridge (SwiftTerm on both platforms) |
| `Mac/` | the Mac app: `AtlasMacApp` (scenes), `AtlasCommands` (menu bar), `MacRootView` (sidebar window, people, search, connect), `Grid/` (the photo grid), `Photos/` (browser and viewer), `Files/`, `MacSettings` (Settings and Terminal windows) |

## The Mac app

Built to the macOS Human Interface Guidelines:

- **One window per ⌘N**, a split view: the sidebar (Photos, Albums,
  Utilities, Files, atlas) restores its selection on relaunch; the content;
  an **inspector** with the photo's info, map and people (⌘I).
- **The menu bar has every command**, with shortcuts: File (New Album ⌥⌘N,
  New Folder ⇧⌘N, Upload Files ⇧⌘I, Export Originals ⇧⌘E), Image (Favorite,
  Add to Album ⌃⌘A, Share as Link ⇧⌘L, Archive, Lock ⌃⌘L, Delete ⌘⌫), View
  (Show Info, Zoom In/Out ⌘+ ⌘−, Refresh ⌘R, sidebar and toolbar), Go
  (Library ⌘1 … Server ⌘7), Window (Terminal ⌥⌘T). Toolbars and context
  menus repeat them; unavailable items are disabled, not hidden.
- **The photo grid** is one view drawing a recycled pool of Core Animation
  layers (no view per cell). It never shows a blank cell: from the pinned
  WebP thumbnails (5 ms to decode) the Mac makes its own **grid tiles**
  once, in the background (`Mac/Grid/GridTiles.swift`, ~1 GB for 26,000
  photos): a 64 px mini of every photo in one memory-mapped file, shown the
  instant a cell appears, and a 256 px square JPEG (0.5 ms to decode) that
  replaces it a frame later and stays in RAM. A thumbnail made again on the
  server drops its tiles; the two largest zooms decode the 512 WebP.
  A click opens a photo; holding it for 300 ms selects it (the photo
  darkens over the hold); ⌘-click and ⇧-click select as everywhere on the
  Mac, a rectangle drawn from below the photos selects many, arrow keys (⇧
  extends), ⌘A, Return or Space open, `.` favorites. Pinching on the
  trackpad (or ⌘+ ⌘−) changes the size.
- **Drag and drop**: photos drag out as their originals (Finder, Mail, …)
  and onto an album in the sidebar; files drop into Files from the Finder to
  upload and drag out to download.
- **The viewer** zooms like Preview (pinch, double-click, scroll to pan),
  steps with ← → or a two-finger swipe, plays videos in the system player
  (Picture in Picture, full screen); Esc returns to the grid.
- **Files** is the Finder's list view: sortable columns, Finder icons, Quick
  Look with Space, Move to…, Deleted Files.
- **Settings** (⌘,) has panes for the server and storage; the **Terminal**
  opens in its own window after Touch ID or the login password, as does the
  Locked album.
- Sandboxed with the hardened runtime: network client, files the user
  picks or drops, Downloads (`Mac/Atlas.entitlements`). The backup of the
  photo library and the widget are iPhone features.

## Notes

- **The grid is laid out from an index.** The server sends month keys and
  counts first; the app computes the whole scroll height from that, opens at
  the bottom, and loads only the months on screen, from disk when it has them.
- **The grid is a `UICollectionView`** with recycled cells, off-main decoding
  at cell size and prefetching in the scroll direction.
- **Backup is a background service** with no button: it runs on launch, on
  return to the foreground, on photo-library changes and in background tasks.
  Originals are exported to files and uploaded through a background
  `URLSession`, so iOS finishes them after the app is closed. The server
  skips what it already has by content hash.
- **One media cache.** Every on-device copy of server media goes through
  `Photos/Model/Cache/`:
  - *Disk* (`MediaStore`): the 512 grid thumbnails are pinned, never
    evicted; `ThumbFill` downloads all of them once in the background
    (Wi-Fi, not in Low Power Mode). Everything else (2048 previews,
    originals, video bytes, face crops, drive thumbnails) shares a fixed
    15 GB budget in Caches. Eviction ranks by idle time × kind (faces age
    slowest, originals fastest), keeps photos of the last two months
    longest, never touches what is playing or was on screen in the last
    minute, and shrinks below the budget when the device runs short of
    space. Nothing to configure; Settings shows what Atlas stores, by kind.
  - *Downloads* (`MediaFetch`): one queue, visible > near > background,
    one shared job per file, cancelled when nobody wants it any more.
    Background work never uses cellular and waits while the user scrolls
    or swipes.
  - *RAM* (`MediaCache`): decoded bitmaps; all decoding off the main
    thread. The viewer keeps the previews of the 10 pages on either side
    (14 ahead) downloaded and decoded, the originals of ±2 downloaded and
    the first seconds of nearby videos fetched.
  - *Video* (`VideoCache`): the player reads through an
    `AVAssetResourceLoader` that serves cached byte ranges and fetches the
    rest with HTTP Range requests into a sparse file, so a prefetched head
    starts instantly and a watched video replays offline. Should that path
    fail, the player streams directly as before.
  - *Warming* (`CacheWarmer`): when idle on Wi-Fi, face crops of all
    people, the last three months' previews and the last month's video
    heads, while the cache has room.
- **Share never waits for what is on screen.** The viewer downloads the
  original of the page on screen (a video's too) at the highest priority as
  soon as it appears, and asks the server who is on it; the grid's context
  menu does the same while it is open. Share then hands over the local file
  at once and shows progress only when something really is missing. Files
  are named `Atlas 2026-09-28 20.56.heic`, or `Atlas – Mia 2026-09-28
  20.56.heic` with named people (up to three), plus ` 2`, ` 3` for several
  from one minute.
- **The Album widget** (small, medium, large) shows one album the user
  picks, or Recent Photos, a different photo every 45 minutes; a tap opens
  the photo in the viewer among the album's photos. It never touches the
  network or the token: `WidgetShelf` writes the album list (for the
  picker), a cover per album and up to 30 photos of every album a widget
  shows (~1000 px JPEGs from the cache's previews) into the App Group with a
  small manifest. It runs at launch, in the background processing task, and
  on return to the foreground (every half hour, or at once when a widget was
  set to an album it does not hold yet). Until then the widget shows the
  album's cover or asks to open Atlas. The widget decodes each photo at the
  size it fills, never larger.
- **Networking** allows plain HTTP only to local addresses and `*.ts.net`
  (the tailnet is already encrypted); see `project.yml`.
- The UI follows [docs/apple-design-guidelines.md](../docs/apple-design-guidelines.md).
