import SwiftUI
import UIKit
import ImageIO
import os

/// The image side of the media cache: what every view asks for a picture.
///
/// Where images come from, in order:
///   • decoded bitmaps in RAM (instant re-scroll, the viewer's look-ahead),
///   • files in `MediaStore`: the pinned 512 grid thumbnails, then 2048
///     previews, originals, face crops and drive thumbnails in the budget,
///   • the server, through `MediaFetch` (one queue, priorities, shared and
///     cancellable jobs), whose answer is written to the store on the way.
///
/// Reading files and decoding never happen on the main thread: they run on
/// one bounded operation queue, so a fling cannot saturate every core, and
/// work for a cell that scrolled away is cancelled before it starts. Grid
/// thumbnails are decoded at their on-screen pixel size, viewer images at
/// the size they fill the screen with.
@MainActor
final class MediaCache {
    static let shared = MediaCache()

    /// Grid cells, keyed "id@pixels".
    private let gridRam = NSCache<NSString, UIImage>()
    /// Small images asked for by URL (album covers, search, filmstrip, faces).
    private let urlRam = NSCache<NSString, UIImage>()
    /// 2048 previews and originals, kept apart so a few big viewer images
    /// cannot evict the grid working set.
    private let bigRam = NSCache<NSString, UIImage>()
    /// The viewer's look-ahead: previews of the pages around the current
    /// one, decoded and held until they leave the window.
    private var windowRam: [NSString: UIImage] = [:]
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

    nonisolated static let log = Logger(subsystem: "com.lukaloehr.Atlas", category: "Images")

    var client = PhotoClient(host: "")

