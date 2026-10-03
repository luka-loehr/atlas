import SwiftUI

/// Settings screen: the server and its status, the backup's state, what the
/// phone keeps (thumbnails, originals), trash and about.
struct SettingsScreen: View {
    var library: Library

    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @AppStorage(OriginalCache.limitKey) private var originalsGB = OriginalCache.defaultGB

    @State private var showTerminal = false
    @State private var confirmCleanup = false
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
                }
                Section("Backup") {
                    valueRow("Backup", backup.statusText, "arrow.triangle.2.circlepath", .green)
                    Button { confirmCleanup = true } label: { row("Free Up iPhone Storage", "iphone", .blue) }
                        .disabled(backup.cleaning)
                        .confirmationDialog("Remove Backed-Up Photos from This iPhone?", isPresented: $confirmCleanup,
                                            titleVisibility: .visible) {
                            Button("Remove", role: .destructive) { backup.deleteBackedUpFromDevice() }
                        }
                }
                Section {
                    StorageBar(use: storage)
                } header: {
                    HStack {
                        Text("iPhone Storage")
                        Spacer()
                        Menu {
                            Picker("Keep Originals", selection: $originalsGB) {
                                ForEach(OriginalCache.choices, id: \.self) { gb in
                                    Text(gb == 0 ? "Off" : "\(gb) GB").tag(gb)
                                }
                            }
                        } label: {
                            HStack(spacing: 3) {
                                Text(originalsGB == 0 ? "Originals Off" : "Originals up to \(originalsGB) GB")
                                Image(systemName: "chevron.up.chevron.down").imageScale(.small)
                            }
                            .font(.footnote)
                            .textCase(nil)
                        }
                    }
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
        .task { storage = await StorageUse.measure() }
        .onChange(of: originalsGB) {
            Task {
                await Task.detached(priority: .utility) { OriginalCache.shared.trim() }.value
                storage = await StorageUse.measure()
            }
        }
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

/// What Atlas keeps on this iPhone, next to the rest of the device.
struct StorageUse {
    var originals: Int64 = 0
    var thumbnails: Int64 = 0
    var capacity: Int64 = 0
    var free: Int64 = 0

    var other: Int64 { max(capacity - free - originals - thumbnails, 0) }
    var used: Int64 { max(capacity - free, 0) }

    /// Read off the main thread: walking the caches touches the disk.
    static func measure() async -> StorageUse {
        await Task.detached(priority: .utility) {
            var u = StorageUse()
            u.originals = OriginalCache.shared.usage
            u.thumbnails = ThumbStore.shared.stats.bytes + Int64(URLCache.shared.currentDiskUsage)
            let home = URL(fileURLWithPath: NSHomeDirectory())
            if let v = try? home.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]) {
                u.capacity = Int64(v.volumeTotalCapacity ?? 0)
                u.free = v.volumeAvailableCapacityForImportantUsage ?? 0
            }
            return u
        }.value
    }
}

/// One row like Settings › General › iPhone Storage: a horizontal bar of the
/// whole device with Atlas' share coloured in, and a legend under it.
struct StorageBar: View {
    var use: StorageUse

    private func gb(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("iPhone").font(.headline)
                Spacer()
                if use.capacity > 0 {
                    Text("\(gb(use.used)) of \(gb(use.capacity)) used")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            GeometryReader { geo in
                let total = CGFloat(max(use.capacity, 1))
                let w = { (b: Int64) in max(geo.size.width * CGFloat(b) / total, b > 0 ? 3 : 0) }
                HStack(spacing: 1.5) {
                    Rectangle().fill(.teal).frame(width: w(use.originals))
                    Rectangle().fill(.indigo).frame(width: w(use.thumbnails))
                    Rectangle().fill(Color(.systemGray3)).frame(width: w(use.other))
                    Spacer(minLength: 0)
                }
                .frame(width: geo.size.width, alignment: .leading)
                .background(Color(.systemGray5))
                .clipShape(.rect(cornerRadius: 4))
            }
            .frame(height: 20)
            .accessibilityHidden(true)
            HStack(spacing: 16) {
                legend(.teal, "Originals", use.originals)
                legend(.indigo, "Thumbnails", use.thumbnails)
                legend(Color(.systemGray3), "Other", use.other)
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
