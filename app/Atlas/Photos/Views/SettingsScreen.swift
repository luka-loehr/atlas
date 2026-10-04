import SwiftUI

/// Settings screen: the server and its status, the backup's state, and what
/// the phone keeps (the media cache manages itself; there is nothing to set).
struct SettingsScreen: View {
    var library: Library

    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var showTerminal = false
    @State private var storage = StorageUse()

    private var backup: BackupService { .shared }

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
                    Button { showTerminal = true } label: { row("Terminal", "terminal.fill", .gray) }
                        .tint(.primary)
                }
                if library.sharing {
                    Section {
                        NavigationLink { SharedLinksScreen(library: library) } label: { row("Shared Links", "link", .blue) }
                    }
                }
                Section("Backup") {
                    valueRow("Backup", backup.statusText, "arrow.triangle.2.circlepath", .green)
                    // backed-up photos older than 30 days leave the iPhone on their own
                    valueRow("Keep Last \(BackupService.keepDays) Days", backup.cleanupText, "iphone", .blue)
                }
                Section("Dynamic Cache") {
                    StorageBar(use: storage)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", systemImage: "xmark") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task(id: session.config) { await session.probe() }
        // start the live stream now, so the server screen is filled when it opens
        .task(id: session.config) {
            guard let api = session.api else { return }
            await Machine.shared.keepLive(api)
        }
        .task { storage = await StorageUse.measure() }
        .fullScreenCover(isPresented: $showTerminal) { TerminalScreen() }
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

}

/// What Atlas keeps on this iPhone, by kind.
struct StorageUse {
    /// Every grid thumbnail of the library (kept for good).
    var thumbnails: Int64 = 0
    var previews: Int64 = 0
    var originals: Int64 = 0
    var videos: Int64 = 0
    /// Faces and file thumbnails.
    var other: Int64 = 0

    var total: Int64 { thumbnails + previews + originals + videos + other }

    /// Read off the main thread: walking the caches touches the disk.
    static func measure() async -> StorageUse {
        await Task.detached(priority: .utility) {
            var u = StorageUse()
            await MediaStore.shared.loadThumbIndex()
            u.thumbnails = MediaStore.shared.thumbStats.bytes
            let kinds = MediaStore.shared.bytesByKind
            u.previews = kinds[.preview] ?? 0
            u.originals = kinds[.original] ?? 0
            u.videos = kinds[.video] ?? 0
            u.other = (kinds[.face] ?? 0) + (kinds[.driveThumb] ?? 0)
            return u
        }.value
    }
}

/// One row like Settings › General › iPhone Storage, but only for what
/// Atlas keeps on this iPhone: a horizontal bar split by kind, and a legend.
struct StorageBar: View {
    var use: StorageUse

    private func gb(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }

    private var parts: [(String, Color, Int64)] {
        [("Thumbnails", .indigo, use.thumbnails), ("Previews", .blue, use.previews),
         ("Originals", .teal, use.originals), ("Videos", .orange, use.videos), ("Faces & Files", .pink, use.other)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Atlas").font(.headline)
                Spacer()
                Text(gb(use.total)).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
            }
            GeometryReader { geo in
                let total = CGFloat(max(use.total, 1))
                HStack(spacing: 1.5) {
                    ForEach(parts.filter { $0.2 > 0 }, id: \.0) { part in
                        Rectangle().fill(part.1)
                            .frame(width: max(geo.size.width * CGFloat(part.2) / total - 1.5, 2))
                    }
                }
                .frame(width: geo.size.width, alignment: .leading)
                .background(Color(.systemGray5))
                .clipShape(.rect(cornerRadius: 4))
            }
            .frame(height: 20)
            .accessibilityHidden(true)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), alignment: .leading)], alignment: .leading, spacing: 8) {
                ForEach(parts, id: \.0) { part in legend(part.1, part.0, part.2) }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private func legend(_ color: Color, _ title: String, _ bytes: Int64) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.caption)
                Text(gb(bytes)).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }
}
