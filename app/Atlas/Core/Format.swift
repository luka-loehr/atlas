import Foundation

extension Int64 {
    var fileSize: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}

/// A video's length as the grid cells show it: "0:42", "12:05", "1:02:03".
/// Formatted once per length: a library has a few hundred distinct ones,
/// and cells ask for them while scrolling.
@MainActor
enum VideoLength {
    private static var texts: [Int: String] = [:]

    static func text(_ seconds: Double) -> String {
        let t = Int(seconds.rounded())
        if let text = texts[t] { return text }
        let text = t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
                             : String(format: "%d:%02d", t / 60, t % 60)
        if texts.count > 5000 { texts.removeAll() }
        texts[t] = text
        return text
    }
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
