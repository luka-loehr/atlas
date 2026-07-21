import SwiftUI
import UIKit
import ImageIO

/// Two-tier cache for images: decoded bitmaps in RAM (instant re-scroll), bytes
/// on disk via URLCache (immutable URLs = never invalidated). Both the network
/// fetch AND the decode happen off the main thread — a lazily-decoded UIImage
/// would otherwise decode on the main thread at render time and stall scrolling
/// / the full-screen pager (that was the "swipe blocks while the photo loads"
/// bug). Full-screen images are downsampled to a zoom-sufficient size so the
/// main thread never touches a 40-megapixel bitmap.
@MainActor
final class ThumbLoader {
    static let shared = ThumbLoader()

    private let ram = NSCache<NSURL, UIImage>()
    private let session: URLSession

    private init() {
        ram.countLimit = 500
        ram.totalCostLimit = 320 << 20        // ~320 MB of decoded pixels
        let cache = URLCache(memoryCapacity: 64 << 20, diskCapacity: 4 << 30, directory: nil)
        let cfg = URLSessionConfiguration.default
        cfg.urlCache = cache
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        session = URLSession(configuration: cfg)
        persistentEnabled = UserDefaults.standard.bool(forKey: "thumbs.persistentCache")
    }

    // MARK: Persistent store (user-triggered "download all")
    //
    // A deliberate, never-evicted on-disk copy of the grid thumbnails so the
    // whole library scrolls instantly and browses OFFLINE while atlas sleeps.
    // Keyed by the URL path+query (NOT the host) so it survives a LAN↔tailnet
    // host switch and the immutable `?v=` version busts stale entries.

    /// When on, every 512-thumb fetch is also written to the persistent store,
    /// so browsing fills gaps and freshly uploaded photos cache automatically.
    var persistentEnabled = false

    private let persistentDir: URL? = {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let dir = base.appendingPathComponent("ThumbCache", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private func persistentPath(_ url: URL) -> URL? {
        guard let dir = persistentDir else { return nil }
        let raw = url.path + "?" + (url.query ?? "")
        let name = String(raw.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) ? Character($0) : "_"
        })
        return dir.appendingPathComponent(name + ".thmb")
    }

    private func persistentData(_ url: URL) -> Data? {
        guard let p = persistentPath(url) else { return nil }
        return try? Data(contentsOf: p)
    }
    func hasPersistent(_ url: URL) -> Bool {
        guard let p = persistentPath(url) else { return false }
        return FileManager.default.fileExists(atPath: p.path)
    }
    private func writePersistent(_ url: URL, _ data: Data) {
        guard let p = persistentPath(url) else { return }
        try? data.write(to: p, options: .atomic)
    }

    /// Fetch (if missing) and persist one thumbnail. Returns false on failure.
    func ensurePersistent(_ url: URL) async -> Bool {
        if hasPersistent(url) { return true }
        guard let data = try? await session.data(from: url).0 else { return false }
        writePersistent(url, data)
        return true
    }