    private init() {
        let memory = ProcessInfo.processInfo.physicalMemory
        gridRam.totalCostLimit = min(Int(memory / 8), 320 << 20)
        gridRam.countLimit = 5000
        urlRam.totalCostLimit = 96 << 20
        urlRam.countLimit = 600
        bigRam.totalCostLimit = 200 << 20
        bigRam.countLimit = 12
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let me = MediaCache.shared
                me.gridRam.removeAllObjects()
                me.urlRam.removeAllObjects()
                me.bigRam.removeAllObjects()
                me.windowRam.removeAll()
            }
        }
        // the first pipeline kept up to 4 GB of thumbnails and originals in
        // the shared URL cache; the store replaces it
        if !UserDefaults.standard.bool(forKey: "images.legacyURLCacheCleared") {
            UserDefaults.standard.set(true, forKey: "images.legacyURLCacheCleared")
            UserDefaults.standard.removeObject(forKey: "thumbs.persistentCache")
            Task.detached(priority: .background) { URLCache.shared.removeAllCachedResponses() }
        }
        MediaStore.shared.warmUp()
    }

    // MARK: What a URL is

    /// "/v1/assets/{id}/thumb/512|2048", "/v1/assets/{id}/original",
    /// "/v1/faces/{id}/crop", "/v1/drive/files/{id}/thumb"; nil for
    /// anything else.
    nonisolated static func key(of url: URL) -> MediaStore.Key? {
        let p = url.pathComponents
        if let i = p.lastIndex(of: "assets"), p.count > i + 2 {
            let id = p[i + 1]
            switch p[i + 2] {
            case "thumb" where p.count > i + 3 && p[i + 3] == "512": return .init(.thumb, id)
            case "thumb" where p.count > i + 3 && p[i + 3] == "2048": return .init(.preview, id)
            case "original": return .init(.original, id)
            default: return nil
            }
        }
        if let i = p.lastIndex(of: "faces"), p.count > i + 2, p[i + 2] == "crop" { return .init(.face, p[i + 1]) }
        if let i = p.lastIndex(of: "files"), i > 0, p[i - 1] == "drive", p.count > i + 2, p[i + 2] == "thumb" {
            return .init(.driveThumb, p[i + 1])
        }
        return nil
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
        @MainActor func cancel() { MediaCache.shared.cancel(self) }
    }

    private var jobs: [String: GridJob] = [:]
    private var nextToken = 0

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
        // the path of a pinned thumbnail is fixed: decode it straight away,
        // a miss costs one failed open
        let file = MediaStore.shared.thumbURL(job.id)
        let pixels = CGFloat(job.pixels)
        let op = BlockOperation()
        op.addExecutionBlock { [unowned op] in
            guard !op.isCancelled else { return }
            let img = Self.decode(file: file, maxPixel: pixels, fill: true)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { MediaCache.shared.decoded(job, img, fromStore: true) }
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
        job.triedNetwork = true
        let id = job.id
        let pixels = CGFloat(job.pixels)
        job.network = Task.detached(priority: .userInitiated) {
            var img: UIImage?
            let key = MediaStore.Key(.thumb, id)
            do {
                // on disk but undecodable: drop it and fetch it again
                if fromStore, MediaStore.shared.contains(key) { MediaStore.shared.remove(key) }
                let file = try await MediaFetch.shared.file(key, from: url, priority: .visible)
                img = await Self.onDecodeQueue(.veryHigh) { Self.decode(file: file, maxPixel: pixels, fill: true) }
            } catch {
                if !Self.isCancellation(error) {
                    Self.log.error("grid thumb \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
            let result = img
            await MainActor.run { MediaCache.shared.decoded(job, result, fromStore: false) }
        }
    }

    private func finish(_ job: GridJob, _ img: UIImage?) {
        guard jobs[job.key] === job else { return }
        jobs[job.key] = nil
        for done in job.waiters.values { done(img) }
    }

    // MARK: By URL (SwiftUI views, viewer)

    private var prefetching: Set<URL> = []

    /// Warms small images about to be shown (faces of the People screens).
    func prefetch(_ urls: [URL], maxPixel: CGFloat? = nil) {
        for url in urls where !prefetching.contains(url) && cached(url, maxPixel: maxPixel) == nil {
            prefetching.insert(url)
            Task(priority: .utility) {
                _ = await fetch(url, maxPixel: maxPixel, priority: .near)
                prefetching.remove(url)
            }
        }
    }

    private static func urlKey(_ url: URL, _ maxPixel: CGFloat?) -> NSString {
        "\(url.absoluteString)#\(Int(maxPixel ?? 0))" as NSString
    }

    private func ram(for key: MediaStore.Key?) -> NSCache<NSString, UIImage> {
        switch key?.kind {
        case .preview, .original: bigRam
        default: urlRam
        }
    }

    /// A decoded image for `url` that is ready now.
    func cached(_ url: URL, maxPixel: CGFloat? = nil) -> UIImage? {
        let k = Self.urlKey(url, maxPixel)
        if let img = windowRam[k] { return img }
        let key = Self.key(of: url)
        if let img = ram(for: key).object(forKey: k) { return img }
        if let key, key.kind == .thumb { return seeds[key.id] }
        return nil
    }

    /// Puts a locally made thumbnail in place of the server's until that is
    /// on the phone (photos just taken here).
    func seed(_ url: URL, image: UIImage) {
        let key = Self.key(of: url)
        if let key, key.kind == .thumb { seeds[key.id] = image; return }
        ram(for: key).setObject(image, forKey: Self.urlKey(url, nil), cost: image.decodedCost)
    }

    /// Thumbnails, downsampled to `maxPixel` (longest side) if given.
    func load(_ url: URL, maxPixel: CGFloat? = nil) async -> UIImage? {
        await fetch(url, maxPixel: maxPixel, priority: .visible)
    }

    /// Full-screen viewer image, downsampled to `maxPixel`.
    func loadFull(_ url: URL, maxPixel: CGFloat) async -> UIImage? {
        await fetch(url, maxPixel: maxPixel, priority: .visible)
    }

    private func fetch(_ url: URL, maxPixel: CGFloat?, priority: MediaFetch.Priority) async -> UIImage? {
        if let img = cached(url, maxPixel: maxPixel) { return img }
        if Task.isCancelled { return nil }
        let key = Self.key(of: url)
        let img = await Self.produce(url, key: key, maxPixel: maxPixel, priority: priority)
        if let img {
            ram(for: key).setObject(img, forKey: Self.urlKey(url, maxPixel), cost: img.decodedCost)
        }
        return img
    }

    /// Off the main thread: local file if there is one, else download (into
    /// the store), then decode.
    nonisolated private static func produce(_ url: URL, key: MediaStore.Key?, maxPixel: CGFloat?,
                                            priority: MediaFetch.Priority) async -> UIImage? {
        let queuePriority: Operation.QueuePriority = priority == .visible ? .veryHigh : .low
        do {
            guard let key else {
                // not media the store knows: load it, keep it in RAM only
                let (data, resp) = try await MediaFetch.shared.session.data(for: AtlasAuth.request(url, timeoutInterval: 30))
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                return await onDecodeQueue(queuePriority) { decode(data: data, maxPixel: maxPixel, fill: false) }
            }
            if key.kind == .thumb {
                let file = MediaStore.shared.thumbURL(key.id)
                if let img = await onDecodeQueue(queuePriority, { decode(file: file, maxPixel: maxPixel, fill: false) }) { return img }
            }
            let file = try await MediaFetch.shared.file(key, from: url, priority: priority)
            if let img = await onDecodeQueue(queuePriority, { decode(file: file, maxPixel: maxPixel, fill: false) }) { return img }
            // on disk but undecodable: drop it, so the next look fetches it again
            if !Task.isCancelled { MediaStore.shared.remove(key) }
            return nil
        } catch {
            if !isCancellation(error) {
                log.error("image \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            return nil
        }
    }

    nonisolated static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    // MARK: Viewer look-ahead

    /// What the viewer keeps ready around the current page: 2048 previews
    /// downloaded and decoded, originals downloaded, video heads streamed.
    private var windowTickets: [String: MediaFetch.Ticket] = [:]
    private var windowWanted: Set<NSString> = []

    /// The pixel size a viewer page shows `asset` at: its aspect-fit size on
    /// this screen in either orientation, at most the preview's 2048. The
    /// look-ahead decodes at this size, and the page asks for the same, so
    /// it finds the decoded image.
    static func viewerPixels(_ asset: Asset) -> CGFloat {
        let screen = UIScreen.main
        let long = max(screen.bounds.width, screen.bounds.height) * screen.scale
        let short = min(screen.bounds.width, screen.bounds.height) * screen.scale
        let w = CGFloat(max(asset.width ?? 3, 1)), h = CGFloat(max(asset.height ?? 4, 1))
        let fit = { (sw: CGFloat, sh: CGFloat) in max(w, h) * min(sw / w, sh / h) }
        return min(2048, max(fit(short, long), fit(long, short)).rounded(.up))
    }

    /// Moves the viewer's window to `index`: previews of the 10 pages on
    /// either side (14 ahead in the direction of travel), originals of the
    /// 2 nearest photos, the first seconds of the videos among them. What
    /// fell out of the window is cancelled and released.
    func viewerFocus(_ pages: [Asset], index: Int, forward: Bool) {
        guard !pages.isEmpty, !client.host.isEmpty else { return }
        let ahead = 14, behind = 10
        // decoded previews cost about 7 MB each; small phones hold fewer
        let decodeReach = ProcessInfo.processInfo.physicalMemory >= 5 << 30 ? ahead : 4
        var order: [(Int, Int)] = []        // (page, distance)
        for d in 0...ahead {
            let next = forward ? index + d : index - d
            let prev = forward ? index - d : index + d
            order.append((next, d))
            if d > 0, d <= behind { order.append((prev, d)) }
        }
        var wantedTickets: [String: MediaFetch.Ticket] = [:]
        var wantedImages: Set<NSString> = []
        var originals: [(String, URL)] = []
        for (i, d) in order {
            guard let asset = pages[safe: i] else { continue }
            let id = asset.id
            if asset.isVideo {
                let name = "head:\(id)"
                if let url = client.streamURL(id) {
                    wantedTickets[name] = windowTickets[name]
                        ?? VideoCache.shared.prefetchHead(id: id, remote: url, duration: asset.durationS,
                                                          priority: .near, expensive: true)
                }
                continue
            }
            guard let url = client.thumbURL(id, 2048) else { continue }
            let px = Self.viewerPixels(asset)
            let k = Self.urlKey(url, px)
            let decode = d <= decodeReach
            if decode { wantedImages.insert(k) }
            // a page that comes within decoding reach needs a new request
            let name = "preview:\(id):\(decode)"
            if let t = windowTickets[name] {
                wantedTickets[name] = t
            } else if !decode || windowRam[k] == nil {
                let key = MediaStore.Key(.preview, id)
                wantedTickets[name] = MediaFetch.shared.ensure(key, from: url, priority: .near) { error in
                    guard error == nil, decode, let file = MediaStore.shared.file(key) else { return }
                    let op = BlockOperation {
                        let img = Self.decode(file: file, maxPixel: px, fill: false)
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                let me = MediaCache.shared
                                if let img, me.windowWanted.contains(k) { me.windowRam[k] = img }
                            }
                        }
                    }
                    op.queuePriority = .low
                    Self.decodeQueue.addOperation(op)
                }
            }
            if d <= 2, let o = client.originalURL(id) { originals.append((id, o)) }
        }
        // originals after every preview: they are big, and only matter once
        // the user stops on a photo and zooms in
        for (id, url) in originals {
            let name = "original:\(id)"
            wantedTickets[name] = windowTickets[name]
                ?? MediaFetch.shared.ensure(.init(.original, id), from: url, priority: .near)
        }
        for (name, t) in windowTickets where wantedTickets[name] == nil { t.cancel() }
        windowTickets = wantedTickets
        windowWanted = wantedImages
        windowRam = windowRam.filter { wantedImages.contains($0.key) }
    }

    /// The viewer closed: nothing more to keep ready.
    func viewerClosed() {
        for t in windowTickets.values { t.cancel() }
        windowTickets = [:]
        windowWanted = []
        windowRam = [:]
    }

    // MARK: Originals for sharing

    /// The original of `id` as a file named "<id>.<ext>" in the temporary
    /// directory (the share sheet shows the name): the cached copy when
    /// there is one, else downloaded into the cache first.
    nonisolated func shareableOriginal(_ id: String, from url: URL) async -> URL? {
        do {
            let file = try await MediaFetch.shared.file(.init(.original, id), from: url, priority: .visible)
            let ext = file.pathExtension == "bin" || file.pathExtension.isEmpty ? "jpg" : file.pathExtension
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent("\(id).\(ext)")
            try? FileManager.default.removeItem(at: dest)
            // a clone on APFS: no second copy of the bytes
            try FileManager.default.copyItem(at: file, to: dest)
            return dest
        } catch {
            if !Self.isCancellation(error) {
                Self.log.error("original \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            return nil
        }
    }

    // MARK: Decoding

    nonisolated static func onDecodeQueue(_ priority: Operation.QueuePriority = .normal,
                                          _ work: @escaping @Sendable () -> UIImage?) async -> UIImage? {
        if Task.isCancelled { return nil }
        return await withCheckedContinuation { cont in
            let op = BlockOperation { cont.resume(returning: work()) }
            op.queuePriority = priority
            decodeQueue.addOperation(op)
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
        _image = State(initialValue: url.flatMap { MediaCache.shared.cached($0, maxPixel: maxPixel) })
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
            if let c = MediaCache.shared.cached(url, maxPixel: maxPixel) {
                if image !== c { image = c }
                return
            }
            image = await MediaCache.shared.load(url, maxPixel: maxPixel)
        }
    }
}
