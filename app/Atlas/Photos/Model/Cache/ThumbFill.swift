import Foundation
import Observation
import os

/// Downloads every grid thumbnail of the library into `MediaStore`, once,
/// in the background: newest photos first, a few at a time, resuming where
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

    @ObservationIgnored private var host = ""
    @ObservationIgnored private var wanted: [String] = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let log = Logger(subsystem: "com.lukaloehr.Atlas", category: "ThumbFill")

    private static let concurrency = 6

    var running: Bool { task != nil }
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
        stored = min(MediaStore.shared.thumbStats.count, total)
    }

    private func run(ids: [String], client: PhotoClient, generation gen: Int) async {
        // 25,000 lookups: off the main thread
        let missing = await Task.detached(priority: .utility) {
            ids.filter { !MediaStore.shared.contains(.init(.thumb, $0)) }
        }.value
        refreshCounts()
        log.info("thumb fill: \(missing.count) of \(ids.count) missing")
        var next = 0
        while next < missing.count, !Task.isCancelled {
            if let reason = Self.pauseReason() {
                log.info("thumb fill paused: \(reason, privacy: .public)")
                try? await Task.sleep(for: .seconds(30))
                continue
            }
            let batch = missing[next..<min(next + Self.concurrency * 8, missing.count)]
            var networkDown: String?
            await withTaskGroup(of: (String, Error?).self) { group in
                var it = batch.makeIterator()
                func next() {
                    guard let id = it.next(), let url = client.thumbURL(id, 512) else { return }
                    group.addTask(priority: .utility) {
                        do {
                            _ = try await MediaFetch.shared.file(.init(.thumb, id), from: url, priority: .background)
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
            guard !Task.isCancelled, generation == gen else { return }
            refreshCounts()
            if let networkDown {
                log.info("thumb fill paused: \(networkDown, privacy: .public)")
                // the same batch again; what came in meanwhile is a store hit
                try? await Task.sleep(for: .seconds(60))
                continue
            }
            // what is still missing after this batch failed; it is retried on
            // the next refresh instead of hammering the server now
            next = batch.endIndex
        }
        refreshCounts()
        log.info("thumb fill finished: \(self.stored)/\(self.total), \(self.failed) failed")
    }

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
