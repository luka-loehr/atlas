import Foundation
import Observation
import CoreGraphics

/// The photo library: the whole timeline as one flat list and its months.
///
/// The timeline runs OLDEST FIRST: the grid opens at its bottom end, on the
/// newest photos, and scrolling up goes back in time (like Apple Photos).
///
/// Loading is month by month. The server's index names every month with a
/// validator that changes exactly when the month's content does, and index
/// and months are kept on disk — so the app opens onto the full library at
/// once (also offline), and a refresh fetches only the months that changed.
/// Decoding and building the list happen off the main thread; the main
/// thread only swaps in the finished result.
@MainActor
@Observable
final class Library {
    /// Server base URL, e.g. "http://atlas.your-tailnet.ts.net:8787". Empty
    /// until the app is connected (see `Session`).
    var host = ""
    var client: PhotoClient { PhotoClient(host: host) }

    /// Oldest first.
    var assets: [Asset] = [] { didSet { revision &+= 1 } }
    /// Changes with every change of `assets`: the grid compares this instead
    /// of 25,000 elements.
    private(set) var revision = 0
    /// Months with their place in `assets`, oldest first: the scale of the
    /// scrubber and the source of the date under the title.
    var months: [Month] = []
    var online = true
    /// The server's timeline has been seen at least once (an empty library
    /// is then really empty, not still loading).
    private(set) var loaded = false

    /// O(1) asset-id → position.
    @ObservationIgnored private var indexByID: [String: Int] = [:]

    /// The index as last seen (newest first, as the server sends it) and the
    /// months loaded for it.
    @ObservationIgnored private var index: [PhotoClient.TimelineBucket] = []
    @ObservationIgnored private var columns: [String: AssetColumns] = [:]
    @ObservationIgnored private var refreshing = false
    /// Reading the timeline from disk; whoever refreshes waits for it, so
    /// the refresh compares against what is on disk and fetches only the
    /// months that changed (not all of them, as against an empty index).
    @ObservationIgnored private var diskLoad: Task<Void, Never>?

    struct Month: Sendable {
        let key: String           // "2024-07" or "undated"
        let year: Int
        let label: String         // "Juli 2024"
        /// Position of its first asset in `assets`, and how many it has.
        let first: Int
        let count: Int
    }

    func start() async {
        if diskLoad == nil { diskLoad = Task { await loadFromDisk() } }
        await loadFirst()
    }

    /// Fetch the index, then every month that is new or changed.
    func loadFirst() async {
        await diskLoad?.value
        guard !host.isEmpty, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let client = client
        do {
            let fresh = try await client.timelineIndex()
            if !online { online = true }
            let known = Dictionary(uniqueKeysWithValues: index.map { ($0.key, $0.etag) })
            let stale = fresh.filter { known[$0.key] != $0.etag || columns[$0.key] == nil }
            // nothing changed: nothing to rebuild
            if stale.isEmpty, fresh.map(\.key) == index.map(\.key) { if !loaded { loaded = true }; return }
            var fetched: [String: AssetColumns] = [:]
            await withTaskGroup(of: (String, AssetColumns?).self) { group in
                var pending = stale.makeIterator()
                for bucket in stale.prefix(6) {
                    _ = pending.next()
                    group.addTask { (bucket.key, try? await client.timelineBucket(bucket.key)) }
                }
                for await (key, columns) in group {
                    if let columns { fetched[key] = columns }
                    if let bucket = pending.next() {
                        group.addTask { (bucket.key, try? await client.timelineBucket(bucket.key)) }
                    }
                }
            }
            // a month that failed to load keeps its previous content
            let complete = fresh.allSatisfy { fetched[$0.key] != nil || (known[$0.key] == $0.etag && columns[$0.key] != nil) }
            guard complete else { return }
            for (key, value) in fetched { columns[key] = value }
            let keys = Set(fresh.map(\.key))
            columns = columns.filter { keys.contains($0.key) }
            index = fresh
            await apply(Self.build(index: fresh, columns: columns))
            if !loaded { loaded = true }
            saveToDisk(index: fresh, changed: fetched)
        } catch {
            if online { online = false }
        }
    }

    /// The finished timeline, built off the main thread.
    struct Snapshot: Sendable {
        var assets: [Asset] = []
        var months: [Month] = []
        var indexByID: [String: Int] = [:]
    }

    private func apply(_ snapshot: Snapshot) async {
        assets = snapshot.assets
        months = snapshot.months
        indexByID = snapshot.indexByID
        // every grid thumbnail of the library onto the phone, in the background
        ThumbFill.shared.update(ids: snapshot.assets.map(\.id), host: host)
        // the last two months' previews, originals and videos are evicted last
        let since = Date().addingTimeInterval(-61 * 86400)
        MediaStore.shared.setRecent(Set(snapshot.assets.reversed().prefix { ($0.takenAt ?? .distantPast) > since }.map(\.id)))
    }

    /// The index lists months newest first, and each month its assets newest
    /// first; the timeline is the reverse of both.
    nonisolated private static func build(index: [PhotoClient.TimelineBucket],
                                          columns: [String: AssetColumns]) async -> Snapshot {
        await Task.detached(priority: .userInitiated) {
            var out = Snapshot()
            out.assets.reserveCapacity(index.reduce(0) { $0 + $1.count })
            for bucket in index.reversed() {
                guard let month = columns[bucket.key] else { continue }
                let assets = month.assets.reversed()
                let (year, label) = monthLabel(bucket.key)
                out.months.append(Month(key: bucket.key, year: year, label: label,
                                        first: out.assets.count, count: assets.count))
                out.assets.append(contentsOf: assets)
            }
            out.indexByID.reserveCapacity(out.assets.count)
            for (i, a) in out.assets.enumerated() { out.indexByID[a.id] = i }
            return out
        }.value
    }

