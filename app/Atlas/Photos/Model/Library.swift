import Foundation
import Observation
import CoreGraphics

/// The photo library: the whole timeline as one flat list, month summary,
/// stats.
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
    var assets: [Asset] = []
    /// Months with their place in `assets`, oldest first: the scale of the
    /// scrubber and the source of the date under the title.
    var months: [Month] = []
    var stats: LibraryStats?
    var online = true
    var loading = false

    /// O(1) asset-id → position.
    @ObservationIgnored private var indexByID: [String: Int] = [:]
    /// Set true while the user drags the scrubber — prefetch pauses so the CPU
    /// doesn't chase thumbnails for every month the finger flies past.
    @ObservationIgnored var scrubbing = false

    /// The index as last seen (newest first, as the server sends it) and the
    /// months loaded for it.
    @ObservationIgnored private var index: [PhotoClient.TimelineBucket] = []
    @ObservationIgnored private var columns: [String: AssetColumns] = [:]
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var started = false

    struct Month: Sendable {
        let key: String           // "2024-07" or "undated"
        let year: Int
        let label: String         // "Juli 2024"
        /// Position of its first asset in `assets`, and how many it has.
        let first: Int
        let count: Int
    }

    func start() async {
        if !started {
            started = true
            await loadFromDisk()
        }
        async let s: Void = loadStats()
        await loadFirst()
        _ = await s
    }

    /// Kept for callers that want "everything is there": the timeline is
    /// always loaded whole.
    func loadAll() async {
        if assets.isEmpty { await loadFirst() }
    }

    func loadStats() async {
        stats = try? await client.stats()
    }

    /// Fetch the index, then every month that is new or changed.
    func loadFirst() async {
        guard !host.isEmpty, !refreshing else { return }
        refreshing = true
        loading = true
        defer { refreshing = false; loading = false }
        let client = client
        do {
            let fresh = try await client.timelineIndex()
            online = true
            let known = Dictionary(uniqueKeysWithValues: index.map { ($0.key, $0.etag) })
            let stale = fresh.filter { known[$0.key] != $0.etag || columns[$0.key] == nil }
            // nothing changed: nothing to rebuild
            if stale.isEmpty, fresh.map(\.key) == index.map(\.key) { return }
            var loaded: [String: AssetColumns] = [:]
            await withTaskGroup(of: (String, AssetColumns?).self) { group in
                var pending = stale.makeIterator()
                for bucket in stale.prefix(6) {
                    _ = pending.next()
                    group.addTask { (bucket.key, try? await client.timelineBucket(bucket.key)) }
                }
                for await (key, columns) in group {
                    if let columns { loaded[key] = columns }
                    if let bucket = pending.next() {
                        group.addTask { (bucket.key, try? await client.timelineBucket(bucket.key)) }
                    }
                }
            }
            // a month that failed to load keeps its previous content
            let complete = fresh.allSatisfy { loaded[$0.key] != nil || (known[$0.key] == $0.etag && columns[$0.key] != nil) }
            guard complete else { return }
            for (key, value) in loaded { columns[key] = value }
            let keys = Set(fresh.map(\.key))
            columns = columns.filter { keys.contains($0.key) }
            index = fresh
            await apply(Self.build(index: fresh, columns: columns))
            saveToDisk(index: fresh, changed: loaded)
        } catch {
            online = false
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
        if key == undatedID { return (0, "Ohne Datum") }
        let p = key.split(separator: "-")
        let y = Int(p.first ?? "0") ?? 0
        let m = p.count > 1 ? (Int(p[1]) ?? 1) : 1
        let names = ["Januar", "Februar", "März", "April", "Mai", "Juni", "Juli",
                     "August", "September", "Oktober", "November", "Dezember"]
        return (y, "\(names[max(0, min(m - 1, 11))]) \(y)")
    }

    /// The month an asset position falls in (binary search).
    func month(at position: Int) -> Month? {
        guard !months.isEmpty else { return nil }
        var lo = 0, hi = months.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if months[mid].first <= position { lo = mid } else { hi = mid - 1 }
        }
        return months[lo]
    }

    // MARK: Disk cache

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
        Task.detached(priority: .utility) {
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
        assets = []
        months = []
        stats = nil
        index = []
        columns = [:]
        indexByID = [:]
        let directory = Self.directory
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: Prefetch (viewport-tracking)

    @ObservationIgnored private var lastPrefetchIndex = -1_000_000

    /// Warms thumbnails around a position in the timeline. The loader's queue
    /// is REPLACED (not appended) so work always tracks the finger.
    func prefetch(around idx: Int, span: Int) {
        guard !scrubbing, !assets.isEmpty, abs(idx - lastPrefetchIndex) >= span / 4 else { return }
        lastPrefetchIndex = idx
        // the timeline is read upwards from its newest end, so the direction
        // of travel is towards OLDER photos (lower indices): look further that
        // way so thumbnails are ready BEFORE they scroll in
        let lo = max(idx - span * 2, 0), hi = min(idx + span, assets.count)
        guard lo < hi else { return }
        let ordered = (lo..<idx).reversed().map { $0 } + (idx..<hi).map { $0 }
        let client = client
        ThumbLoader.shared.setPrefetchWindow(ordered.compactMap { client.thumbURL(assets[$0].id, 512) })
    }

    func refresh() async {
        await loadStats()
        await loadFirst()
    }

    func position(of id: String) -> Int? { indexByID[id] }

    func insertLocally(_ asset: Asset) {
        guard indexByID[asset.id] == nil else { return }
        let at = asset.takenAt ?? Date()
        let idx = assets.lastIndex { ($0.takenAt ?? .distantPast) <= at }.map { $0 + 1 } ?? 0
        assets.insert(asset, at: idx)
        reindex()
    }

    func removeLocally(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        assets.removeAll { ids.contains($0.id) }
        reindex()
    }

    /// After a local insert or removal: positions shift, month boundaries are
    /// approximate until the next refresh.
    private func reindex() {
        var idx: [String: Int] = [:]
        idx.reserveCapacity(assets.count)
        for (i, a) in assets.enumerated() { idx[a.id] = i }
        indexByID = idx
    }

    /// Key of assets without a capture date; they lead the timeline.
    nonisolated static let undatedID = "undated"
}

extension Date {
    /// Only for callers outside the hot grid path (the grid uses the precomputed
    /// DaySection.title). Uses shared cached formatters.
    func sectionTitle() -> String {
        let cal = Calendar.current
        if cal.isDateInToday(self) { return "Heute" }
        if cal.isDateInYesterday(self) { return "Gestern" }
        return (cal.isDate(self, equalTo: Date(), toGranularity: .year)
                ? Date.titleThisYearShared : Date.titleOtherYearShared).string(from: self)
    }
    fileprivate static let titleThisYearShared: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "de_DE"); f.dateFormat = "EEEE, d. MMMM"; return f
    }()
    fileprivate static let titleOtherYearShared: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "de_DE"); f.dateFormat = "d. MMMM yyyy"; return f
    }()
}
