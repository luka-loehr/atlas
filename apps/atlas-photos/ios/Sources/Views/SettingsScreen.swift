import SwiftUI

/// Settings screen: server host + connection, library stats, cache,
/// iPhone-Sync (auto-backup / manual backup / device cleanup), trash and about.
/// Reads live state from `Library`; destructive/side-effecting actions are
/// delegated to the caller via closures.
struct SettingsScreen: View {
    var library: Library
    var onSyncNow: () -> Void
    var onCleanupDevice: () -> Void
    var onEmptyTrash: () -> Void

    @AppStorage("photos.host") private var host = "atlas.your-tailnet.ts.net:8788"
    @AppStorage("photos.autoBackup") private var autoBackup = false

    @State private var testing = false
    @State private var cacheBytes: Int64 = 0
    @State private var confirmCleanup = false
    @State private var confirmTrash = false

    init(library: Library,
         onSyncNow: @escaping () -> Void = {},
         onCleanupDevice: @escaping () -> Void = {},
         onEmptyTrash: @escaping () -> Void = {}) {
        self.library = library
        self.onSyncNow = onSyncNow
        self.onCleanupDevice = onCleanupDevice
        self.onEmptyTrash = onEmptyTrash
    }

    var body: some View {
        NavigationStack {
            Form {
                serverSection
                librarySection
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
        .onAppear {
            refreshCacheSize()
            library.host = host
        }
        .onChange(of: host) { _, new in library.host = new }
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
            HStack {
                icon("server.rack", .indigo)
                TextField("host:port", text: $host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(.primary)
            }
            HStack {
                icon("dot.radiowaves.left.and.right", library.online ? .green : .red)
                Text("Status").foregroundStyle(.primary)
                Spacer()
                HStack(spacing: 6) {
                    Circle().fill(library.online ? .green : .red).frame(width: 8, height: 8)
                    Text(library.online ? "Verbunden" : "Offline")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            Button { testConnection() } label: {
                HStack {
                    icon("antenna.radiowaves.left.and.right", .blue)
                    Text("Verbindung testen").foregroundStyle(.primary)
                    Spacer()
                    if testing { ProgressView() }
                }
            }
            .disabled(testing)
        } header: {
            Text("Server")
        } footer: {
            Text("atlas-Host im Tailnet. Format host:port.")
        }    }

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
            valueRow("App", "atlas Fotos", "photo.stack", .blue)
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

    private func testConnection() {
        testing = true
        Task { @MainActor in
            library.host = host
            let ok = (try? await library.client.stats()) != nil
            library.online = ok
            testing = false
        }
    }

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