    nonisolated private static func monthLabel(_ key: String) -> (Int, String) {
        if key == undatedID { return (0, "No Date") }
        let p = key.split(separator: "-")
        let y = Int(p.first ?? "0") ?? 0
        let m = p.count > 1 ? (Int(p[1]) ?? 1) : 1
        let names = ["January", "February", "March", "April", "May", "June", "July",
                     "August", "September", "October", "November", "December"]
        return (y, "\(names[max(0, min(m - 1, 11))]) \(y)")
    }

    /// The month an asset position falls in (binary search).
    func month(at position: Int) -> Month? {
        months.isEmpty ? nil : months[month(index: position)]
    }

    /// Index in `months` of the month a position falls in; `months` is not empty.
    private func month(index position: Int) -> Int {
        var lo = 0, hi = months.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if months[mid].first <= position { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    // MARK: Disk cache

    /// Saves and the reset run one after another, so an older save can never
    /// land after a newer one (or after the reset).
    nonisolated private static let diskQueue = DispatchQueue(label: "atlas.timeline.disk", qos: .utility)

    nonisolated private static var directory: URL {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("timeline", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func loadFromDisk() async {
        guard assets.isEmpty else { return }
        let cached: ([PhotoClient.TimelineBucket], [String: AssetColumns])? = await Task.detached(priority: .userInitiated) {
            let dir = Self.directory
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("index.json")),
                  let index = try? JSONDecoder().decode([PhotoClient.TimelineBucket].self, from: data) else { return nil }
            var loaded: [String: AssetColumns] = [:]
            for bucket in index {
                guard let data = try? Data(contentsOf: dir.appendingPathComponent("\(bucket.key).json")),
                      let columns = try? JSONDecoder().decode(AssetColumns.self, from: data) else { return nil }
                loaded[bucket.key] = columns
            }
            return (index, loaded)
        }.value
        guard let (cachedIndex, loaded) = cached, assets.isEmpty else { return }
        index = cachedIndex
        columns = loaded
        await apply(Self.build(index: cachedIndex, columns: loaded))
    }

    private func saveToDisk(index: [PhotoClient.TimelineBucket], changed: [String: AssetColumns]) {
        let keys = Set(index.map(\.key))
        Self.diskQueue.async {
            let directory = Self.directory
            for (key, columns) in changed {
                if let data = try? JSONEncoder().encode(columns) {
                    try? data.write(to: directory.appendingPathComponent("\(key).json"), options: .atomic)
                }
            }
            if let data = try? JSONEncoder().encode(index) {
                try? data.write(to: directory.appendingPathComponent("index.json"), options: .atomic)
            }
            // months that no longer exist
            for file in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] {
                let key = (file as NSString).deletingPathExtension
                if file != "index.json", !keys.contains(key) {
                    try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
                }
            }
        }
    }

    /// Forget everything (the app was disconnected from its server).
    func reset() {
        ThumbFill.shared.stop()
        assets = []
        months = []
        index = []
        columns = [:]
        indexByID = [:]
        loaded = false
        diskLoad = nil
        Self.diskQueue.async {
            let directory = Self.directory
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    /// The same as `start`: whichever comes first reads the disk.
    func refresh() async {
        await start()
    }

    func position(of id: String) -> Int? { indexByID[id] }

    func insertLocally(_ asset: Asset) {
        guard indexByID[asset.id] == nil else { return }
        let at = asset.takenAt ?? Date()
        let idx = assets.lastIndex { ($0.takenAt ?? .distantPast) <= at }.map { $0 + 1 } ?? 0
        assets.insert(asset, at: idx)
        // it joins the month of the photo before it (a new month appears
        // with the next refresh); the months after it move up by one
        if !months.isEmpty {
            let owner = month(index: max(idx - 1, 0))
            months = months.enumerated().map { i, m in
                i == owner ? Month(key: m.key, year: m.year, label: m.label, first: m.first, count: m.count + 1)
                    : i > owner ? Month(key: m.key, year: m.year, label: m.label, first: m.first + 1, count: m.count) : m
            }
        }
        reindex()
    }

    func removeLocally(_ ids: Set<String>) {
        let gone = ids.compactMap { indexByID[$0] }.sorted()
        guard !gone.isEmpty else { return }
        assets.removeAll { ids.contains($0.id) }
        // the months keep matching the positions: each loses what was taken
        // from it and moves up by what was taken before it
        var removed = 0, g = 0
        months = months.compactMap { m in
            let before = removed
            while g < gone.count, gone[g] < m.first + m.count { g += 1; removed += 1 }
            let count = m.count - (removed - before)
            return count > 0 ? Month(key: m.key, year: m.year, label: m.label, first: m.first - before, count: count) : nil
        }
        reindex()
    }

    /// Marks assets as favorites (or not) in place, after the server agreed.
    func setFavorite(_ ids: Set<String>, _ value: Bool) {
        var next = assets
        var changed = false
        for id in ids {
            guard let i = indexByID[id], next[i].isFavorite != value else { continue }
            next[i].favorite = value
            changed = true
        }
        if changed { assets = next }
    }

    /// After a local insert or removal: positions shift.
    private func reindex() {
        var idx: [String: Int] = [:]
        idx.reserveCapacity(assets.count)
        for (i, a) in assets.enumerated() { idx[a.id] = i }
        indexByID = idx
    }

    /// Key of assets without a capture date; they lead the timeline.
    nonisolated static let undatedID = "undated"
}
