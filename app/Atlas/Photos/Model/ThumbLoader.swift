import SwiftUI
import UIKit
import ImageIO
import os

/// The image pipeline of the app.
///
/// Where images come from, in order:
///   • decoded bitmaps in RAM (instant re-scroll),
///   • 512 grid thumbnails from `ThumbStore` (every one of them ends up on
///     the phone, see `ThumbFill`),
///   • 2048 previews and originals from `OriginalCache`,
///   • the server, whose answer is written to the store or cache on the way.
///
/// Reading files and decoding never happen on the main thread: they run on
/// one bounded operation queue, so a fling cannot saturate every core, and
/// work for a cell that scrolled away is cancelled before it starts. Grid
/// thumbnails are decoded at their on-screen pixel size.
@MainActor
final class ThumbLoader {
    static let shared = ThumbLoader()

    /// Grid cells, keyed "id@pixels".
    private let gridRam = NSCache<NSString, UIImage>()
    /// Thumbnails asked for by URL (album covers, search, filmstrip, …).
    private let urlRam = NSCache<NSString, UIImage>()
    /// 2048 previews and originals, kept apart so a few big viewer images
    /// cannot evict the grid working set.
    private let bigRam = NSCache<NSString, UIImage>()
    /// Local thumbnails of photos just taken on this iPhone, shown until the
    /// server's own thumbnail is in the store.
    private var seeds: [String: UIImage] = [:]

