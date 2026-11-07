import SwiftUI
import AppKit

/// Atlas › Settings… (⌘,): panes in a toolbar, the last one reopened, every
/// change applied at once (HIG, "Settings").
struct MacSettings: View {
    @AppStorage("settings.pane") private var pane = "server"

    var body: some View {
        TabView(selection: $pane) {
            Tab("Server", systemImage: "server.rack", value: "server") { ServerPane() }
            Tab("Storage", systemImage: "internaldrive", value: "storage") { StoragePane() }
        }
        .scenePadding()
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The server this Mac talks to; disconnecting forgets it and its token.
private struct ServerPane: View {
    @Environment(Session.self) private var session
    @Environment(AppModel.self) private var model
    @State private var confirmDisconnect = false

    var body: some View {
        Form {
            if session.isConnected {
                Section {
                    LabeledContent("Server") {
                        HStack(spacing: 6) {
                            StateLabel(healthy: session.reachability != .offline && session.reachability != .unauthorized,
                                       text: statusText)
                        }
                    }
                    LabeledContent("Address", value: session.base)
                        .textSelection(.enabled)
                    if let info = session.info {
                        LabeledContent("Name", value: info.hostname)
                        LabeledContent("Version", value: info.version)
                        LabeledContent("Time Zone", value: info.timezone)
                    }
                    LabeledContent("Library") {
                        Text(model.library.assets.count == 1 ? "1 item" : "\(model.library.assets.count.formatted()) items")
                            .monospacedDigit()
                    }
                } footer: {
                    Text("The access token is kept in your keychain on this Mac.")
                        .foregroundStyle(.secondary)
                }
                Section {
                    HStack {
                        Spacer()
                        Button("Disconnect…") { confirmDisconnect = true }
                    }
                }
            } else {
                Section {
                    Text("Not connected. Connect in the main window, or open the link “atlas connect” prints.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .task(id: session.config) { await session.probe() }
        .confirmationDialog("Disconnect from \(session.info?.hostname ?? "atlas")?", isPresented: $confirmDisconnect) {
            Button("Disconnect", role: .destructive) {
                session.disconnect()
            }
        } message: {
            Text("Atlas forgets the server and its token, and removes the timeline it keeps on this Mac. Your photos stay on the server.")
        }
    }

    private var statusText: String {
        switch session.reachability {
        case .online: "Connected"
        case .offline: "Offline"
        case .unauthorized: "Token Rejected"
        case .unknown: model.library.online ? "Connected" : "Connecting…"
        }
    }
}

/// What Atlas keeps on this Mac. The cache looks after itself: there is
/// nothing to set, only to see.
private struct StoragePane: View {
    @State private var storage = StorageUse()
    @State private var measured = false

    var body: some View {
        Form {
            Section {
                StorageBar(use: storage)
                    .redacted(reason: measured ? [] : .placeholder)
            } footer: {
                Text("Every grid thumbnail of your library stays on this Mac, so it opens complete, also offline. Previews, originals and videos share \(MediaStore.budget.fileSize) and make room on their own, least used first.")
                    .foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Spacer()
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([MediaStore.shared.directory])
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task {
            storage = await StorageUse.measure()
            measured = true
        }
    }
}

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
