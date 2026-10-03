import Foundation
import Observation
import CoreGraphics

/// The photo library: the whole timeline grouped into day sections, month
/// summary, stats.
///
/// The timeline runs OLDEST FIRST: the grid opens at its bottom end, on the
/// newest photos, and scrolling up goes back in time (like Apple Photos).
///
/// Loading is month by month. The server's index names every month with a
/// validator that changes exactly when the month's content does, and index
/// and months are kept on disk — so the app opens onto the full library at
/// once (also offline), and a refresh fetches only the months that changed.
@MainActor
@Observable
final class Library {
    /// Server base URL, e.g. "http://atlas.your-tailnet.ts.net:8787". Empty
    /// until the app is connected (see `Session`).
    var host = ""
    var client: PhotoClient { PhotoClient(host: host) }

    /// Oldest first.
    var assets: [Asset] = []
    var sections: [DaySection] = []
    /// Full month distribution (all months + counts, oldest first) — the
    /// stable scale for the TimeScrubber.
    var scale: [MonthBucket] = [] { didSet { rebuildScrubIndex() } }
    /// Precomputed scrubber lookups (id→fraction, month→section, labels) so the
    /// scroll/drag path never scans sections or touches Calendar/DateFormatter.
    var scrubIndex = ScrubIndex()
    var stats: LibraryStats?
    var online = true
    var loading = false

    /// O(1) asset-id → position, so hot per-cell callbacks never do an
    /// O(n) `firstIndex(of:)` full-struct scan during a fast fling.
    @ObservationIgnored private var indexByID: [String: Int] = [:]
    /// Set true while the user drags the scrubber — prefetch pauses so the CPU
    /// doesn't chase thumbnails for every month the finger flies past.
    @ObservationIgnored var scrubbing = false

    /// The index as last seen (newest first, as the server sends it) and the
    /// months loaded for it.
    @ObservationIgnored private var index: [PhotoClient.TimelineBucket] = []
    @ObservationIgnored private var months: [String: AssetColumns] = [:]
    @ObservationIgnored private var refreshing = false

    struct DaySection: Identifiable {
        let id: String            // "2024-07-15"
        let date: Date
        let title: String         // precomputed header text (no per-frame format)
        var assets: [Asset]
    }

    struct ScrubIndex {
        struct Entry { let month: String; let year: Int; let label: String; let start: CGFloat; let end: CGFloat }
        var entries: [Entry] = []            // top(oldest)→bottom(newest), by fraction
        var fracByID: [String: CGFloat] = [:]
        var idByMonth: [String: String] = [:]
    }

    func start() async {
        loadFromDisk()
        async let s: Void = loadStats()
        await loadFirst()
        _ = await s
    }

