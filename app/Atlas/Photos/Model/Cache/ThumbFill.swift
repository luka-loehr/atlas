import Foundation
import Observation
import os

/// Downloads every grid thumbnail of the library, once, in the background:
/// on the iPhone the square JPEG tiles of `GridTiles` (after which the old
/// pinned 512 WebPs are deleted), on the Mac the 512 WebPs its own tiles
/// are made from.
/// newest photos first, a few at a time, resuming where
/// it stopped after a relaunch, and topping up new photos after each
/// timeline refresh. Its downloads are `MediaFetch`'s background work: they
/// wait for an inexpensive network (no cellular, no Low Data Mode) and
/// while the user scrolls or swipes; the fill pauses in Low Power Mode. The
/// grid still loads what is on screen over any network.
@MainActor
@Observable
final class ThumbFill {
    static let shared = ThumbFill()

    /// Thumbnails on the phone, and how many the library has.
    private(set) var stored = 0
    private(set) var total = 0
    /// Thumbnails that failed in this run (they are retried on the next).
    private(set) var failed = 0
    /// Why the fill waits right now ("Waiting for Wi-Fi", "Low Power Mode",
    /// ...), nil while it runs or is done.
    private(set) var paused: String?

    @ObservationIgnored private var host = ""
    @ObservationIgnored private var wanted: [String] = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let log = Logger(subsystem: "com.lukaloehr.atlas", category: "ThumbFill")

    private static let concurrency = 6

    var running: Bool { task != nil }