    func clearPersistent() {
        guard let dir = persistentDir else { return }
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func persistentStats() -> (count: Int, bytes: Int64) {
        guard let dir = persistentDir,
              let items = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return (0, 0) }
        var bytes: Int64 = 0
        for f in items {
            bytes += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return (items.count, bytes)
    }

    func setPersistentEnabled(_ on: Bool) {
        persistentEnabled = on
        UserDefaults.standard.set(on, forKey: "thumbs.persistentCache")
    }

    // MARK: Prefetch (aggressive precache)

    private var prefetchInflight: Set<URL> = []   // queued or fetching — no double-fetch
    private var prefetchQueue: [URL] = []
    private var prefetchActive = 0
    private let prefetchLimit = 6

    /// Warms both cache tiers for `urls` at background priority: the bytes land
    /// in URLCache (disk) and the decoded bitmap in the RAM cache, so a later
    /// `load` is instant. Already-cached and already-in-flight URLs are skipped;
    /// at most `prefetchLimit` fetches run concurrently.
    func prefetch(_ urls: [URL]) {
        for url in urls {
            guard ram.object(forKey: url as NSURL) == nil,
                  !prefetchInflight.contains(url) else { continue }
            prefetchInflight.insert(url)
            prefetchQueue.append(url)
        }
        pumpPrefetch()
    }

    private func pumpPrefetch() {
        while prefetchActive < prefetchLimit, !prefetchQueue.isEmpty {
            let url = prefetchQueue.removeFirst()
            prefetchActive += 1
            Task(priority: .background) { [weak self] in
                _ = await self?.fetch(url, maxPixel: nil)
                guard let self else { return }
                self.prefetchInflight.remove(url)
                self.prefetchActive -= 1
                self.pumpPrefetch()
            }
        }
    }

    func cached(_ url: URL) -> UIImage? { ram.object(forKey: url as NSURL) }

    /// Seeds the RAM cache with a locally generated image under a SERVER url —
    /// a fresh iPhone photo shows its on-device thumbnail instantly while the
    /// server one is still being generated; once the RAM entry is evicted the
    /// normal load path fetches the (visually identical) server thumb.
    func seed(_ url: URL, image: UIImage) {
        ram.setObject(image, forKey: url as NSURL, cost: image.decodedCost)
    }

    /// Grid thumbnails: fetched and fully decoded off-main.
    func load(_ url: URL) async -> UIImage? { await fetch(url, maxPixel: nil) }

    /// Full-screen viewer image: downsampled to `maxPixel` and decoded off-main
    /// so paging between photos never blocks on a huge main-thread decode.
    func loadFull(_ url: URL, maxPixel: CGFloat) async -> UIImage? {
        await fetch(url, maxPixel: maxPixel)
    }

    private func fetch(_ url: URL, maxPixel: CGFloat?) async -> UIImage? {
        let key = url as NSURL
        if let img = ram.object(forKey: key) { return img }
        // grid thumbs (maxPixel == nil): try the persistent store first — instant
        // and works with atlas offline
        if maxPixel == nil, let data = persistentData(url) {
            let decoded = await Task.detached(priority: .userInitiated) {
                Self.decode(data, maxPixel: nil)
            }.value
            if let img = decoded {
                ram.setObject(img, forKey: key, cost: img.decodedCost)
                return img
            }
        }
        guard let data = try? await session.data(from: url).0 else { return nil }
        // keep the full local set complete: persist grid thumbs when enabled
        if maxPixel == nil, persistentEnabled { writePersistent(url, data) }
        let img = await Task.detached(priority: .userInitiated) {
            Self.decode(data, maxPixel: maxPixel)
        }.value
        guard let img else { return nil }
        ram.setObject(img, forKey: key, cost: img.decodedCost)
        return img
    }

    /// Off-main decode. With `maxPixel`, ImageIO decodes + downsamples in one
    /// pass (`ShouldCacheImmediately` forces the decode now); otherwise the small
    /// thumb is prepared for display so nothing decodes at render time.
    nonisolated private static func decode(_ data: Data, maxPixel: CGFloat?) -> UIImage? {
        if let maxPixel {
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            ]
            if let src = CGImageSourceCreateWithData(data as CFData, nil),
               let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) {
                return UIImage(cgImage: cg)
            }
        }
        return UIImage(data: data)?.preparingForDisplay()
    }
}

private extension UIImage {
    /// Approx decoded byte cost for NSCache accounting.
    var decodedCost: Int { (cgImage?.bytesPerRow ?? 0) * (cgImage?.height ?? 0) }
}

/// A thumbnail cell that shows instantly from cache, else fades in on load.
struct Thumb: View {
    let url: URL?
    var body: some View {
        ThumbInner(url: url)
    }
}

private struct ThumbInner: View {
    let url: URL?
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Rectangle().fill(Color(uiColor: .secondarySystemFill))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            }
        }
        .clipped()   // scaledToFill must never bleed past the cell
        .contentShape(Rectangle())
        .task(id: url) {
            guard let url else { return }
            if let c = ThumbLoader.shared.cached(url) { image = c; return }
            image = await ThumbLoader.shared.load(url)
        }
    }
}

/// Drives the "Offline-Cache" settings: download every grid thumbnail into the
/// persistent store (with progress), show its size, delete it, top up new ones.
@MainActor
@Observable
final class ThumbCache {
    var downloading = false
    var done = 0
    var total = 0
    var storedCount = 0
    var storedBytes: Int64 = 0

    var enabled: Bool { ThumbLoader.shared.persistentEnabled }

    init() { refresh() }

    func refresh() {
        let s = ThumbLoader.shared.persistentStats()
        storedCount = s.count
        storedBytes = s.bytes
    }

    /// Download every not-yet-stored thumbnail (8 in parallel). Re-running only
    /// fetches the new ones — cheap file-exists check skips the rest.
    func downloadAll(urls: [URL]) async {
        guard !downloading, !urls.isEmpty else { return }
        ThumbLoader.shared.setPersistentEnabled(true)
        downloading = true
        done = 0
        total = urls.count
        var i = 0
        let chunk = 8
        while i < urls.count {
            let slice = Array(urls[i ..< min(i + chunk, urls.count)])
            await withTaskGroup(of: Void.self) { g in
                for u in slice { g.addTask { _ = await ThumbLoader.shared.ensurePersistent(u) } }
            }
            i += slice.count
            done = i
            if i % 240 < chunk { refresh() }
        }
        downloading = false
        refresh()
    }

    func clear() {
        ThumbLoader.shared.clearPersistent()
        ThumbLoader.shared.setPersistentEnabled(false)
        refresh()
    }
}
