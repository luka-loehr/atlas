import Foundation
import Observation
import CoreGraphics

/// The photo library: paged timeline grouped into day sections, month summary,
/// albums, stats. Loads pages as the grid scrolls near the end.
@MainActor
@Observable
final class Library {
    /// Server host:port, e.g. "atlas.your-tailnet.ts.net:8788". Empty until the
    /// user configures it (Einstellungen / Account sheet, key "photos.host").
    var host = ""
    var client: PhotoClient { PhotoClient(host: host) }

    var assets: [Asset] = []
    var sections: [DaySection] = []
    /// Full month distribution (all months + counts, newest first) — the stable,
    /// pagination-independent scale for the TimeScrubber. Filled once on start.
    var scale: [MonthBucket] = [] { didSet { rebuildScrubIndex() } }
    /// Precomputed scrubber lookups (id→fraction, month→section, labels) so the
    /// scroll/drag path never scans sections or touches Calendar/DateFormatter.
    var scrubIndex = ScrubIndex()
    var stats: LibraryStats?
    var online = true
    var loading = false
    private var reachedEnd = false
    private var loadingAll = false

    /// O(1) asset-id → position, so hot per-cell callbacks never do an
    /// O(n) `firstIndex(of:)` full-struct scan during a fast fling.
    @ObservationIgnored private var indexByID: [String: Int] = [:]
    /// Set true while the user drags the scrubber — prefetch pauses so the CPU
    /// doesn't chase thumbnails for every month the finger flies past.
    @ObservationIgnored var scrubbing = false

    struct DaySection: Identifiable {
        let id: String            // "2024-07-15"
        let date: Date
        let title: String         // precomputed header text (no per-frame format)
        var assets: [Asset]
    }

    struct ScrubIndex {
        struct Entry { let month: String; let year: Int; let label: String; let start: CGFloat; let end: CGFloat }
        var entries: [Entry] = []            // top(newest)→bottom(oldest), by fraction
        var fracByID: [String: CGFloat] = [:]
        var idByMonth: [String: String] = [:]
    }

    func start() async {
        async let s: Void = loadStats()
        await loadFirst()
        _ = await s
        Task { scale = (try? await client.summary()) ?? [] }
        Task { await loadAll() }
    }

    func loadAll() async {
        guard !loadingAll, !reachedEnd else { return }
        loadingAll = true
        defer { loadingAll = false }
        guard let last = assets.last?.takenAt else { reachedEnd = true; return }
        if let rest = try? await client.timeline(before: last, limit: 100_000), !rest.isEmpty {
            let known = Set(assets.map(\.id))
            assets.append(contentsOf: rest.filter { !known.contains($0.id) })
            rebuildSections()
        }
        reachedEnd = true
        if ThumbLoader.shared.persistentEnabled {
            let urls = assets.compactMap { client.thumbURL($0.id, 512) }
            Task.detached(priority: .background) {
                for u in urls { _ = await ThumbLoader.shared.ensurePersistent(u) }
            }
        }
    }

    func loadStats() async {
        stats = try? await client.stats()
    }

    func loadFirst() async {
        loading = true
        do {
            let page = try await client.timeline(before: nil)
            assets = page
            reachedEnd = page.isEmpty
            rebuildSections()
            online = true
        } catch {
            online = false
        }
        loading = false
    }

    func loadMoreIfNeeded(current asset: Asset) async {
        // once the bulk load runs/finished, scroll pagination is redundant
        guard !loading, !loadingAll, !reachedEnd,
              let idx = indexByID[asset.id],
              idx > assets.count - 40 else { return }
        guard let last = assets.last?.takenAt else { return }
        loading = true
        do {
            let page = try await client.timeline(before: last)
            if page.isEmpty { reachedEnd = true }
            else {
                assets.append(contentsOf: page)
                rebuildSections()
            }
        } catch {}
        loading = false
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

        // look further ahead so thumbnails are ready BEFORE they scroll in — safe
        // now that decodes are bounded/cancellable and the window is pruned, not
        // appended (so this never becomes a runaway flood)
        let ahead  = ((idx + 1) ..< min(idx + 49, assets.count)).map { $0 }
        let behind = (max(idx - 16, 0) ..< idx).reversed().map { $0 }
        let urls = (ahead + behind).compactMap { client.thumbURL(assets[$0].id, 512) }
        ThumbLoader.shared.setPrefetchWindow(urls)
    }

    func refresh() async {
        reachedEnd = false
        await loadStats()
        await loadFirst()
    }

    func insertLocally(_ asset: Asset) {
        guard indexByID[asset.id] == nil else { return }
        let at = asset.takenAt ?? Date()
        let idx = assets.firstIndex { ($0.takenAt ?? .distantPast) <= at } ?? assets.count
        assets.insert(asset, at: idx)
        rebuildSections()
    }

    func removeLocally(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        assets.removeAll { ids.contains($0.id) }
        rebuildSections()
    }

    // MARK: Section building

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
            let d = a.takenAt ?? Date(timeIntervalSince1970: 0)
            let key = Self.dayKeyFmt.string(from: d)
            if let s = dayMap[key] {
                out[s].assets.append(a)
            } else {
                dayMap[key] = out.count
                let start = cal.startOfDay(for: d)
                out.append(DaySection(id: key, date: start,
                                      title: Self.title(for: start, today: today,
                                                        thisYear: thisYear, cal: cal),
                                      assets: [a]))
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
            let (y, date) = Self.parseMonth(b.month)
            out.entries.append(.init(month: b.month, year: y,
                                     label: Self.monthLabel(date),
                                     start: start, end: end))
            startByMonth[b.month] = start
            endByMonth[b.month] = end
        }

        let cal = Calendar.current
        for s in sections {
            let comps = cal.dateComponents([.year, .month, .day], from: s.date)
            let mk = String(format: "%04d-%02d", comps.year ?? 0, comps.month ?? 0)
            if out.idByMonth[mk] == nil { out.idByMonth[mk] = s.id }
            if let st = startByMonth[mk], let en = endByMonth[mk] {
                let day = comps.day ?? 1
                let dim = cal.range(of: .day, in: .month, for: s.date)?.count ?? 30
                let dayFrac = CGFloat(day - 1) / CGFloat(max(dim - 1, 1))
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
