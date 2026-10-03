import Foundation
import Observation
import UIKit
import os

/// The persistent on-device store of every 512 grid thumbnail, keyed by asset
/// id. Thumbnails are content-addressed and immutable, so a file, once
/// written, is valid forever. The grid reads from here first; `ThumbFill`
/// makes sure every asset of the library ends up here.
///
/// Thread-safe: the id index sits behind a lock, the file system is touched
/// only from the callers' (background) threads.
final class ThumbStore: @unchecked Sendable {
    static let shared = ThumbStore()

    let directory: URL
    private let lock = NSLock()
    private var ids: Set<String> = []
    private var bytes: Int64 = 0
    private var shards: Set<String> = []
    private var indexTask: Task<Void, Never>?

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("Thumbs512", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    /// Where the thumbnail of `id` lives (whether or not it is there yet).
    /// 256 shard directories keep each directory small.
    func fileURL(_ id: String) -> URL {
        directory.appendingPathComponent(String(id.prefix(2)), isDirectory: true)
            .appendingPathComponent(id + ".webp")
    }

    func has(_ id: String) -> Bool { lock.withLock { ids.contains(id) } }

    var stats: (count: Int, bytes: Int64) { lock.withLock { (ids.count, bytes) } }

    /// Writes a downloaded thumbnail. Atomic, so a crash never leaves a
    /// truncated file that would decode as garbage.
    func put(_ id: String, _ data: Data) throws {
        let shard = String(id.prefix(2))
        if !lock.withLock({ shards.contains(shard) }) {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent(shard, isDirectory: true),
                                                    withIntermediateDirectories: true)
            lock.withLock { _ = shards.insert(shard) }
        }
        try data.write(to: fileURL(id), options: .atomic)
        lock.withLock {
            if ids.insert(id).inserted { bytes += Int64(data.count) }
        }
    }

    /// A file that failed to decode is removed so it is fetched again.
    func remove(_ id: String) {
        try? FileManager.default.removeItem(at: fileURL(id))
        lock.withLock { _ = ids.remove(id) }
    }

    /// Reads which thumbnails are on disk (once per launch, off the main
    /// thread). Also moves over the files of the old optional offline cache.
    func loadIndex() async {
        let task = lock.withLock { () -> Task<Void, Never> in
            if let indexTask { return indexTask }
            let t = Task.detached(priority: .utility) { [self] in self.scan() }
            indexTask = t
            return t
        }
        await task.value
    }

    private func scan() {
        migrateLegacyCache()
        let fm = FileManager.default
        var found: Set<String> = []
        var total: Int64 = 0
        var dirs: Set<String> = []
        let keys: [URLResourceKey] = [.fileSizeKey, .isDirectoryKey]
        if let e = fm.enumerator(at: directory, includingPropertiesForKeys: keys) {
            for case let url as URL in e {
                let v = try? url.resourceValues(forKeys: Set(keys))
                if v?.isDirectory == true { dirs.insert(url.lastPathComponent); continue }
                guard url.pathExtension == "webp" else { continue }
                found.insert(url.deletingPathExtension().lastPathComponent)
                total += Int64(v?.fileSize ?? 0)
            }
        }
        lock.withLock {
            ids.formUnion(found)
            bytes = max(bytes, total)
            shards.formUnion(dirs)
        }
    }

    /// The former "Offline-Cache" kept thumbnails under a mangled URL name in
    /// Application Support/ThumbCache. Its 512s are moved here, the rest
    /// (2048s) is dropped, and the directory goes away.
    private func migrateLegacyCache() {
        let fm = FileManager.default
        let legacy = directory.deletingLastPathComponent().appendingPathComponent("ThumbCache", isDirectory: true)
        guard let names = try? fm.contentsOfDirectory(atPath: legacy.path) else { return }
        for name in names {
            // "_v1_assets_<id>_thumb_512_.thmb"
            let parts = name.components(separatedBy: "_")
            if let i = parts.firstIndex(of: "assets"), parts.count > i + 3, parts[i + 2] == "thumb", parts[i + 3] == "512" {
                let id = parts[i + 1]
                let shard = directory.appendingPathComponent(String(id.prefix(2)), isDirectory: true)
                try? fm.createDirectory(at: shard, withIntermediateDirectories: true)
                try? fm.moveItem(at: legacy.appendingPathComponent(name), to: fileURL(id))
            }
        }
        try? fm.removeItem(at: legacy)
    }
}

