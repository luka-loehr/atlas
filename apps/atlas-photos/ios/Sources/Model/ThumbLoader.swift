import SwiftUI
import UIKit
import ImageIO

/// Bounds how many image decodes run at once (≈ cores − 1) so a fast fling can't
/// saturate every core and cook the phone. It only GATES; the decode itself runs
/// off the actor.
actor DecodeGate {
    private let limit: Int
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(_ n: Int) { limit = max(1, n) }

    func acquire() async {
        if active < limit { active += 1; return }
        await withCheckedContinuation { waiters.append($0) }   // slot handed over on release
    }
    func release() {
        if !waiters.isEmpty { waiters.removeFirst().resume() }   // pass the slot, active unchanged
        else { active -= 1 }
    }
}

/// Two-tier cache for images: decoded bitmaps in RAM (instant re-scroll), bytes
/// on disk via URLCache + an optional persistent grid store. Fetch AND decode
/// happen off the main thread and are bounded + cancellable, so recycled cells
/// stop working the moment they scroll off screen. Grid thumbs are downsampled
/// to their on-screen size so the main thread never holds a huge bitmap.
@MainActor
final class ThumbLoader {
    static let shared = ThumbLoader()
    private static let gate = DecodeGate(max(2, ProcessInfo.processInfo.activeProcessorCount - 1))

    private let ram = NSCache<NSURL, UIImage>()   // grid thumbs (the hot working set)
    private let bigRam = NSCache<NSURL, UIImage>() // 2048 previews / full — kept apart so a
                                                   // few big viewer images can't evict the grid
    private let session: URLSession

