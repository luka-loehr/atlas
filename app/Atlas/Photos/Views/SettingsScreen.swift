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
                serverSection
                librarySection
                offlineCacheSection
                cacheSection
                syncSection
                trashSection
                aboutSection
            }
            .navigationTitle("Einstellungen")
        }
        .task {
            if library.stats == nil { await library.loadStats() }
        }
        .task(id: session.config) { await session.probe() }
        .onAppear {
            refreshCacheSize()
            thumbCache.refresh()
        }
        .fullScreenCover(isPresented: $showTerminal) { TerminalScreen() }
        .confirmationDialog("Verbindung zu diesem Server trennen?",
                            isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button("Trennen", role: .destructive) { session.disconnect() }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Dieses iPhone vergisst Adresse und Zugangstoken. Auf dem Server ändert sich nichts.")
        }
        .confirmationDialog("Gesicherte Fotos vom iPhone löschen?",
                            isPresented: $confirmCleanup, titleVisibility: .visible) {
            Button("Löschen", role: .destructive) { onCleanupDevice() }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Entfernt Aufnahmen vom iPhone, die bereits auf atlas gesichert sind. Die Originale bleiben auf dem Server.")
        }
        .confirmationDialog("Papierkorb leeren?",
                            isPresented: $confirmTrash, titleVisibility: .visible) {
            Button("Endgültig löschen", role: .destructive) { onEmptyTrash() }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Alle Fotos im Papierkorb werden dauerhaft von atlas entfernt.")
        }
    }

    // MARK: - Sections

    private var serverSection: some View {
        Section {
            NavigationLink { ServerStatusScreen() } label: {
                HStack {
                    icon("server.rack", .indigo)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(session.info?.hostname ?? "atlas").foregroundStyle(.primary)
                        Text(session.config?.url.host() ?? "")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    HStack(spacing: 6) {
                        Circle().fill(connected ? .green : .red).frame(width: 8, height: 8)
                        Text(statusText)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            NavigationLink { ActivityScreen() } label: {
                HStack {
                    icon("chart.bar.fill", .orange)
                    Text("Aktivität").foregroundStyle(.primary)
                }
            }
            NavigationLink { NetworkScreen() } label: {
                HStack {
                    icon("network", .blue)
                    Text("Netzwerk").foregroundStyle(.primary)
                }
            }
            Button { showTerminal = true } label: {
                HStack {
                    icon("terminal.fill", .black)
                    Text("Terminal").foregroundStyle(.primary)
                }
            }
            Button(role: .destructive) { confirmDisconnect = true } label: {
                HStack {
                    icon("rectangle.portrait.and.arrow.right", .red)
                    Text("Verbindung trennen").foregroundStyle(.red)
                }
            }
        } header: {
            Text("Server")
        } footer: {
            Text("Auslastung, Dienste, Speicher und Ein/Aus deines atlas-Servers findest du unter dem Servernamen.")
        }    }

    private var connected: Bool { session.reachability == .online || (session.reachability == .unknown && library.online) }

    private var statusText: String {
        switch session.reachability {
        case .online: "Verbunden"
        case .offline: "Offline"
        case .unauthorized: "Token abgelehnt"
        case .unknown: library.online ? "Verbunden" : "Offline"
        }
    }

    private var librarySection: some View {
        Section("Bibliothek") {
            if let s = library.stats {
                valueRow("Fotos", "\(s.total - s.videos)", "photo", .blue)
                valueRow("Videos", "\(s.videos)", "video", .pink)
                valueRow("Alben", "\(s.albums)", "rectangle.stack", .orange)
                valueRow("Größe", fmtBytes(s.bytes), "internaldrive", .teal)
                if let o = s.oldest, let n = s.newest {
                    valueRow("Zeitspanne",
                             "\(o.formatted(.dateTime.year())) – \(n.formatted(.dateTime.year()))",
                             "calendar", .purple)
                }
            } else {
                HStack {
                    icon("photo", .blue)
                    Text("Statistik wird geladen …").foregroundStyle(.secondary)
                    Spacer()
                    ProgressView()
                }
            }
        }    }

    private var offlineCacheSection: some View {
        Section {
            valueRow("Offline gespeichert",
                     "\(thumbCache.storedCount) · \(fmtBytes(thumbCache.storedBytes))",
                     "arrow.down.circle.fill", .indigo)
            if thumbCache.downloading {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: Double(thumbCache.done),
                                 total: Double(max(thumbCache.total, 1)))
                        .tint(.indigo)
                    Text("\(thumbCache.done) / \(thumbCache.total) geladen")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                .padding(.vertical, 2)
            } else {
                Button {
                    Task {
                        await library.loadAll()
                        let urls = library.assets.compactMap { library.client.thumbURL($0.id, 512) }
                        await thumbCache.downloadAll(urls: urls)
                    }
                } label: {
                    HStack {
                        icon("arrow.down.to.line", .indigo)
                        Text(thumbCache.storedCount > 0 ? "Neue Vorschaubilder nachladen"
                                                        : "Alle Vorschaubilder laden")
                            .foregroundStyle(.primary)
                    }
                }
                if thumbCache.storedCount > 0 {
                    Button(role: .destructive) {
                        thumbCache.clear()
                    } label: {
                        HStack {
                            icon("trash", .gray)
                            Text("Offline-Cache löschen").foregroundStyle(.primary)
                        }
                    }
                }
            }
        } header: {
            Text("Offline-Cache")
        } footer: {
            Text("Lädt alle Raster-Vorschaubilder (~0,7 GB) dauerhaft aufs iPhone. Die Bibliothek scrollt dann sofort und lässt sich auch durchblättern, wenn atlas aus ist. Neue Fotos werden beim Öffnen automatisch ergänzt.")
        }
    }

    private var cacheSection: some View {
        Section {
            valueRow("Zwischengespeichert", fmtBytes(cacheBytes),
                     "externaldrive.badge.icloud", .cyan)
            Button {
                URLCache.shared.removeAllCachedResponses()
                refreshCacheSize()
            } label: {
                HStack {
                    icon("trash", .gray)
                    Text("Cache leeren").foregroundStyle(.primary)
                }
            }
        } header: {
            Text("Cache")
        } footer: {
            Text("Thumbnails und Vorschauen werden bei Bedarf neu von atlas geladen.")
        }    }

    private var syncSection: some View {
        Section {
            Toggle(isOn: $autoBackup) {
                HStack {
                    icon("arrow.triangle.2.circlepath", .green)
                    Text("Auto-Backup").foregroundStyle(.primary)
                }
            }
            .tint(.green)
            Button { onSyncNow() } label: {
                HStack {
                    icon("icloud.and.arrow.up", .blue)
                    Text("Jetzt sichern").foregroundStyle(.primary)
                }
            }
            Button(role: .destructive) { confirmCleanup = true } label: {
                HStack {
                    icon("iphone.slash", .red)
                    Text("Gesicherte vom iPhone löschen").foregroundStyle(.red)
                }
            }
        } header: {
            Text("iPhone-Sync")
        } footer: {
            Text("Neue Aufnahmen automatisch auf atlas sichern.")
        }    }

    private var trashSection: some View {
        Section("Papierkorb") {
            Button(role: .destructive) { confirmTrash = true } label: {
                HStack {
                    icon("trash.slash", .red)
                    Text("Papierkorb leeren").foregroundStyle(.red)
                }
            }
        }    }

    private var aboutSection: some View {
        Section("Über") {
            valueRow("App", "Atlas", "photo.stack", .blue)
            valueRow("Version", appVersion, "info.circle", .gray)
            HStack {
                icon("externaldrive.connected.to.line.below", .indigo)
                Text("Server").foregroundStyle(.primary)
                Spacer()
                Text("läuft auf atlas").foregroundStyle(.secondary)
            }
        }    }

    // MARK: - Building blocks

    private func icon(_ system: String, _ color: Color) -> some View {
        Image(systemName: system)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(color, in: RoundedRectangle(cornerRadius: 7))
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
