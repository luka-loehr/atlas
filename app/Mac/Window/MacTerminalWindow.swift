import SwiftUI

/// A shell on atlas in its own window. Opening it takes Touch ID or the
/// Mac's password every time.
struct MacTerminalWindow: View {
    @Environment(Session.self) private var session
    @State private var unlocked = false
    @State private var failed = false

    var body: some View {
        Group {
            if unlocked, let api = session.api {
                TerminalBridge(api: api)
                    .padding(6)
                    .background(.black)
            } else {
                ContentUnavailableView {
                    Label("Terminal Locked", systemImage: "lock.shield.fill")
                } description: {
                    Text(session.isConnected ? "Opening a shell on atlas requires Touch ID or your password."
                         : "Connect to atlas first.")
                } actions: {
                    if failed, session.isConnected {
                        Button("Unlock") { Task { await unlock() } }
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
        .navigationTitle("Terminal")
        .navigationSubtitle(session.info?.hostname ?? "")
        .preferredColorScheme(.dark)
        .task(id: session.config) { await unlock() }
    }

    private func unlock() async {
        guard session.isConnected, !unlocked else { return }
        unlocked = await Biometric.authenticate(reason: "open a shell on atlas")
        failed = !unlocked
    }
}
