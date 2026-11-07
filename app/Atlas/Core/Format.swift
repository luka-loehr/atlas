import Foundation

extension Int64 {
    var fileSize: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
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
