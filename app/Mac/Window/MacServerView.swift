import SwiftUI

/// The server's live status; the terminal opens in its own window.
struct MacServerView: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationStack {
            ServerStatusScreen()
                .formStyle(.grouped)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Terminal", systemImage: "terminal") { openWindow(id: "terminal") }
                            .help("Open a shell on atlas")
                    }
                }
        }
    }
}
