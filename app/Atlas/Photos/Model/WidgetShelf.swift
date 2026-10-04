import Foundation
import ImageIO
import UniformTypeIdentifiers
import WidgetKit

/// Keeps the Album widgets' photos on the phone (`WidgetData`): the album
/// list for the widget's picker with a cover for each album, and for every
/// album a widget on the Home Screen shows, up to 30 of its photos,
/// downsampled from the 2048 previews of the media cache. Runs at launch,
/// on return to the foreground (at most every half hour) and in the
/// background processing task.
@MainActor
final class WidgetShelf {
    static let shared = WidgetShelf()

    static let perSet = 30
    /// Short side of a staged photo: sharp on a large widget, small in memory.
    nonisolated static let photoPixels: CGFloat = 1000
    nonisolated static let coverPixels: CGFloat = 600

    private var running: Task<Void, Never>?
    private var lastRun = Date.distantPast
    private var lastWanted = Set<String>()

    /// Runs when `force`d, half an hour after the last run, or at once when
    /// a widget was set to an album the shelf does not hold yet.
    func refresh(library: Library, force: Bool = false) async {
        if let running { await running.value; return }
        let wanted = await Self.wanted()
        guard force || Date().timeIntervalSince(lastRun) > 1800 || !wanted.isSubset(of: lastWanted) else { return }
        let task = Task { await run(library, wanted: wanted) }
        running = task
        await task.value
        running = nil
        lastRun = Date()
        lastWanted = wanted
    }

    /// The sets the widgets on the Home Screen show.
    private static func wanted() async -> Set<String> {
        let widgets = (try? await WidgetCenter.shared.currentConfigurations()) ?? []
        return Set(widgets.filter { $0.kind == WidgetData.kind }.map {
            $0.widgetConfigurationIntent(of: AlbumWidgetIntent.self)?.album?.id ?? WidgetData.recents
        })
    }

    private func run(_ library: Library, wanted: Set<String>) async {
        let client = library.client
        guard !client.host.isEmpty, let folder = WidgetData.folder else { return }
        let old = await Task.detached(priority: .utility) { WidgetData.read() }.value ?? .init()
        var manifest = WidgetData.Manifest()

        // every album with its cover, for the picker and an unfilled widget
        let albums = try? await client.albums()
        if let albums {
            let visible = albums.filter { !SpecialAlbum.isLocked($0.title) && !SpecialAlbum.isTrash($0.title) }
            for album in visible {
                var info = WidgetData.AlbumInfo(id: album.id, title: album.title, count: album.count, cover: nil)
                if let cover = album.cover {
                    let name = "c-\(cover).jpg"
                    if await stage(cover, as: name, in: folder, kind: .thumb, pixels: Self.coverPixels, priority: .background) {
                        info.cover = name
                    }
                }
                manifest.albums.append(info)
            }
        } else {
            manifest.albums = old.albums
        }

        // the photos of every album a widget shows
        for key in wanted {
            guard let assets = await candidates(key, library: library) else {
                if let kept = old.sets[key] { manifest.sets[key] = kept }
                continue
            }
            let picked = Self.pick(assets, keeping: old.sets[key] ?? [])
            var set: [WidgetData.Photo] = []
            for asset in picked {
                let name = "p-\(asset.id).jpg"
                // the first few over any network, so a new widget fills at
                // once; the rest when the phone is on Wi-Fi
                let priority: MediaFetch.Priority = set.count < 6 ? .near : .background
                if await stage(asset.id, as: name, in: folder, kind: .preview, pixels: Self.photoPixels, priority: priority) {
                    set.append(.init(id: asset.id, file: name, taken: asset.takenAt))
                }
            }
            if !set.isEmpty { manifest.sets[key] = set } else if let kept = old.sets[key] { manifest.sets[key] = kept }
        }

        let written = await Task.detached(priority: .utility) {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent("manifest.json").path)
        }.value
        guard manifest != old || !written else { return }
        let keep = Set(manifest.albums.compactMap(\.cover) + manifest.sets.values.flatMap { $0.map(\.file) } + ["manifest.json"])
        let snapshot = manifest
        await Task.detached(priority: .utility) {
            try? WidgetData.write(snapshot)
            // files no set or cover uses any more
            let fm = FileManager.default
            for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where !keep.contains(name) {
                try? fm.removeItem(at: folder.appendingPathComponent(name))
            }
        }.value
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetData.kind)
    }

    /// The photos a set chooses from: the newest of the library, or an
    /// album's. Videos only when an album has nothing else (their stills).
    private func candidates(_ key: String, library: Library) async -> [Asset]? {
        if key == WidgetData.recents {
            guard library.loaded || !library.assets.isEmpty else { return nil }
            return Array(library.assets.reversed().lazy.filter { !$0.isVideo }.prefix(Self.perSet))
        }
        guard let id = WidgetData.albumID(of: key),
              let assets = try? await library.client.albumAssets(id) else { return nil }
        let photos = assets.filter { !$0.isVideo }
        return photos.isEmpty ? assets : photos
    }

    /// Up to `perSet` photos spread over the album; those already shown
    /// keep their order, new ones join shuffled, so the rotation does not
    /// walk through the album in date order.
    private static func pick(_ assets: [Asset], keeping old: [WidgetData.Photo]) -> [Asset] {
        var chosen = assets
        if assets.count > perSet {
            let step = Double(assets.count) / Double(perSet)
            chosen = (0..<perSet).map { assets[Int(Double($0) * step)] }
        }
        let byID = Dictionary(chosen.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let kept = old.compactMap { byID[$0.id] }
        let keptIDs = Set(kept.map(\.id))
        return kept + chosen.filter { !keptIDs.contains($0.id) }.shuffled()
    }

    /// Writes `id`'s image (from the media cache, downloaded there first if
    /// needed) as a JPEG of `pixels` on its short side. True when the file
    /// is in place.
    private func stage(_ id: String, as name: String, in folder: URL, kind: MediaStore.Kind,
                       pixels: CGFloat, priority: MediaFetch.Priority) async -> Bool {
        let dest = folder.appendingPathComponent(name)
        guard let url = MediaCache.shared.client.thumbURL(id, kind == .thumb ? 512 : 2048) else { return false }
        return await Task.detached(priority: .utility) {
            if FileManager.default.fileExists(atPath: dest.path) { return true }
            guard let source = try? await MediaFetch.shared.file(.init(kind, id), from: url, priority: priority) else { return false }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return Self.downsample(source, to: dest, short: pixels)
        }.value
    }

    nonisolated private static func downsample(_ source: URL, to dest: URL, short: CGFloat) -> Bool {
        guard let src = CGImageSourceCreateWithURL(source as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue, w > 0, h > 0 else { return false }
        let long = max(w, h), shortSide = min(w, h)
        // short side to `short`, the long side at most twice that (panoramas)
        let target = min(long, (short * long / shortSide).rounded(.up), short * 2)
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: target,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return false }
        let tmp = dest.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).jpg")
        guard let out = CGImageDestinationCreateWithURL(tmp as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(out, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(out) else { try? FileManager.default.removeItem(at: tmp); return false }
        do {
            try FileManager.default.moveItem(at: tmp, to: dest)
            return true
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            return FileManager.default.fileExists(atPath: dest.path)
        }
    }
}
