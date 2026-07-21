import Foundation

/// GET /api/power/daily — accumulated energy per day plus the lifetime total.
/// Cost is computed app-side so the €/kWh tariff stays user-configurable.
struct PowerHistory: Codable, Sendable {
    let days: [PowerDay]
    let totalWh: Double

    enum CodingKeys: String, CodingKey {
        case days
        case totalWh = "total_wh"
    }
}

struct PowerDay: Codable, Sendable, Identifiable {
    let day: String   // "yyyy-MM-dd"
    let wh: Double
    var id: String { day }

    var date: Date? { PowerDay.parser.date(from: day) }
    var kwh: Double { wh / 1000 }

    static let parser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()
}
