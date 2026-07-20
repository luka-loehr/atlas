import SwiftUI
import UIKit

/// Ein Bündel geladener Original-Dateien für die Share-Präsentation via
/// `.sheet(item:)`. Erst Originale herunterladen (siehe `PhotoClient`),
/// dann `shareBundle = ShareBundle(urls:)` setzen.
struct ShareBundle: Identifiable {
    let id = UUID()
    let urls: [URL]
}

/// SwiftUI-Wrapper um `UIActivityViewController` zum Teilen lokaler Datei-URLs
/// (`file://`). Für Einzel-Fotos geht auch `ShareLink`; für den Batch-Fall
/// (mehrere Dateien, Videos) ist dieser Wrapper die robustere Wahl.
///
/// Nutzung:
/// ```
/// .sheet(item: $shareBundle) { bundle in
///     ShareSheet(items: bundle.urls)
///         .presentationDetents([.medium, .large])
/// }
/// ```
struct ShareSheet: UIViewControllerRepresentable {
    let items: [URL]
    var applicationActivities: [UIActivity]? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items,
                                 applicationActivities: applicationActivities)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
