import SwiftUI
import LocalAuthentication

/// A shell on the server. Opening it takes Face ID every time: whoever holds
/// the unlocked phone can look at photos, but not type into the machine.
struct TerminalScreen: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var unlocked = false
    @State private var failed = false

    var body: some View {
        NavigationStack {
            Group {
                if unlocked, let api = session.api {
                    TerminalBridge(api: api).ignoresSafeArea(.container, edges: .bottom)
                } else {
                    ContentUnavailableView {
                        Label("Terminal Locked", systemImage: "lock.shield.fill")
                    } description: {
                        Text("Access to the atlas shell requires Face ID.")
                    } actions: {
                        if failed { Button("Unlock") { Task { await unlock() } } }
                    }
                }
            }
            .background(.black)
            .navigationTitle("Terminal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(role: .close) { dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
        .task { await unlock() }
    }

    private func unlock() async {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else { unlocked = true; return }
        let ok = (try? await context.evaluatePolicy(.deviceOwnerAuthentication,
                                                    localizedReason: "Open a shell on atlas")) ?? false
        unlocked = ok
        failed = !ok
    }
}
