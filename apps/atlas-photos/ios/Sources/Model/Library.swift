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
    var stats: LibraryStats?
    var online = true
    var loading = false
    private var reachedEnd = false

    struct DaySection: Identifiable {
        let id: String            // "2024-07-15"
        let date: Date
        var assets: [Asset]
    }

    func start() async {
        async let s: Void = loadStats()
        await loadFirst()
        _ = await s
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
