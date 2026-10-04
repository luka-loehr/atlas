import UIKit

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

/// The screen the app shows on (what `UIScreen.main` used to answer).
@MainActor
enum ScreenSize {
    private static var screen: UIScreen? { (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen }
    static var bounds: CGRect { screen?.bounds ?? CGRect(x: 0, y: 0, width: 402, height: 874) }
    static var scale: CGFloat { screen?.scale ?? 3 }
}