    nonisolated static let decodeQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "atlas.decode"
        q.qualityOfService = .userInitiated
        q.maxConcurrentOperationCount = max(2, ProcessInfo.processInfo.activeProcessorCount - 2)
        return q
    }()

    /// Thumbnails and originals are persisted by the store and the original
    /// cache, so their requests bypass the URL cache; only small other images
    /// (face crops) use it.
    nonisolated static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cfg.urlCache = URLCache(memoryCapacity: 8 << 20, diskCapacity: 256 << 20,
                                directory: caches.appendingPathComponent("ImageURLCache", isDirectory: true))
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        cfg.httpMaximumConnectionsPerHost = 8
        cfg.timeoutIntervalForRequest = 30
        return URLSession(configuration: cfg)
    }()

    nonisolated static let log = Logger(subsystem: "com.lukaloehr.Atlas", category: "Images")

    private init() {
        let budget = Int(ProcessInfo.processInfo.physicalMemory / 8)
        gridRam.totalCostLimit = min(budget, 320 << 20)
        gridRam.countLimit = 5000
        urlRam.totalCostLimit = 96 << 20
        urlRam.countLimit = 600
        bigRam.totalCostLimit = 200 << 20
        bigRam.countLimit = 12
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.gridRam.removeAllObjects()
                self.urlRam.removeAllObjects()
                self.bigRam.removeAllObjects()
            }
        }
        // the old pipeline kept up to 4 GB of thumbnails and originals in
        // the shared URL cache; the store and the original cache replace it
        if !UserDefaults.standard.bool(forKey: "images.legacyURLCacheCleared") {
            UserDefaults.standard.set(true, forKey: "images.legacyURLCacheCleared")
            UserDefaults.standard.removeObject(forKey: "thumbs.persistentCache")
            Task.detached(priority: .background) { URLCache.shared.removeAllCachedResponses() }
        }
    }

    // MARK: What a URL is

    enum Kind: Sendable {
        case thumb(String)          // 512, in ThumbStore
        case preview(String)        // 2048, in OriginalCache
        case original(String)       // original, in OriginalCache
        case other
    }

    /// "/v1/assets/{id}/thumb/512", "/v1/assets/{id}/thumb/2048",
    /// "/v1/assets/{id}/original".
    nonisolated static func kind(of url: URL) -> Kind {
        let p = url.pathComponents
        guard let i = p.lastIndex(of: "assets"), p.count > i + 2 else { return .other }
        let id = p[i + 1]
        switch p[i + 2] {
        case "thumb" where p.count > i + 3 && p[i + 3] == "512": return .thumb(id)
        case "thumb" where p.count > i + 3 && p[i + 3] == "2048": return .preview(id)
        case "original": return .original(id)
        default: return .other
        }
    }

    // MARK: Grid (UIKit cells)

    /// A grid thumbnail that is ready now, or nil.
    func gridImage(id: String, pixels: Int) -> UIImage? {
        gridRam.object(forKey: Self.gridKey(id, pixels) as NSString) ?? seeds[id]
    }

    private static func gridKey(_ id: String, _ pixels: Int) -> String { "\(id)@\(pixels)" }

    private final class GridJob {
        let key: String
        let id: String
        let pixels: Int
        var waiters: [Int: (UIImage?) -> Void] = [:]
        var operation: Operation?
        var network: Task<Void, Never>?
        var triedNetwork = false
        init(key: String, id: String, pixels: Int) { self.key = key; self.id = id; self.pixels = pixels }
    }

    /// Cancels its request when the cell no longer wants the image.
    final class Ticket {
        fileprivate let key: String
        fileprivate let token: Int
        fileprivate init(key: String, token: Int) { self.key = key; self.token = token }
        @MainActor func cancel() { ThumbLoader.shared.cancel(self) }
    }

    private var jobs: [String: GridJob] = [:]
    private var nextToken = 0
    var client = PhotoClient(host: "")

    /// Loads a grid thumbnail (store first, then server) decoded to fit a
    /// square cell of `pixels`. `done` runs on the main thread, unless the
    /// ticket was cancelled first. Requests for the same image share one job.
    func requestGrid(id: String, pixels: Int, urgent: Bool,
                     _ done: @escaping (UIImage?) -> Void) -> Ticket {
        let key = Self.gridKey(id, pixels)
        nextToken += 1
        let token = nextToken
        if let job = jobs[key] {
            job.waiters[token] = done
            if urgent, let op = job.operation, !op.isExecuting { op.queuePriority = .veryHigh }
        } else {
            let job = GridJob(key: key, id: id, pixels: pixels)
            job.waiters[token] = done
            jobs[key] = job
            decodeFromStore(job, urgent: urgent)
        }
        return Ticket(key: key, token: token)
    }

    private func cancel(_ ticket: Ticket) {
        guard let job = jobs[ticket.key] else { return }
        job.waiters[ticket.token] = nil
        guard job.waiters.isEmpty else { return }
        job.operation?.cancel()
        job.network?.cancel()
        jobs[ticket.key] = nil
    }

    private func decodeFromStore(_ job: GridJob, urgent: Bool) {
        let file = ThumbStore.shared.fileURL(job.id)
        let pixels = CGFloat(job.pixels)
        let op = BlockOperation()
        op.addExecutionBlock { [unowned op] in
            guard !op.isCancelled else { return }
            let img = Self.decode(file: file, maxPixel: pixels, fill: true)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { ThumbLoader.shared.decoded(job, img, fromStore: true) }
            }
        }
        op.queuePriority = urgent ? .veryHigh : .low
        job.operation = op
        Self.decodeQueue.addOperation(op)
    }

    private func decoded(_ job: GridJob, _ img: UIImage?, fromStore: Bool) {
        if let img {
            gridRam.setObject(img, forKey: job.key as NSString, cost: img.decodedCost)
            seeds[job.id] = nil
            finish(job, img)
            return
        }
        guard jobs[job.key] === job else { return }
        // not in the store (yet): fetch it from the server, store it, decode it
        guard !job.triedNetwork, let url = client.thumbURL(job.id, 512) else {
            if !fromStore { Self.log.error("grid thumb \(job.id, privacy: .public) could not be loaded") }
            finish(job, nil)
            return
        }
        if fromStore, ThumbStore.shared.has(job.id) {
            // on disk but undecodable: drop it and fetch it again
            ThumbStore.shared.remove(job.id)
        }
        job.triedNetwork = true
        let id = job.id
        let pixels = CGFloat(job.pixels)
        job.network = Task.detached(priority: .userInitiated) {
            var img: UIImage?
            do {
                let data = try await Self.fetchData(url)
                try? ThumbStore.shared.put(id, data)
                if !Task.isCancelled {
                    img = await Self.onDecodeQueue { Self.decode(data: data, maxPixel: pixels, fill: true) }
                }
            } catch {
                if !(error is CancellationError), (error as? URLError)?.code != .cancelled {
                    Self.log.error("grid thumb \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
            let result = img
            await MainActor.run { ThumbLoader.shared.decoded(job, result, fromStore: false) }
        }
    }

    private func finish(_ job: GridJob, _ img: UIImage?) {
        guard jobs[job.key] === job else { return }
        jobs[job.key] = nil
        for done in job.waiters.values { done(img) }
    }

    // MARK: By URL (SwiftUI views, viewer)

    private var prefetching: Set<URL> = []

    /// Warms images the viewer is about to show (its neighbours).
    func prefetch(_ urls: [URL]) {
        for url in urls where !prefetching.contains(url) && cached(url) == nil {
            prefetching.insert(url)
            Task(priority: .utility) {
                _ = await load(url)
                prefetching.remove(url)
            }
        }
    }

    private static func urlKey(_ url: URL, _ maxPixel: CGFloat?) -> NSString {
        "\(url.absoluteString)#\(Int(maxPixel ?? 0))" as NSString
    }

    private func ram(for kind: Kind) -> NSCache<NSString, UIImage> {
        switch kind {
        case .preview, .original: bigRam
        case .thumb, .other: urlRam
        }
    }

    /// A decoded image for `url` that is ready now.
    func cached(_ url: URL, maxPixel: CGFloat? = nil) -> UIImage? {
        let kind = Self.kind(of: url)
        if let img = ram(for: kind).object(forKey: Self.urlKey(url, maxPixel)) { return img }
        if case .thumb(let id) = kind { return seeds[id] }
        return nil
    }

    /// Puts a locally made thumbnail in place of the server's until that is
    /// on the phone (photos just taken here).
    func seed(_ url: URL, image: UIImage) {
        switch Self.kind(of: url) {
        case .thumb(let id): seeds[id] = image
        case let kind: ram(for: kind).setObject(image, forKey: Self.urlKey(url, nil), cost: image.decodedCost)
        }
    }

    /// Thumbnails, downsampled to `maxPixel` (longest side) if given.
    func load(_ url: URL, maxPixel: CGFloat? = nil) async -> UIImage? {
        await fetch(url, maxPixel: maxPixel)
    }

    /// Full-screen viewer image, downsampled to `maxPixel`.
    func loadFull(_ url: URL, maxPixel: CGFloat) async -> UIImage? {
        await fetch(url, maxPixel: maxPixel)
    }

    private func fetch(_ url: URL, maxPixel: CGFloat?) async -> UIImage? {
        if let img = cached(url, maxPixel: maxPixel) { return img }
        if Task.isCancelled { return nil }
        let kind = Self.kind(of: url)
        let img = await Self.produce(url, kind: kind, maxPixel: maxPixel)
        if let img {
            ram(for: kind).setObject(img, forKey: Self.urlKey(url, maxPixel), cost: img.decodedCost)
        }
        return img
    }

    /// Off the main thread: local file if there is one, else download (into
    /// the store or the original cache), then decode.
    nonisolated private static func produce(_ url: URL, kind: Kind, maxPixel: CGFloat?) async -> UIImage? {
        do {
            switch kind {
            case .thumb(let id):
                let file = ThumbStore.shared.fileURL(id)
                if let img = await onDecodeQueue({ decode(file: file, maxPixel: maxPixel, fill: false) }) { return img }
                let data = try await fetchData(url)
                try? ThumbStore.shared.put(id, data)
                return await onDecodeQueue { decode(data: data, maxPixel: maxPixel, fill: false) }

            case .preview(let id), .original(let id):
                let which: OriginalCache.Kind = if case .preview = kind { .preview } else { .original }
                if let file = OriginalCache.shared.file(id, which) {
                    if let img = await onDecodeQueue({ decode(file: file, maxPixel: maxPixel, fill: false) }) { return img }
                }
                let (tmp, resp) = try await session.download(for: AtlasAuth.request(url, timeoutInterval: 600))
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                    try? FileManager.default.removeItem(at: tmp)
                    throw URLError(.badServerResponse)
                }
                let ext = (resp.suggestedFilename as NSString?)?.pathExtension ?? ""
                if let kept = OriginalCache.shared.adopt(tmp, id: id, kind: which, ext: ext) {
                    return await onDecodeQueue { decode(file: kept, maxPixel: maxPixel, fill: false) }
                }
                defer { try? FileManager.default.removeItem(at: tmp) }
                return await onDecodeQueue { decode(file: tmp, maxPixel: maxPixel, fill: false) }

            case .other:
                var req = AtlasAuth.request(url)
                req.cachePolicy = .returnCacheDataElseLoad
                let (data, resp) = try await session.data(for: req)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                return await onDecodeQueue { decode(data: data, maxPixel: maxPixel, fill: false) }
            }
        } catch {
            if !(error is CancellationError), (error as? URLError)?.code != .cancelled {
                log.error("image \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            return nil
        }
    }

    nonisolated static func fetchData(_ url: URL) async throws -> Data {
        var req = AtlasAuth.request(url, timeoutInterval: 30)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, resp) = try await session.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { throw URLError(.badServerResponse) }
        return data
    }

    // MARK: Decoding

    nonisolated static func onDecodeQueue(_ work: @escaping @Sendable () -> UIImage?) async -> UIImage? {
        if Task.isCancelled { return nil }
        return await withCheckedContinuation { cont in
            decodeQueue.addOperation { cont.resume(returning: work()) }
        }
    }

    nonisolated static func decode(file: URL, maxPixel: CGFloat?, fill: Bool) -> UIImage? {
        let opts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithURL(file as CFURL, opts) else { return nil }
        return decode(src, maxPixel: maxPixel, fill: fill)
    }

    nonisolated static func decode(data: Data, maxPixel: CGFloat?, fill: Bool) -> UIImage? {
        let opts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithData(data as CFData, opts) else { return nil }
        return decode(src, maxPixel: maxPixel, fill: fill)
    }

    /// One pass: ImageIO decodes and downsamples together, applies the
    /// orientation, and the result is a finished bitmap, so nothing decodes
    /// at render time. `fill`: `maxPixel` is the SHORT side (an aspect-fill
    /// square cell), else the long side.
    nonisolated static func decode(_ src: CGImageSource, maxPixel: CGFloat?, fill: Bool) -> UIImage? {
        guard CGImageSourceGetCount(src) > 0 else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let w = (props?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
        let h = (props?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
        let long = max(w, h), short = max(min(w, h), 1)
        var target = long > 0 ? long : 4096
        if let maxPixel {
            target = fill ? min(long, (maxPixel * long / short).rounded(.up)) : min(long, maxPixel)
        }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(target, 1),
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let img = UIImage(cgImage: cg)
        return img.preparingForDisplay() ?? img
    }
}

extension UIImage {
    var decodedCost: Int { (cgImage?.bytesPerRow ?? 0) * (cgImage?.height ?? 0) }
}

/// A thumbnail that shows at once from memory, else appears when loaded.
/// `maxPixel` downsamples the decode (longest side).
struct Thumb: View {
    let url: URL?
    var maxPixel: CGFloat? = nil
    var body: some View { ThumbInner(url: url, maxPixel: maxPixel) }
}

private struct ThumbInner: View {
    let url: URL?
    var maxPixel: CGFloat?
    @State private var image: UIImage?

    init(url: URL?, maxPixel: CGFloat?) {
        self.url = url
        self.maxPixel = maxPixel
        // a cached image is there in the very first frame, no grey flash
        _image = State(initialValue: url.flatMap { ThumbLoader.shared.cached($0, maxPixel: maxPixel) })
    }

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
            if let c = ThumbLoader.shared.cached(url, maxPixel: maxPixel) {
                if image !== c { image = c }
                return
            }
            image = await ThumbLoader.shared.load(url, maxPixel: maxPixel)
        }
    }
}
