import SwiftUI

/// Settings screen: the server and its status, library stats, cache,
/// iPhone-Sync (auto-backup / manual backup / device cleanup), trash and about.
/// Reads live state from `Library`; destructive/side-effecting actions are
/// delegated to the caller via closures.
struct SettingsScreen: View {
    var library: Library
    var onSyncNow: () -> Void
    var onCleanupDevice: () -> Void
    var onEmptyTrash: () -> Void

    @Environment(Session.self) private var session
    @AppStorage("photos.autoBackup") private var autoBackup = false

    @State private var showTerminal = false
    @State private var confirmDisconnect = false
    @State private var cacheBytes: Int64 = 0
    @State private var confirmCleanup = false
    @State private var confirmTrash = false
    @State private var thumbCache = ThumbCache()

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
                            Text(statusText).foregroundStyle(.secondary)
                        }
                    }
                    NavigationLink { ActivityScreen() } label: { row("Aktivität", "chart.bar.fill", .orange) }
                    NavigationLink { NetworkScreen() } label: { row("Netzwerk", "network", .blue) }
                    Button { showTerminal = true } label: { row("Terminal", "terminal.fill", .gray) }
                }
                Section("Backup") {
                    Toggle(isOn: $autoBackup) { row("Automatisch sichern", "arrow.triangle.2.circlepath", .green) }
                    Button { onSyncNow() } label: { row("Jetzt sichern", "icloud.and.arrow.up", .blue) }
                    Button { confirmCleanup = true } label: { row("Gesicherte vom iPhone löschen", "iphone.slash", .red) }
                }
                Section("Speicher") {
                    if thumbCache.downloading {
                        ProgressView(value: Double(thumbCache.done), total: Double(max(thumbCache.total, 1))) {
                            row("Vorschaubilder laden", "arrow.down.circle.fill", .indigo)
                        } currentValueLabel: {
                            Text("\(thumbCache.done) / \(thumbCache.total)").monospacedDigit()
                        }
                    } else {
                        Button {
                            Task {
                                await library.loadAll()
                                let urls = library.assets.compactMap { library.client.thumbURL($0.id, 512) }
                                await thumbCache.downloadAll(urls: urls)
                            }
                        } label: {
                            valueRow("Offline verfügbar",
                                     thumbCache.storedCount > 0 ? fmtBytes(thumbCache.storedBytes) : "Aus",
                                     "arrow.down.circle.fill", .indigo)
                        }
                        if thumbCache.storedCount > 0 {
                            Button("Offline-Vorschaubilder entfernen", role: .destructive) { thumbCache.clear() }
                        }
                    }
                    Button {
                        URLCache.shared.removeAllCachedResponses()
                        refreshCacheSize()
                    } label: {
                        valueRow("Cache leeren", fmtBytes(cacheBytes), "trash", .gray)
                    }
                }
                Section {
                    Button { confirmTrash = true } label: { row("Papierkorb leeren", "trash.slash", .red) }
                }
                Section {
                    LabeledContent("Version", value: appVersion)
                    Button("Verbindung trennen", role: .destructive) { confirmDisconnect = true }
                }
            }
            .navigationTitle("Einstellungen")
        }
        .task(id: session.config) { await session.probe() }
        .onAppear {
            refreshCacheSize()
            thumbCache.refresh()
        }
        .fullScreenCover(isPresented: $showTerminal) { TerminalScreen() }
        .confirmationDialog("Verbindung trennen?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button("Trennen", role: .destructive) { session.disconnect() }
        }
        .confirmationDialog("Gesicherte Fotos vom iPhone löschen?", isPresented: $confirmCleanup, titleVisibility: .visible) {
            Button("Löschen", role: .destructive) { onCleanupDevice() }
        }
        .confirmationDialog("Papierkorb leeren?", isPresented: $confirmTrash, titleVisibility: .visible) {
            Button("Endgültig löschen", role: .destructive) { onEmptyTrash() }
        }
    }

    private var connected: Bool { session.reachability == .online || (session.reachability == .unknown && library.online) }

    private var statusText: String {
        switch session.reachability {
        case .online: "Verbunden"
        case .offline: "Offline"
        case .unauthorized: "Token abgelehnt"
        case .unknown: library.online ? "Verbunden" : "Offline"
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

    private func refreshCacheSize() {
        cacheBytes = Int64(URLCache.shared.currentDiskUsage + URLCache.shared.currentMemoryUsage)
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