    /// Kept for callers that want "everything is there": the timeline is
    /// always loaded whole now.
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
            let stale = fresh.filter { known[$0.key] != $0.etag || months[$0.key] == nil }
            // newest months first: the grid opens on them
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
            let complete = fresh.filter { loaded[$0.key] != nil || (known[$0.key] == $0.etag && months[$0.key] != nil) }
            for (key, columns) in loaded { months[key] = columns }
            months = months.filter { key, _ in fresh.contains { $0.key == key } }
            index = complete.count == fresh.count ? fresh : index.filter { b in fresh.contains { $0.key == b.key } }
            if complete.count == fresh.count {
                rebuildAssets(from: fresh)
                saveToDisk(index: fresh, changed: loaded)
            }
        } catch {
            online = false
        }
    }

    func loadMoreIfNeeded(current asset: Asset) async {}

    /// The index lists months newest first, and each month its assets newest
    /// first; the timeline is the reverse of both.
    private func rebuildAssets(from index: [PhotoClient.TimelineBucket]) {
        var all: [Asset] = []
        all.reserveCapacity(index.reduce(0) { $0 + $1.count })
        for bucket in index.reversed() {
            if let columns = months[bucket.key] { all.append(contentsOf: columns.assets.reversed()) }
        }
        assets = all
        scale = index.reversed().map { MonthBucket(month: $0.key, count: $0.count) }
        rebuildSections()
    }

    // MARK: Disk cache

    @ObservationIgnored private lazy var directory: URL = {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("timeline", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private func loadFromDisk() {
        guard assets.isEmpty,
              let data = try? Data(contentsOf: directory.appendingPathComponent("index.json")),
              let cached = try? JSONDecoder().decode([PhotoClient.TimelineBucket].self, from: data) else { return }
        var loaded: [String: AssetColumns] = [:]
        for bucket in cached {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("\(bucket.key).json")),
                  let columns = try? JSONDecoder().decode(AssetColumns.self, from: data) else { return }
            loaded[bucket.key] = columns
        }
        index = cached
        months = loaded
        rebuildAssets(from: cached)
    }

    private func saveToDisk(index: [PhotoClient.TimelineBucket], changed: [String: AssetColumns]) {
        let directory = directory
        let keys = Set(index.map(\.key))
        Task.detached(priority: .utility) {
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
        sections = []
        scale = []
        stats = nil
        index = []
        months = [:]
        indexByID = [:]
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: Prefetch (viewport-tracking)

    @ObservationIgnored private var lastPrefetchIndex = Int.min
    @ObservationIgnored private var lastPrefetchAt = Date.distantPast

    /// Warms thumbnails around `asset`. Throttle FIRST (cheap exit before any
    /// index work); paused during a scrubber drag; window kept tight and the
    /// loader's queue is REPLACED (not appended) so work always tracks the finger.
    func prefetch(around asset: Asset) {
        guard !scrubbing else { return }
        let now = Date()
        guard now.timeIntervalSince(lastPrefetchAt) >= 0.25 else { return }
        guard let idx = indexByID[asset.id] else { return }
        guard idx != lastPrefetchIndex else { return }
        lastPrefetchAt = now
        lastPrefetchIndex = idx

        // the timeline is entered at its newest end and read upwards, so the
        // direction of travel is towards OLDER photos (lower indices): look
        // further that way so thumbnails are ready BEFORE they scroll in
        let older = (max(idx - 48, 0) ..< idx).reversed().map { $0 }
        let newer = ((idx + 1) ..< min(idx + 17, assets.count)).map { $0 }
        let urls = (older + newer).compactMap { client.thumbURL(assets[$0].id, 512) }
        ThumbLoader.shared.setPrefetchWindow(urls)
    }

    func refresh() async {
        await loadStats()
        await loadFirst()
    }

    func insertLocally(_ asset: Asset) {
        guard indexByID[asset.id] == nil else { return }
        let at = asset.takenAt ?? Date()
        let idx = assets.lastIndex { ($0.takenAt ?? .distantPast) <= at }.map { $0 + 1 } ?? 0
        assets.insert(asset, at: idx)
        rebuildSections()
    }

    func removeLocally(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        assets.removeAll { ids.contains($0.id) }
        rebuildSections()
    }

    // MARK: Section building

    /// Section id of assets without a capture date; they lead the timeline.
    static let undatedID = "undated"

    private func rebuildSections() {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let thisYear = cal.component(.year, from: today)
        var out: [DaySection] = []
        var dayMap: [String: Int] = [:]
        var idx: [String: Int] = [:]
        idx.reserveCapacity(assets.count)

        for (i, a) in assets.enumerated() {
            idx[a.id] = i
            let key = a.takenAt.map { Self.dayKeyFmt.string(from: $0) } ?? Self.undatedID
            if let s = dayMap[key] {
                out[s].assets.append(a)
            } else {
                dayMap[key] = out.count
                let start = cal.startOfDay(for: a.takenAt ?? Date(timeIntervalSince1970: 0))
                let title = a.takenAt == nil
                    ? "Ohne Datum"
                    : Self.title(for: start, today: today, thisYear: thisYear, cal: cal)
                out.append(DaySection(id: key, date: start, title: title, assets: [a]))
            }
        }
        indexByID = idx
        sections = out
        rebuildScrubIndex()
    }

    /// Precompute everything the scrubber reads per frame/drag: cumulative month
    /// fractions, each section's handle fraction, and month→section jump targets.
    private func rebuildScrubIndex() {
        var out = ScrubIndex()
        guard !scale.isEmpty else { scrubIndex = out; return }

        let total = max(scale.reduce(0) { $0 + $1.count }, 1)
        var acc = 0
        var startByMonth: [String: CGFloat] = [:]
        var endByMonth: [String: CGFloat] = [:]
        for b in scale {
            let start = CGFloat(acc) / CGFloat(total)
            acc += b.count
            let end = CGFloat(acc) / CGFloat(total)
            if b.month == Self.undatedID {
                out.entries.append(.init(month: b.month, year: 0, label: "Ohne Datum", start: start, end: end))
            } else {
                let (y, date) = Self.parseMonth(b.month)
                out.entries.append(.init(month: b.month, year: y,
                                         label: Self.monthLabel(date),
                                         start: start, end: end))
            }
            startByMonth[b.month] = start
            endByMonth[b.month] = end
        }

        let cal = Calendar.current
        for s in sections {
            let comps = cal.dateComponents([.year, .month, .day], from: s.date)
            let mk = s.id == Self.undatedID
                ? Self.undatedID
                : String(format: "%04d-%02d", comps.year ?? 0, comps.month ?? 0)
            if out.idByMonth[mk] == nil { out.idByMonth[mk] = s.id }
            if let st = startByMonth[mk], let en = endByMonth[mk] {
                let day = comps.day ?? 1
                let dim = cal.range(of: .day, in: .month, for: s.date)?.count ?? 30
                let dayFrac = s.id == Self.undatedID ? 0 : CGFloat(day - 1) / CGFloat(max(dim - 1, 1))
                out.fracByID[s.id] = st + dayFrac * (en - st)
            }
        }
        scrubIndex = out
    }

    // MARK: cached formatters (constructing DateFormatter is expensive)

    private static let dayKeyFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()
    private static let titleThisYear: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "de_DE"); f.dateFormat = "EEEE, d. MMMM"; return f
    }()
    private static let titleOtherYear: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "de_DE"); f.dateFormat = "d. MMMM yyyy"; return f
    }()
    private static let monthFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "de_DE"); f.dateFormat = "MMM yyyy"; return f
    }()

    private static func title(for date: Date, today: Date, thisYear: Int, cal: Calendar) -> String {
        if cal.isDate(date, inSameDayAs: today) { return "Heute" }
        if let y = cal.date(byAdding: .day, value: -1, to: today), cal.isDate(date, inSameDayAs: y) { return "Gestern" }
        return (cal.component(.year, from: date) == thisYear ? titleThisYear : titleOtherYear).string(from: date)
    }
    private static func monthLabel(_ d: Date) -> String { monthFmt.string(from: d) }
    private static func parseMonth(_ ym: String) -> (Int, Date) {
        let p = ym.split(separator: "-")
        let y = Int(p.first ?? "0") ?? 0
        let m = p.count > 1 ? (Int(p[1]) ?? 1) : 1
        let d = Calendar.current.date(from: DateComponents(year: y, month: m, day: 1)) ?? Date()
        return (y, d)
    }
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
