import SwiftUI

/// Settings screen: the server and its status, the backup's state, and what
/// the phone keeps (the media cache manages itself; there is nothing to set).
struct SettingsScreen: View {
    var library: Library

    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var showTerminal = false
    /// ATLAS_SCREEN=server opens a simulator on the server screen.
    @State private var showServer = ProcessInfo.processInfo.environment["ATLAS_SCREEN"] == "server"
    @State private var storage = StorageUse()
    @State private var cacheChoice: Int64 = MediaStore.chosenBudget ?? 0
    /// Live share links, for the count on their row.
    @State private var links: Int?

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
                        NavigationLink { SharedLinksScreen(library: library) } label: {
                            valueRow("Shared Links", links.map { $0 == 0 ? "None" : "\($0)" } ?? "", "link", .blue)
                        }
                    }
                }
                Section("Backup") {
                    valueRow("Backup", backup.statusText, "arrow.triangle.2.circlepath", .green)
                    // backed-up photos older than 30 days leave the iPhone on their own
                    valueRow("Keep Last \(BackupService.keepDays) Days", backup.cleanupText, "iphone", .blue)
                    syncRow
                }
                Section {
                    StorageBar(use: storage)
                    Picker("Cache Size", selection: Binding(
                        get: { cacheChoice },
                        set: { choice in
                            cacheChoice = choice
                            MediaStore.chosenBudget = choice == 0 ? nil : choice
                            Task { storage = await StorageUse.measure() }
                        })) {
                        Text("Automatic (\(MediaStore.automaticBudget.fileSize))").tag(Int64(0))
                        ForEach(MediaStore.budgetChoices, id: \.self) { gb in
                            Text("\(gb) GB").tag(Int64(gb) << 30)
                        }
                    }
                } header: {
                    Text("Dynamic Cache")
                } footer: {
                    Text("Grid thumbnails always stay on the iPhone. Previews, originals and videos fill up to \(MediaStore.budget.fileSize) as you browse and make room on their own, least used first. Automatic is a tenth of the free space.")
                }
            }
            .navigationTitle("Settings")
            .navigationDestination(isPresented: $showServer) { ServerStatusScreen() }
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
        .task { await SyncStatus.shared.watch(library.client) }
        .task {
            guard library.sharing else { return }
            links = (try? await library.client.shares())?.count
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

    /// What is being synced right now, in a few words (on the phone and
    /// on atlas); a small spinner while anything is.
    private var syncRow: some View {
        let (text, busy) = SyncStatus.shared.line(library)
        return HStack {
            icon("arrow.trianglehead.2.clockwise", .teal)
            VStack(alignment: .leading, spacing: 2) {
                Text("Sync").foregroundStyle(.primary)
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(2)
            }
            Spacer()
            if busy {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "checkmark").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
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
