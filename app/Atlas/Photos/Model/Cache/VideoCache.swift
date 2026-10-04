import AVFoundation
import UniformTypeIdentifiers
import os

/// Videos through the media cache.
///
/// The player does not talk to the server itself: its asset has an
/// "atlas-video://video/{id}" URL, and this resource loader answers the
/// byte ranges AVFoundation asks for, from the cache where it has them and
/// with HTTP Range requests to GET /v1/assets/{id}/video where it does not.
/// Everything that comes over the network is written into one sparse file
/// per video (`MediaStore`, kind `.video`) with a list of the ranges it
/// holds, so a video's first seconds, fetched ahead (`prefetchHead`), start
/// it instantly, and a video played to the end plays again from the phone.
/// The file counts against the cache budget and is never evicted while open.
///
/// All state lives on one serial queue, which is also the resource loader's
/// and the URL session's delegate queue.
final class VideoCache: NSObject, @unchecked Sendable {
    static let shared = VideoCache()
    static let scheme = "atlas-video"

    fileprivate let queue = DispatchQueue(label: "atlas.video", qos: .userInitiated)
    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = 30
        cfg.httpMaximumConnectionsPerHost = 6
        let ops = OperationQueue()
        ops.underlyingQueue = queue
        ops.maxConcurrentOperationCount = 1
        return URLSession(configuration: cfg, delegate: self, delegateQueue: ops)
    }()

    private let remotesLock = NSLock()
    private var remotes: [String: URL] = [:]

    // on `queue`
    private var files: [String: VideoFile] = [:]
    private var loads: [AVAssetResourceLoadingRequest: Load] = [:]
    private var transfers: [Int: Transfer] = [:]

    private let log = Logger(subsystem: "com.lukaloehr.atlas", category: "VideoCache")

    // MARK: Public

    /// A player asset for the video `id`, streamed from `remote` through
    /// the cache.
    func asset(id: String, remote: URL) -> AVURLAsset {
        setRemote(id, remote)
        let asset = AVURLAsset(url: URL(string: "\(Self.scheme)://video/\(id)")!)
        asset.resourceLoader.setDelegate(self, queue: queue)
        return asset
    }

    /// Fetches the first seconds of a video (and its index, wherever in the
    /// file it is) into the cache, through the media download queue.
    /// `expensive`: cellular is fine (the viewer's neighbours), else only
    /// Wi-Fi (grid cells, the warmer).
    func prefetchHead(id: String, remote: URL, duration: Double?,
                      priority: MediaFetch.Priority, expensive: Bool) -> MediaFetch.Ticket {
        setRemote(id, remote)
        return MediaFetch.shared.enqueue("head:\(id)", priority: priority, work: { [self] p in
            try await fetchHead(id: id, duration: duration, expensive: expensive && p != .background)
        }, done: { _ in })
    }

    /// `prefetchHead` that waits until the head is in.
    func head(id: String, remote: URL, duration: Double?,
              priority: MediaFetch.Priority, expensive: Bool) async throws {
        setRemote(id, remote)
        try await MediaFetch.shared.run("head:\(id)", priority: priority) { [self] p in
            try await fetchHead(id: id, duration: duration, expensive: expensive && p != .background)
        }
    }

    private func setRemote(_ id: String, _ url: URL) {
        remotesLock.withLock { remotes[id] = url }
    }

    private func remote(_ id: String) -> URL? {
        remotesLock.withLock { remotes[id] }
    }

    // MARK: Files

    /// One video on disk: a sparse data file and the ranges it holds.
    fileprivate final class VideoFile: @unchecked Sendable {
        struct Meta: Codable {
            var length: Int64?
            var type: String?
            var ranges: [[Int64]] = []
        }

        let id: String
        let dataURL: URL
        let metaURL: URL
        var meta: Meta
        var ranges: [Range<Int64>]
        var refs = 0
        private var handle: FileHandle?
        private var dirty = false

        init(id: String, dataURL: URL, metaURL: URL) {
            self.id = id
            self.dataURL = dataURL
            self.metaURL = metaURL
            let fm = FileManager.default
            if fm.fileExists(atPath: dataURL.path), let d = try? Data(contentsOf: metaURL),
               let m = try? JSONDecoder().decode(Meta.self, from: d) {
                meta = m
                ranges = m.ranges.compactMap { $0.count == 2 && $0[0] < $0[1] ? $0[0]..<$0[1] : nil }
            } else {
                // data without its range list (or nothing): start over
                try? fm.removeItem(at: dataURL)
                meta = Meta()
                ranges = []
            }
        }

        var uti: String {
            meta.type.flatMap { UTType(mimeType: $0)?.identifier } ?? UTType.mpeg4Movie.identifier
        }

        var bytes: Int64 { ranges.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) } }

        func range(containing o: Int64) -> Range<Int64>? { ranges.first { $0.contains(o) } }

        func nextStart(after o: Int64) -> Int64? { ranges.first { $0.lowerBound > o }?.lowerBound }

        func gaps(in r: Range<Int64>) -> [Range<Int64>] {
            var out: [Range<Int64>] = []
            var pos = r.lowerBound
            for c in ranges where c.upperBound > pos && c.lowerBound < r.upperBound {
                if c.lowerBound > pos { out.append(pos..<c.lowerBound) }
                pos = max(pos, c.upperBound)
            }
            if pos < r.upperBound { out.append(pos..<r.upperBound) }
            return out
        }

        private func open() throws -> FileHandle {
            if let handle { return handle }
            if !FileManager.default.fileExists(atPath: dataURL.path) {
                FileManager.default.createFile(atPath: dataURL.path, contents: nil)
            }
            let h = try FileHandle(forUpdating: dataURL)
            handle = h
            return h
        }

        func write(_ data: Data, at offset: Int64) throws {
            guard !data.isEmpty else { return }
            let h = try open()
            try h.seek(toOffset: UInt64(offset))
            try h.write(contentsOf: data)
            add(offset..<offset + Int64(data.count))
        }

        func read(_ r: Range<Int64>) throws -> Data {
            let h = try open()
            try h.seek(toOffset: UInt64(r.lowerBound))
            return try h.read(upToCount: Int(r.upperBound - r.lowerBound)) ?? Data()
        }

        private func add(_ r: Range<Int64>) {
            var merged = r
            var out: [Range<Int64>] = []
            for c in ranges {
                if c.upperBound < merged.lowerBound || c.lowerBound > merged.upperBound {
                    out.append(c)
                } else {
                    merged = min(c.lowerBound, merged.lowerBound)..<max(c.upperBound, merged.upperBound)
                }
            }
            out.append(merged)
            ranges = out.sorted { $0.lowerBound < $1.lowerBound }
            dirty = true
        }

        func noteHeaders(length: Int64?, type: String?) {
            if meta.length == nil, let length, length > 0 { meta.length = length; dirty = true }
            if meta.type == nil, let type { meta.type = type; dirty = true }
        }

        /// The range list goes to disk after the bytes it describes.
        func flush() {
            guard dirty else { return }
            meta.ranges = ranges.map { [$0.lowerBound, $0.upperBound] }
            if let d = try? JSONEncoder().encode(meta) { try? d.write(to: metaURL, options: .atomic) }
            dirty = false
        }

        func close() {
            flush()
            try? handle?.close()
            handle = nil
        }
    }

    /// On `queue`.
    private func open(_ id: String) throws -> VideoFile {
        if let f = files[id] { f.refs += 1; return f }
        let (data, meta) = try MediaStore.shared.videoFiles(id)
        let f = VideoFile(id: id, dataURL: data, metaURL: meta)
        f.refs = 1
        files[id] = f
        MediaStore.shared.lease(.init(.video, id))
        return f
    }

    /// On `queue`.
    private func close(_ f: VideoFile) {
        f.refs -= 1
        guard f.refs <= 0 else { return }
        f.close()
        files[f.id] = nil
        let bytes = f.bytes
        if bytes > 0 {
            MediaStore.shared.noteVideo(f.id, file: f.dataURL, bytes: bytes)
        } else {
            try? FileManager.default.removeItem(at: f.dataURL)
            try? FileManager.default.removeItem(at: f.metaURL)
        }
        MediaStore.shared.release(.init(.video, f.id))
    }

    // MARK: Transfers (HTTP Range requests into a file)

    private final class Transfer {
        let file: VideoFile
        let want: Range<Int64>
        /// Where the next received byte belongs; set by the response.
        var offset: Int64 = -1
        var received: Int64 = 0
        var failure: Error?
        var onData: ((Data, Int64) -> Void)?
        let onDone: (Error?) -> Void
        var task: URLSessionDataTask?
        init(file: VideoFile, want: Range<Int64>, onData: ((Data, Int64) -> Void)?, onDone: @escaping (Error?) -> Void) {
            self.file = file; self.want = want; self.onData = onData; self.onDone = onDone
        }
    }

    /// On `queue`. `onDone` runs exactly once, on `queue`.
    @discardableResult
    private func startTransfer(_ file: VideoFile, _ want: Range<Int64>, expensive: Bool,
                               onData: ((Data, Int64) -> Void)?, onDone: @escaping (Error?) -> Void) -> Transfer {
        let t = Transfer(file: file, want: want, onData: onData, onDone: onDone)
        guard let url = remote(file.id) else {
            queue.async { onDone(URLError(.badURL)) }
            return t
        }
        var req = AtlasAuth.request(url, timeoutInterval: 30)
        req.setValue("bytes=\(want.lowerBound)-\(want.upperBound - 1)", forHTTPHeaderField: "Range")
        if !expensive {
            req.allowsExpensiveNetworkAccess = false
            req.allowsConstrainedNetworkAccess = false
        }
        let task = session.dataTask(with: req)
        t.task = task
        file.refs += 1          // the file stays open until the transfer ends
        transfers[task.taskIdentifier] = t
        task.resume()
        return t
    }

    // MARK: Head prefetch

    private func onQueue<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            queue.async { cont.resume(with: Result { try body() }) }
        }
    }

    private final class Cancel: @unchecked Sendable {
        var cancelled = false
        var transfer: Transfer?
    }

    /// Fills `r` of the file from the network, gap by gap.
    private func fill(_ file: VideoFile, _ r: Range<Int64>, expensive: Bool) async throws {
        let gaps = try await onQueue { file.gaps(in: r) }
        for gap in gaps {
            try Task.checkCancellation()
            let box = Cancel()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    queue.async { [self] in
                        guard !box.cancelled else { cont.resume(throwing: CancellationError()); return }
                        box.transfer = startTransfer(file, gap, expensive: expensive, onData: nil) { error in
                            if let error { cont.resume(throwing: error) } else { cont.resume() }
                        }
                    }
                }
            } onCancel: { [queue] in
                queue.async {
                    box.cancelled = true
                    box.transfer?.task?.cancel()
                }
            }
        }
    }

    private func fetchHead(id: String, duration: Double?, expensive: Bool) async throws {
        let file = try await onQueue { try self.open(id) }
        do {
            if try await onQueue({ file.meta.length }) == nil {
                try await fill(file, 0..<(64 << 10), expensive: expensive)
            }
            guard let length = try await onQueue({ file.meta.length }) else { throw URLError(.badServerResponse) }
            // about six seconds at the video's average bitrate
            var head: Int64 = 4 << 20
            if let duration, duration > 0 { head = Int64(Double(length) / max(duration, 1) * 6) + (256 << 10) }
            head = min(length, min(max(head, 1 << 20), 32 << 20))
            try await fill(file, 0..<head, expensive: expensive)
            try await fetchIndex(file, length: length, expensive: expensive)
        } catch {
            _ = try? await onQueue { self.close(file) }
            throw error
        }
        _ = try? await onQueue { self.close(file) }
    }

    /// A player needs the "moov" box before the first frame. A streaming
    /// rendition has it up front, inside the head; a camera file can carry
    /// it at the very end, after the media data, so the top-level boxes are
    /// walked (16 bytes each) until it is found and then fetched whole.
    private func fetchIndex(_ file: VideoFile, length: Int64, expensive: Bool) async throws {
        var offset: Int64 = 0
        for _ in 0..<16 {
            guard offset + 8 <= length else { return }
            let header = offset..<min(offset + 16, length)
            try await fill(file, header, expensive: expensive)
            let h = [UInt8](try await onQueue { try file.read(header) })
            guard h.count >= 8 else { return }
            var size = Int64(h[0..<4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            let type = String(bytes: h[4..<8], encoding: .ascii)
            if size == 1, h.count >= 16 {
                size = Int64(bitPattern: h[8..<16].reduce(UInt64(0)) { $0 << 8 | UInt64($1) })
            } else if size == 0 {
                size = length - offset
            }
            guard size >= 8 else { return }
            if type == "moov" {
                try await fill(file, offset..<min(offset + size, length), expensive: expensive)
                return
            }
            offset += size
        }
    }

    // MARK: Serving the player

    private final class Load {
        let request: AVAssetResourceLoadingRequest
        let file: VideoFile
        var transfer: Transfer?
        init(request: AVAssetResourceLoadingRequest, file: VideoFile) { self.request = request; self.file = file }
    }

    /// On `queue`: answers as much as the cache holds, then fetches the next
    /// gap and comes back here when it is in.
    private func step(_ load: Load) {
        guard loads[load.request] === load else { return }
        let file = load.file
        guard let length = file.meta.length else {
            // the length and type come with the first bytes
            load.transfer = startTransfer(file, 0..<(64 << 10), expensive: true, onData: nil) { [self] error in
                load.transfer = nil
                if let error { fail(load, error) } else if file.meta.length == nil {
                    fail(load, URLError(.badServerResponse))
                } else {
                    step(load)
                }
            }
            return
        }
        if let info = load.request.contentInformationRequest {
            info.contentType = file.uti
            info.contentLength = length
            info.isByteRangeAccessSupported = true
        }
        guard let data = load.request.dataRequest else { finish(load); return }
        let end = data.requestsAllDataToEndOfResource
            ? length : min(data.requestedOffset + Int64(data.requestedLength), length)
        var pos = data.currentOffset
        var served = 0
        while pos < end {
            if let have = file.range(containing: pos) {
                let upto = min(have.upperBound, end, pos + (1 << 20))
                do {
                    let chunk = try file.read(pos..<upto)
                    guard !chunk.isEmpty else { throw URLError(.cannotOpenFile) }
                    data.respond(with: chunk)
                    pos += Int64(chunk.count)
                    served += chunk.count
                } catch {
                    fail(load, error)
                    return
                }
                // a long answer from disk yields the queue now and then
                if served >= 8 << 20 { queue.async { [self] in step(load) }; return }
            } else {
                let gapEnd = min(file.nextStart(after: pos) ?? end, end)
                load.transfer = startTransfer(file, pos..<gapEnd, expensive: true, onData: { [weak self] chunk, at in
                    guard let self, self.loads[load.request] === load else { return }
                    let cur = data.currentOffset
                    let chunkEnd = at + Int64(chunk.count)
                    guard cur >= at, cur < chunkEnd else { return }
                    data.respond(with: Data(chunk.dropFirst(Int(cur - at))))
                }, onDone: { [self] error in
                    load.transfer = nil
                    guard loads[load.request] === load else { return }
                    if let error { fail(load, error) } else { step(load) }
                })
                return
            }
        }
        finish(load)
    }

    private func finish(_ load: Load) {
        guard loads.removeValue(forKey: load.request) != nil else { return }
        load.request.finishLoading()
        close(load.file)
    }

    private func fail(_ load: Load, _ error: Error) {
        guard loads.removeValue(forKey: load.request) != nil else { return }
        if !MediaCache.isCancellation(error) {
            log.error("video \(load.file.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        load.request.finishLoading(with: error)
        close(load.file)
    }
}

extension VideoCache: AVAssetResourceLoaderDelegate {
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        guard let url = request.request.url, url.scheme == Self.scheme else { return false }
        let id = url.lastPathComponent
        guard remote(id) != nil, let file = try? open(id) else { return false }
        let load = Load(request: request, file: file)
        loads[request] = load
        step(load)
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel request: AVAssetResourceLoadingRequest) {
        guard let load = loads.removeValue(forKey: request) else { return }
        load.transfer?.task?.cancel()
        load.transfer = nil
        close(load.file)
    }
}

extension VideoCache: URLSessionDataDelegate {
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let t = transfers[dataTask.taskIdentifier], let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        // "bytes 100-199/12345"
        let range = (http.value(forHTTPHeaderField: "Content-Range") ?? "")
            .replacingOccurrences(of: "bytes ", with: "")
        let parts = range.split(separator: "/")
        let start = parts.first?.split(separator: "-").first.flatMap { Int64($0) }
        switch http.statusCode {
        case 206 where start != nil:
            t.offset = start!
            t.file.noteHeaders(length: parts.count > 1 ? Int64(parts[1]) : nil, type: http.mimeType)
        case 200:
            // the whole file, whatever was asked for
            t.offset = 0
            t.file.noteHeaders(length: http.expectedContentLength > 0 ? http.expectedContentLength : nil, type: http.mimeType)
        default:
            t.failure = URLError(.badServerResponse)
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let t = transfers[dataTask.taskIdentifier], t.offset >= 0, t.failure == nil else { return }
        do {
            try t.file.write(data, at: t.offset)
        } catch {
            t.failure = error
            dataTask.cancel()
            return
        }
        t.onData?(data, t.offset)
        t.offset += Int64(data.count)
        t.received += Int64(data.count)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let t = transfers.removeValue(forKey: task.taskIdentifier) else { return }
        t.file.flush()
        let failure = t.failure ?? error ?? (t.received == 0 ? URLError(.zeroByteResource) : nil)
        if t.received > 0 { MediaStore.shared.noteVideo(t.file.id, file: t.file.dataURL, bytes: t.file.bytes) }
        close(t.file)
        t.onDone(failure)
    }
}
