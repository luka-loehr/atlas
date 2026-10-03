# Atlas — the iOS app

One app for the whole server: the photo library, the drive, and the machine
itself. SwiftUI, iOS 26, English UI.

| Tab | |
|---|---|
| **Fotos** | the timeline as one grid, newest at the bottom, with pinch zoom, a month scrubber, the system context menu, multi-select and the full-screen viewer (zoom, swipe, video, info sheet with map, people and EXIF) |
| **Alben** | your albums, people, and the utility folders: locked (Face ID), archive, trash |
| **Dateien** | the drive: folders, upload, previews, move, rename, trash |
| **Einstellungen** | backup status, the size of the original cache, and the server: live status, services, containers, activity, network, power, a terminal (Face ID) |
| **Suche** | from Dateien it searches files; from every other tab people, places and albums by name, everything else by what is in the picture |

## Build

```bash
brew install xcodegen
cd app && xcodegen                      # regenerates Atlas.xcodeproj from project.yml
open Atlas.xcodeproj                    # pick your team under Signing, then run
```

No server address or token is compiled in. On first launch the app asks for
both; `atlas connect` on the Mac prints an `atlas://connect?…` link that fills
them in. The address lives in the app's preferences, the token in the
keychain.

## Layout

| Path | |
|---|---|
| `Atlas/AtlasApp.swift` | entry point, tabs, the connect screen, background backup task |
| `Atlas/Core/` | `Session` (server address + token), `API` (JSON and WebSocket client), formatting |
| `Atlas/Photos/Model/` | `Library` (timeline state and its on-disk cache), `PhotoClient` and `DriveClient`, `ThumbLoader`, `DeviceSync` (iPhone backup) |
| `Atlas/Photos/Views/` | the timeline grid, viewer and pager, info sheet, search, albums, people, drive, settings |
| `Atlas/Settings/` | server status, activity, network, terminal |

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
- **Every grid thumbnail is kept on the phone.** They are downloaded once in
  the background (Wi-Fi, not in Low Power Mode) and the grid reads them from
  disk first.
- **Original cache.** Viewed originals and previews, and recent photos, stay
  on the phone up to the size picked under Einstellungen (off to 50 GB),
  least recently used first out.
- **Networking** allows plain HTTP only to local addresses and `*.ts.net`
  (the tailnet is already encrypted); see `project.yml`.
- The UI follows [docs/apple-design-guidelines.md](../docs/apple-design-guidelines.md).