    /// What the fill downloads: tiles on the phone, WebPs on the Mac.
    nonisolated private static var tiles: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }

    /// Whether `id` is on the device in the form the grid draws.
    nonisolated private static func stored(_ id: String) -> Bool {
        tiles ? GridTiles.shared.has(id) : MediaStore.shared.contains(.init(.thumb, id))
    }
    var complete: Bool { total > 0 && stored >= total }

    /// The library as it is now, oldest first (the timeline order). Starts or
    /// redirects the fill.
    func update(ids: [String], host: String) {
        self.host = host
        wanted = ids.reversed()   // newest first
        total = ids.count
        restart()
    }

    func stop() {
        task?.cancel()
        task = nil
        paused = nil
    }

    /// Carries on if it is not running and thumbnails are still missing
    /// (after a background window ended it, or a run that had failures):
    /// called on every return to the app and when the network is back.
    func resume() {
        guard task == nil, !host.isEmpty, !wanted.isEmpty, !complete else { return }
        restart()
    }

    /// Waits until the current fill has finished or was cancelled.
    func finish() async { await task?.value }

    private func restart() {
        task?.cancel()
        generation += 1
        let gen = generation
        guard !host.isEmpty, !wanted.isEmpty else { task = nil; return }
        let client = PhotoClient(host: host)
        let ids = wanted
        failed = 0
        task = Task(priority: .utility) { [weak self] in
            await MediaStore.shared.loadThumbIndex()
            await self?.run(ids: ids, client: client, generation: gen)
            if let self, self.generation == gen { self.task = nil }
        }
    }

    private func refreshCounts() {
        stored = min(Self.tiles ? GridTiles.shared.count : MediaStore.shared.thumbStats.count, total)
    }

    /// Downloads one tile and takes it in.
    nonisolated private static func fetchTile(_ id: String, from url: URL) async throws {
        try await MediaFetch.shared.run("tile/\(id)", priority: .background) { _ in
            var req = AtlasAuth.request(url, timeoutInterval: 60)
            req.cachePolicy = .reloadIgnoringLocalCacheData
            req.allowsExpensiveNetworkAccess = false
            req.allowsConstrainedNetworkAccess = false
            let (data, resp) = try await MediaFetch.shared.session.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            guard GridTiles.shared.store(id, jpeg: data) else { throw URLError(.cannotDecodeContentData) }
        }
    }

    private func run(ids: [String], client: PhotoClient, generation gen: Int, attempt: Int = 0) async {
        // 25,000 lookups: off the main thread
        let missing = await Task.detached(priority: .utility) {
            ids.filter { !ThumbFill.stored($0) }
        }.value
        refreshCounts()
        log.info("thumb fill: \(missing.count) of \(ids.count) missing")
        var next = 0
        while next < missing.count, !Task.isCancelled {
            if let reason = Self.pauseReason() {
                log.info("thumb fill paused: \(reason, privacy: .public)")
                paused = reason
                try? await Task.sleep(for: .seconds(30))
                continue
            }
            paused = nil
            let batch = missing[next..<min(next + Self.concurrency * 8, missing.count)]
            var networkDown: String?
            await withTaskGroup(of: (String, Error?).self) { group in
                var it = batch.makeIterator()
                func next() {
                    guard let id = it.next(),
                          let url = Self.tiles ? client.tileURL(id) : client.thumbURL(id, 512) else { return }
                    group.addTask(priority: .utility) {
                        do {
                            if Self.tiles {
                                try await Self.fetchTile(id, from: url)
                            } else {
                                _ = try await MediaFetch.shared.file(.init(.thumb, id), from: url, priority: .background)
                            }
                            return (id, nil)
                        } catch {
                            return (id, error)
                        }
                    }
                }
                for _ in 0..<Self.concurrency { next() }
                for await (id, error) in group {
                    if let error {
                        if let reason = Self.unavailable(error) { networkDown = reason; group.cancelAll() }
                        else if !MediaCache.isCancellation(error) {
                            failed += 1
                            log.error("thumb \(id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                        }
                    }
                    if networkDown == nil { next() }
                }
            }
            if Self.tiles { GridTiles.shared.flush() }
            guard !Task.isCancelled, generation == gen else { return }
            refreshCounts()
            if let networkDown {
                log.info("thumb fill paused: \(networkDown, privacy: .public)")
                paused = networkDown
                // the same batch again; what came in meanwhile is a store hit
                try? await Task.sleep(for: .seconds(60))
                continue
            }
            // what is still missing after this batch failed; it is retried on
            // the next refresh instead of hammering the server now
            next = batch.endIndex
        }
        refreshCounts()
        paused = nil
        log.info("thumb fill finished: \(self.stored)/\(self.total), \(self.failed) failed")
        // every tile is here: the 512 WebPs the grid used to draw go
        if Self.tiles, complete, !UserDefaults.standard.bool(forKey: Self.purgedKey) {
            await Task.detached(priority: .utility) { MediaStore.shared.removeAllThumbs() }.value
            UserDefaults.standard.set(true, forKey: Self.purgedKey)
            log.info("thumb fill: all tiles here, pinned 512 thumbnails deleted")
        }
        // what failed is tried again in a while (2, 4, ... 32 min), not only
        // at the next launch; a thumbnail atlas cannot make is not asked for
        // every two minutes forever
        if failed > 0, attempt < 5, !Task.isCancelled {
            paused = "\(failed.formatted()) failed, retrying"
            try? await Task.sleep(for: .seconds(120 << attempt))
            guard !Task.isCancelled, generation == gen else { return }
            failed = 0
            await run(ids: ids, client: client, generation: gen, attempt: attempt + 1)
        }
    }

    private static let purgedKey = "thumbs.512Removed"

    private static func pauseReason() -> String? {
        let info = ProcessInfo.processInfo
        if info.isLowPowerModeEnabled { return "Low Power Mode" }
        if info.thermalState == .serious || info.thermalState == .critical { return "iPhone Too Warm" }
        return nil
    }

    /// Network errors that mean "not now" rather than "this thumbnail is bad".
    static func unavailable(_ error: Error) -> String? {
        guard let e = error as? URLError else { return nil }
        if let reason = e.networkUnavailableReason {
            switch reason {
            case .cellular, .expensive: return "Waiting for Wi-Fi"
            case .constrained: return "Low Data Mode"
            default: return "No Network"
            }
        }
        switch e.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
             .cannotFindHost, .timedOut, .dnsLookupFailed:
            return "atlas Unreachable"
        default:
            return nil
        }
    }
}