/// Downloads every grid thumbnail of the library into `ThumbStore`, once,
/// in the background: newest photos first, a few at a time, resuming where
/// it stopped after a relaunch, and topping up new photos after each
/// timeline refresh. It waits for an inexpensive network (no cellular, no
/// Low Data Mode) and pauses in Low Power Mode; the grid still loads what
/// is on screen over any network.
@MainActor
@Observable
final class ThumbFill {
    static let shared = ThumbFill()

    /// Thumbnails on the phone, and how many the library has.
    private(set) var stored = 0
    private(set) var total = 0
    private(set) var storedBytes: Int64 = 0
    /// Thumbnails that failed in this run (they are retried on the next).
    private(set) var failed = 0
    private(set) var lastError: String?
    /// Why the fill is waiting, if it is.
    private(set) var paused: String?

    @ObservationIgnored private var host = ""
    @ObservationIgnored private var wanted: [String] = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let log = Logger(subsystem: "com.lukaloehr.Atlas", category: "ThumbFill")

    /// A session of its own that never touches cellular or a Low Data Mode
    /// network; requests made there fail fast instead.
    @ObservationIgnored private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.allowsExpensiveNetworkAccess = false
        cfg.allowsConstrainedNetworkAccess = false
        cfg.httpMaximumConnectionsPerHost = 6
        cfg.timeoutIntervalForRequest = 30
        return URLSession(configuration: cfg)
    }()

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
        lastError = nil
        task = Task(priority: .utility) { [weak self] in
            await ThumbStore.shared.loadIndex()
            await self?.run(ids: ids, client: client, generation: gen)
            if let self, self.generation == gen { self.task = nil }
        }
    }

    private func refreshCounts(_ ids: [String]) {
        let s = ThumbStore.shared.stats
        storedBytes = s.bytes
        stored = min(s.count, total)
    }

    private func run(ids: [String], client: PhotoClient, generation gen: Int) async {
        let store = ThumbStore.shared
        var missing = ids.filter { !store.has($0) }
        refreshCounts(ids)
        log.info("thumb fill: \(missing.count) of \(ids.count) missing")
        while !missing.isEmpty, !Task.isCancelled {
            if let reason = Self.pauseReason() {
                paused = reason
                try? await Task.sleep(for: .seconds(30))
                continue
            }
            paused = nil
            let batch = Array(missing.prefix(Self.concurrency * 8))
            let session = session
            var networkDown: String?
            await withTaskGroup(of: (String, Error?).self) { group in
                var it = batch.makeIterator()
                func next() {
                    guard let id = it.next(), let url = client.thumbURL(id, 512) else { return }
                    group.addTask(priority: .utility) {
                        do {
                            let (data, resp) = try await session.data(for: AtlasAuth.request(url, timeoutInterval: 30))
                            guard (resp as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else {
                                throw URLError(.badServerResponse)
                            }
                            try store.put(id, data)
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
                        else if !(error is CancellationError) {
                            failed += 1
                            lastError = error.localizedDescription
                            log.error("thumb \(id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                        }
                    }
                    if networkDown == nil { next() }
                }
            }
            guard !Task.isCancelled, generation == gen else { return }
            refreshCounts(ids)
            if let networkDown {
                paused = networkDown
                try? await Task.sleep(for: .seconds(60))
                missing = missing.filter { !store.has($0) }
                continue
            }
            // what is still missing after this batch failed; it is retried on
            // the next refresh instead of hammering the server now
            let done = Set(batch)
            missing.removeAll { done.contains($0) }
        }
        refreshCounts(ids)
        paused = nil
        log.info("thumb fill finished: \(self.stored)/\(self.total), \(self.failed) failed")
    }

    private static func pauseReason() -> String? {
        let info = ProcessInfo.processInfo
        if info.isLowPowerModeEnabled { return "Stromsparmodus" }
        if info.thermalState == .serious || info.thermalState == .critical { return "iPhone zu warm" }
        return nil
    }

    /// Network errors that mean "not now" rather than "this thumbnail is bad".
    private static func unavailable(_ error: Error) -> String? {
        guard let e = error as? URLError else { return nil }
        if let reason = e.networkUnavailableReason {
            switch reason {
            case .cellular, .expensive: return "Wartet auf WLAN"
            case .constrained: return "Datensparmodus"
            default: return "Kein Netz"
            }
        }
        switch e.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
             .cannotFindHost, .timedOut, .dnsLookupFailed:
            return "atlas nicht erreichbar"
        default:
            return nil
        }
    }
}