    private init() {
        ram.countLimit = 800
        // size the decoded-pixel budget to the device instead of a flat 320 MB
        let budget = Int(ProcessInfo.processInfo.physicalMemory / 6)
        ram.totalCostLimit = min(budget, 400 << 20)
        bigRam.countLimit = 8
        bigRam.totalCostLimit = 160 << 20
        let cache = URLCache(memoryCapacity: 16 << 20, diskCapacity: 4 << 30, directory: nil)
        let cfg = URLSessionConfiguration.default
        cfg.urlCache = cache
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        session = URLSession(configuration: cfg)
        persistentEnabled = UserDefaults.standard.bool(forKey: "thumbs.persistentCache")
        // drop the working set on memory pressure instead of thrashing toward OOM
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.ram.removeAllObjects()
                self.bigRam.removeAllObjects()
                self.session.configuration.urlCache?.removeAllCachedResponses()
            }
        }
    }

    // MARK: Persistent store (nonisolated: pure FS/string, safe off the MainActor)

    var persistentEnabled = false

    private static let persistentDir: URL? = {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let dir = base.appendingPathComponent("ThumbCache", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    nonisolated private static func persistentPath(_ url: URL) -> URL? {
        guard let dir = persistentDir else { return nil }
        let raw = url.path + "?" + (url.query ?? "")
        let name = String(raw.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) ? Character($0) : "_"
        })
        return dir.appendingPathComponent(name + ".thmb")
    }
    nonisolated private static func persistentData(_ url: URL) -> Data? {
        guard let p = persistentPath(url) else { return nil }
        return try? Data(contentsOf: p)
    }
    nonisolated func hasPersistent(_ url: URL) -> Bool {
        guard let p = Self.persistentPath(url) else { return false }
        return FileManager.default.fileExists(atPath: p.path)
    }
    nonisolated private static func writePersistent(_ url: URL, _ data: Data) {
        guard let p = persistentPath(url) else { return }
        try? data.write(to: p, options: .atomic)
    }

    func ensurePersistent(_ url: URL) async -> Bool {
        if hasPersistent(url) { return true }
        guard let data = try? await session.data(from: url).0 else { return false }
        Self.writePersistent(url, data)
        return true
    }
    func clearPersistent() {
        guard let dir = Self.persistentDir else { return }
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    func persistentStats() -> (count: Int, bytes: Int64) {
        guard let dir = Self.persistentDir,
              let items = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return (0, 0) }
        var bytes: Int64 = 0
        for f in items { bytes += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return (items.count, bytes)
    }
    func setPersistentEnabled(_ on: Bool) {
        persistentEnabled = on
        UserDefaults.standard.set(on, forKey: "thumbs.persistentCache")
    }

    // MARK: Prefetch (viewport-tracking — the window is REPLACED each move)

    private var prefetchInflight: Set<URL> = []
    private var prefetchQueue: [URL] = []
    private var prefetchActive: Set<URL> = []
    private let prefetchLimit = 6

    /// Append-style prefetch (used by the viewer for a few neighbours).
    func prefetch(_ urls: [URL]) {
        for url in urls {
            guard ram.object(forKey: url as NSURL) == nil,
                  !prefetchInflight.contains(url) else { continue }
            prefetchInflight.insert(url)
            prefetchQueue.append(url)
        }
        pumpPrefetch()
    }

    /// Grid prefetch: REPLACE the waiting queue with the current viewport window
    /// so the CPU never keeps chasing thumbnails the finger already flew past.
    func setPrefetchWindow(_ urls: [URL]) {
        let wanted = Set(urls)
        prefetchQueue.removeAll { !wanted.contains($0) }
        prefetchInflight = prefetchInflight.filter { wanted.contains($0) || prefetchActive.contains($0) }
        for url in urls {
            guard ram.object(forKey: url as NSURL) == nil,
                  !prefetchInflight.contains(url) else { continue }
            prefetchInflight.insert(url)
            prefetchQueue.append(url)
        }
        let cap = max(urls.count * 2, 16)
        if prefetchQueue.count > cap {
            for u in prefetchQueue[cap...] { prefetchInflight.remove(u) }
            prefetchQueue.removeLast(prefetchQueue.count - cap)
        }
        pumpPrefetch()
    }

    private func pumpPrefetch() {
        while prefetchActive.count < prefetchLimit, !prefetchQueue.isEmpty {
            let url = prefetchQueue.removeFirst()
            prefetchActive.insert(url)
            Task(priority: .background) { [weak self] in
                _ = await self?.fetch(url, maxPixel: 512, persist: true)
                guard let self else { return }
                self.prefetchActive.remove(url)
                self.prefetchInflight.remove(url)
                self.pumpPrefetch()
            }
        }
    }

    func cached(_ url: URL) -> UIImage? { ram.object(forKey: url as NSURL) }

    func seed(_ url: URL, image: UIImage) {
        ram.setObject(image, forKey: url as NSURL, cost: image.decodedCost)
    }

    /// Grid thumbnails: downsampled to `maxPixel` (the cell's pixel size) and
    /// fully decoded off-main. Reads/writes the persistent grid store.
    func load(_ url: URL, maxPixel: CGFloat? = nil) async -> UIImage? {
        await fetch(url, maxPixel: maxPixel, persist: true)
    }

    /// Full-screen viewer image: downsampled to `maxPixel`, kept in the separate
    /// big-image cache so it can't evict the grid working set.
    func loadFull(_ url: URL, maxPixel: CGFloat) async -> UIImage? {
        await fetch(url, maxPixel: maxPixel, persist: false)
    }

    private func fetch(_ url: URL, maxPixel: CGFloat?, persist: Bool) async -> UIImage? {
        let key = url as NSURL
        if let img = (persist ? ram : bigRam).object(forKey: key) { return img }
        if Task.isCancelled { return nil }

        // persistent grid store first — read + decode off-main and bounded
        if persist, hasPersistent(url) {
            if let img = await decodeGated(maxPixel: maxPixel, { Self.persistentData(url) }) {
                ram.setObject(img, forKey: key, cost: img.decodedCost)
                return img
            }
        }
        guard !Task.isCancelled, let data = try? await session.data(from: url).0 else { return nil }
        if persist, persistentEnabled {
            Task.detached(priority: .background) { Self.writePersistent(url, data) }
        }
        if Task.isCancelled { return nil }
        guard let img = await decodeGated(maxPixel: maxPixel, { data }) else { return nil }
        (persist ? ram : bigRam).setObject(img, forKey: key, cost: img.decodedCost)
        return img
    }

    /// Acquire a decode slot, run the (off-actor) decode, always release.
    private func decodeGated(maxPixel: CGFloat?, _ dataProvider: @escaping @Sendable () -> Data?) async -> UIImage? {
        await Self.gate.acquire()
        let img = await Task.detached(priority: .userInitiated) {
            guard let data = dataProvider() else { return nil as UIImage? }
            return Self.decode(data, maxPixel: maxPixel)
        }.value
        await Self.gate.release()
        return img
    }

    /// Off-main decode. With `maxPixel`, ImageIO decodes + downsamples in one
    /// pass; otherwise the thumb is prepared for display so nothing decodes at
    /// render time.
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
    var decodedCost: Int { (cgImage?.bytesPerRow ?? 0) * (cgImage?.height ?? 0) }
}

/// A thumbnail cell that shows instantly from cache, else fades in on load.
/// `maxPixel` downsamples the decode to the on-screen size (grid cells pass it).
struct Thumb: View {
    let url: URL?
    var maxPixel: CGFloat? = nil
    var body: some View { ThumbInner(url: url, maxPixel: maxPixel) }
}

private struct ThumbInner: View {
    let url: URL?
    var maxPixel: CGFloat?
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
        .clipped()
        .contentShape(Rectangle())
        .task(id: url) {
            guard let url else { return }
            if let c = ThumbLoader.shared.cached(url) { image = c; return }
            image = await ThumbLoader.shared.load(url, maxPixel: maxPixel)
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
