import SwiftUI
import Sparkle

/// Keeps the Mac app up to date from the GitHub releases, with Sparkle: it
/// checks the appcast once a day, downloads a new version in the background
/// and installs it when the app quits (or at once from Check for Updates…).
/// Every update is notarized by Apple and signed with the release key, whose
/// public half is `SUPublicEDKey` in Info.plist; see scripts/release-mac.sh.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    /// Whether a check can start now (not while one runs).
    @Published private(set) var canCheck = false
    private let controller: SPUStandardUpdaterController?

    private init() {
        #if DEBUG
        // a development build never replaces itself with a release
        controller = nil
        #else
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil,
                                                  userDriverDelegate: nil)
        controller?.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
        #endif
    }

    func check() { controller?.checkForUpdates(nil) }
}

/// Atlas › Check for Updates…
struct CheckForUpdatesButton: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        Button("Check for Updates…") { updater.check() }
            .disabled(!updater.canCheck)
    }
}
