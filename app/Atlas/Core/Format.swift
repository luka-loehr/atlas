import Foundation

extension Int64 {
    var fileSize: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}

/// Days as the Library header names them, like Photos: "28 September
/// 2026" for one day, "26–28 Sept 2026" for several.
enum DayRange {
    static func text(_ a: Date, _ b: Date) -> String {
        if Calendar.current.isDate(a, inSameDayAs: b) { return day.string(from: a) }
        return range.string(from: min(a, b), to: max(a, b))
    }

    private static let range: DateIntervalFormatter = {
        let f = DateIntervalFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateTemplate = "dMMMyyyy"
        return f
    }()
    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.setLocalizedDateFormatFromTemplate("dMMMMyyyy")
        return f
    }()
}

extension Asset {
    /// What VoiceOver says for a grid cell: kind and date, e.g.
    /// "Video, 3. Oktober 2026 um 18:04".
    var spokenDescription: String {
        let kind = isVideo ? "Video" : "Photo"
        guard let takenAt else { return kind }
        return "\(kind), \(takenAt.formatted(date: .long, time: .shortened))"
    }
}
