import Foundation
import Observation

/// Mirrors /api/activity — one entry per day, oldest first.
struct ActivityData: Codable, Sendable {
    let today: String
    let days: [Day]

    struct Day: Codable, Sendable, Identifiable {
        let d: String          // "2026-07-20"
        let min: Int           // minutes online
        let boots: Int
        let commits: Int
        var id: String { d }
    }
}

@MainActor
@Observable
final class ActivityModel {
    var data: ActivityData?
    var error: String?
    var host = ""
    var token = ""

    private var client: AtlasClient { AtlasClient(host: host, token: token.isEmpty ? nil : token) }

    func load() async {
        do {
            data = try await client.activity()
            error = nil
        } catch {
            self.error = "atlas nicht erreichbar"
        }
    }

    // MARK: derived, GitHub-profile-style numbers

    /// Days-online streak ending today (or yesterday, so an evening boot
    /// doesn't reset the count at midnight).
    var streak: Int {
        guard let days = data?.days, !days.isEmpty else { return 0 }
        var run = 0
        var idx = days.count - 1
        if days[idx].min == 0 { idx -= 1 }   // today may not have started yet
        while idx >= 0, days[idx].min > 0 {
            run += 1
            idx -= 1
        }
        return run
    }

    private func last30<T: Numeric>(_ pick: (ActivityData.Day) -> T) -> T {
        (data?.days.suffix(30) ?? []).reduce(T.zero) { $0 + pick($1) }
    }

    var hours30: Double { Double(last30 { $0.min }) / 60 }
    var boots30: Int { last30 { $0.boots } }
    var commits30: Int { last30 { $0.commits } }

    var busiestDay: ActivityData.Day? {
        data?.days.max { $0.min < $1.min }
    }
}
