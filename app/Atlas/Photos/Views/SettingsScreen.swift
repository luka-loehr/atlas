import SwiftUI

/// Settings screen: the server and its status, the backup's state, what the
/// phone keeps (thumbnails, originals), trash and about.
struct SettingsScreen: View {
    var library: Library

    @Environment(Session.self) private var session
    @AppStorage(OriginalCache.limitKey) private var originalsGB = OriginalCache.defaultGB

    @State private var showTerminal = false
    @State private var confirmDisconnect = false
    @State private var cacheBytes: Int64 = 0
    @State private var confirmCleanup = false
    @State private var confirmTrash = false

    private var backup: BackupService { .shared }
    private var thumbs: ThumbFill { .shared }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink { ServerStatusScreen() } label: {
                        HStack {
                            icon("server.rack", .indigo)
                            Text(session.info?.hostname ?? "atlas")
                            Spacer()
                            Circle().fill(connected ? .green : .red).frame(width: 8, height: 8)
                                .accessibilityHidden(true)
                            Text(statusText).foregroundStyle(.secondary)
                        }
                    }
                    NavigationLink { ActivityScreen() } label: { row("Activity", "chart.bar.fill", .orange) }
                    NavigationLink { NetworkScreen() } label: { row("Network", "network", .blue) }
                    Button { showTerminal = true } label: { row("Terminal", "terminal.fill", .gray) }
                }
                Section("Backup") {
                    valueRow("Backup", backup.statusText, "arrow.triangle.2.circlepath", .green)
                    Button { confirmCleanup = true } label: { row("Remove Backed-Up Items from iPhone", "iphone.slash", .red) }
                        .disabled(backup.cleaning)
                }
                Section("Storage") {
                    valueRow("Thumbnails", thumbText, "square.grid.3x3.fill", .indigo)
                    Picker(selection: $originalsGB) {
                        ForEach(OriginalCache.choices, id: \.self) { gb in
                            Text(gb == 0 ? "Off" : "\(gb) GB").tag(gb)
                        }
                    } label: {
                        row("Keep Originals", "photo.stack.fill", .teal)
                    }
                    Button {
                        Task {
                            await Task.detached(priority: .userInitiated) {
                                OriginalCache.shared.clear()
                                URLCache.shared.removeAllCachedResponses()
                            }.value
                            await refreshCacheSize()
                        }
                    } label: {
                        valueRow("Clear Cache", fmtBytes(cacheBytes), "trash", .gray)
                    }
                }
                Section {
                    Button { confirmTrash = true } label: { row("Empty Recently Deleted", "trash.slash", .red) }
                }
                Section {
                    LabeledContent("Version", value: appVersion)
                    Button("Disconnect", role: .destructive) { confirmDisconnect = true }
                }
            }
            .navigationTitle("Settings")
        }
        .task(id: session.config) { await session.probe() }
        // file sizes are read off the main thread, so the tab appears at once
        .task { await refreshCacheSize() }
        .onChange(of: originalsGB) {
            Task {
                await Task.detached(priority: .utility) { OriginalCache.shared.trim() }.value
                await refreshCacheSize()
            }
        }
        .fullScreenCover(isPresented: $showTerminal) { TerminalScreen() }
        .confirmationDialog("Disconnect from Server?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) { session.disconnect() }
        }
        .confirmationDialog("Remove Backed-Up Photos from This iPhone?", isPresented: $confirmCleanup, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { backup.deleteBackedUpFromDevice() }
        }
        .confirmationDialog("Empty Recently Deleted?", isPresented: $confirmTrash, titleVisibility: .visible) {
            Button("Delete Permanently", role: .destructive) {
                Task { try? await library.client.emptyTrash(); await library.loadStats() }
            }
        }
    }

    private var thumbText: String {
        guard thumbs.total > 0 else { return "…" }
        if thumbs.complete { return thumbs.total.formatted() }
        let count = "\(thumbs.stored.formatted()) / \(thumbs.total.formatted())"
        return thumbs.paused.map { "\(count) · \($0)" } ?? count
    }

    private var connected: Bool { session.reachability == .online || (session.reachability == .unknown && library.online) }

    private var statusText: String {
        switch session.reachability {
        case .online: "Connected"
        case .offline: "Offline"
        case .unauthorized: "Token Rejected"
        case .unknown: library.online ? "Connected" : "Offline"
        }
    }

    // MARK: - Building blocks

    private func icon(_ system: String, _ color: Color) -> some View {
        Image(systemName: system)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(color, in: RoundedRectangle(cornerRadius: 7))
    }

    private func row(_ title: String, _ system: String, _ color: Color) -> some View {
        HStack {
            icon(system, color)
            Text(title).foregroundStyle(.primary)
        }
    }

    private func valueRow(_ title: String, _ value: String,
                          _ system: String, _ color: Color) -> some View {
        HStack {
            icon(system, color)
            Text(title).foregroundStyle(.primary)
            Spacer()
            Text(value)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
    }

    // MARK: - Actions & helpers

    private func refreshCacheSize() async {
        cacheBytes = await Task.detached(priority: .utility) {
            OriginalCache.shared.usage + Int64(URLCache.shared.currentDiskUsage)
        }.value
    }

    private func fmtBytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = info?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }
}
