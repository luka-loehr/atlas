import Foundation
import Network
import os

/// Fills the cache ahead of need while the app is idle:
///   • the face crops of every person (and the people list itself), so the
///     People views open complete,
///   • the 2048 previews of the last three months, newest first,
///   • the first seconds of the last month's videos.
/// It runs only in the foreground, on Wi-Fi (not cellular, not Low Data
/// Mode), not in Low Power Mode or when the phone is warm, after the grid
/// thumbnails are all in, a few seconds after the last scroll or swipe, and
/// only while the cache has room (the device not short of space, the
/// budget not mostly used). Its downloads are `MediaFetch` background work,
/// so whatever the user looks at overtakes them.
@MainActor
final class CacheWarmer {
    static let shared = CacheWarmer()

    private weak var library: Library?
    private var task: Task<Void, Never>?
    private var generation = 0
    private var wifi = false
    private let monitor = NWPathMonitor()
    private let log = Logger(subsystem: "com.lukaloehr.atlas", category: "CacheWarmer")

    private init() {
        monitor.pathUpdateHandler = { path in
            let ok = path.status == .satisfied && !path.isExpensive && !path.isConstrained
            Task { @MainActor in CacheWarmer.shared.wifi = ok }
        }
        monitor.start(queue: DispatchQueue(label: "atlas.warmer.path", qos: .utility))
    }

    func start(_ library: Library) {
        self.library = library
        guard task == nil else { return }
        generation += 1
        let gen = generation
        task = Task(priority: .utility) { [weak self] in
            await self?.run()
            // a stopped run that ends late must not clear its successor
            if let self, self.generation == gen { self.task = nil }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private var idle: Bool {
        let info = ProcessInfo.processInfo
        return wifi && !info.isLowPowerModeEnabled
            // warming is optional: it stops as soon as the phone is warm at
            // all, so it can never be the reason the grid stutters later on
            && info.thermalState == .nominal
            && MediaFetch.shared.calm > 3
            && (!ThumbFill.shared.running || ThumbFill.shared.complete)
    }

    /// Room for more: the device is not short of space and the budget is
    /// at most 80 % used.
    nonisolated private static func roomy() -> Bool {
        let store = MediaStore.shared
        let (_, roomy) = store.target()
        return roomy && store.cacheBytes < MediaStore.budget / 10 * 8
    }

    private func waitUntilIdle() async -> Bool {
        while !Task.isCancelled {
            if idle { return true }
            try? await Task.sleep(for: .seconds(5))
        }
        return false
    }

    private func run() async {
        try? await Task.sleep(for: .seconds(3))
        guard !Task.isCancelled else { return }
        await warmFaces()
        while !Task.isCancelled {
            guard await waitUntilIdle(), let library else { return }
            await warmRecent(library)
            // new photos arrive; look again later
            try? await Task.sleep(for: .seconds(15 * 60))
        }
    }

    // MARK: Faces

    private func warmFaces() async {
        guard let library, !library.host.isEmpty, let people = try? await library.client.persons() else { return }
        PeopleMemo.people = people
        let client = library.client
        let urls = people.compactMap { p in p.coverFace.flatMap { client.faceCropURL($0) } }
        await withTaskGroup(of: Void.self) { group in
            for url in urls {
                guard let key = MediaCache.key(of: url) else { continue }
                group.addTask {
                    _ = try? await MediaFetch.shared.file(key, from: url, priority: .background)
                }
            }
        }
        // the first screenful decoded, for the People row and screen
        MediaCache.shared.prefetch(Array(urls.prefix(30)))
        log.info("faces warm: \(urls.count)")
    }

    // MARK: Recent months

    private func warmRecent(_ library: Library) async {
        let client = library.client
        let now = Date()
        var photos: [Asset] = []
        var videos: [Asset] = []
        for asset in library.assets.reversed() {
            let age = now.timeIntervalSince(asset.takenAt ?? .distantPast)
            if asset.isVideo {
                if age < 31 * 86400, videos.count < 40 { videos.append(asset) }
            } else if age < 92 * 86400 || photos.count < 300 {
                photos.append(asset)
            }
            if photos.count >= 3000 || (age > 92 * 86400 && photos.count >= 300) { break }
        }
        let missing = await Task.detached(priority: .utility) {
            photos.filter { !MediaStore.shared.contains(.init(.preview, $0.id)) }
        }.value
        log.info("warming \(missing.count) previews, \(videos.count) video heads")

        var done = 0
        for batch in stride(from: 0, to: missing.count, by: 12).map({ Array(missing[$0..<min($0 + 12, missing.count)]) }) {
            guard !Task.isCancelled, await waitUntilIdle() else { return }
            guard await Task.detached(priority: .utility, operation: { Self.roomy() }).value else {
                log.info("warming stopped: cache full enough")
                return
            }
            await withTaskGroup(of: Void.self) { group in
                for asset in batch {
                    guard let url = client.thumbURL(asset.id, 2048) else { continue }
                    group.addTask {
                        _ = try? await MediaFetch.shared.file(.init(.preview, asset.id), from: url, priority: .background)
                    }
                }
            }
            done += batch.count
        }
        for asset in videos {
            guard !Task.isCancelled, await waitUntilIdle(), let url = client.streamURL(asset.id) else { return }
            try? await VideoCache.shared.head(id: asset.id, remote: url, duration: asset.durationS,
                                              priority: .background, expensive: false)
        }
        log.info("warming done: \(done) previews")
    }
}
