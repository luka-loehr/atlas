import Foundation
import Observation

/// The photo library: paged timeline grouped into day sections, month summary,
/// albums, stats. Loads pages as the grid scrolls near the end.
@MainActor
@Observable
final class Library {
    var host = "atlas.your-tailnet.ts.net:8788"
    var client: PhotoClient { PhotoClient(host: host) }

    var assets: [Asset] = []
    var sections: [DaySection] = []
    /// Full month distribution (all months + counts, newest first) — the stable,
    /// pagination-independent scale for the TimeScrubber. Filled once on start.
    var scale: [MonthBucket] = []
    var stats: LibraryStats?
    var online = true
    var loading = false
    private var reachedEnd = false
    private var loadingAll = false

    struct DaySection: Identifiable {
        let id: String            // "2024-07-15"
        let date: Date
        var assets: [Asset]
    }

    func start() async {
        async let s: Void = loadStats()
        await loadFirst()
        _ = await s
        // scale (for the scrubber) + full timeline in the background so the grid
        // shows instantly but the scrubber gets a stable full-range scale and
        // every jump target exists.
        Task { scale = (try? await client.summary()) ?? [] }
        Task { await loadAll() }
    }

    /// Pull every remaining asset in one bulk request so all day-sections exist
    /// (the scrubber can then jump anywhere without the range shifting).
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
        guard !loading, !reachedEnd,
              let idx = assets.firstIndex(of: asset),
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

    // MARK: Prefetch

    @ObservationIgnored private var lastPrefetchIndex = Int.min
    @ObservationIgnored private var lastPrefetchAt = Date.distantPast

    /// Warms thumbnails around `asset` in timeline order: the next 60 and the
    /// previous 12. Throttled — fires at most once per second unless the
    /// viewport jumped more than 20 items (fast scroll).
    func prefetch(around asset: Asset) {
        guard let idx = assets.firstIndex(of: asset) else { return }
        let now = Date()
        guard now.timeIntervalSince(lastPrefetchAt) >= 1
            || abs(idx - lastPrefetchIndex) > 20 else { return }
        lastPrefetchAt = now
        lastPrefetchIndex = idx

        let ahead  = ((idx + 1) ..< min(idx + 61, assets.count)).map { $0 }
        let behind = (max(idx - 12, 0) ..< idx).reversed().map { $0 }
        let urls = (ahead + behind).compactMap { client.thumbURL(assets[$0].id, 512) }
        ThumbLoader.shared.prefetch(urls)
    }

    func refresh() async {
        reachedEnd = false
        await loadStats()
        await loadFirst()
    }

    /// Insert a freshly captured asset at its timeline position immediately —
    /// the grid shows it before the server has even finished ingesting it.
    func insertLocally(_ asset: Asset) {
        guard !assets.contains(where: { $0.id == asset.id }) else { return }
        let at = asset.takenAt ?? Date()
        let idx = assets.firstIndex { ($0.takenAt ?? .distantPast) <= at } ?? assets.count
        assets.insert(asset, at: idx)
        rebuildSections()
    }

    /// Drop assets from the in-memory timeline immediately (after archive /
    /// lock / trash / delete) so the grid closes the gap without a round-trip.
    func removeLocally(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        assets.removeAll { ids.contains($0.id) }
        rebuildSections()
    }

    private func rebuildSections() {
        let cal = Calendar.current
        var out: [DaySection] = []
        var map: [String: Int] = [:]
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        for a in assets {
            let d = a.takenAt ?? Date(timeIntervalSince1970: 0)
            let key = fmt.string(from: d)
            if let i = map[key] {
                out[i].assets.append(a)
            } else {
                map[key] = out.count
                out.append(DaySection(id: key, date: cal.startOfDay(for: d), assets: [a]))
            }
        }
        sections = out
    }
}

extension Date {
    func sectionTitle() -> String {
        let cal = Calendar.current
        if cal.isDateInToday(self) { return "Heute" }
        if cal.isDateInYesterday(self) { return "Gestern" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = cal.isDate(self, equalTo: Date(), toGranularity: .year)
            ? "EEEE, d. MMMM" : "d. MMMM yyyy"
        return f.string(from: self)
    }
}
