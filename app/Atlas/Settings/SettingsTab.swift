import SwiftUI
import Charts

/// The Einstellungen tab: the settings screen, with the iPhone-sync actions
/// wired to a `DeviceSync` and its progress sheet.
struct SettingsTab: View {
    var library: Library
    @State private var sync: DeviceSync?
    @State private var showSync = false

    var body: some View {
        SettingsScreen(
            library: library,
            onSyncNow: { startSync(delete: false) },
            onCleanupDevice: { startSync(delete: true) },
            onEmptyTrash: { Task { try? await library.client.emptyTrash(); await library.loadStats() } })
        .sheet(isPresented: $showSync) { if let sync { SyncProgressScreen(sync: sync) } }
    }

    private func startSync(delete: Bool) {
        let sync = sync ?? DeviceSync(client: library.client)
        sync.client = library.client
        self.sync = sync
        showSync = true
        Task {
            guard await sync.requestAccess() else { return }
            await sync.scan()
            if delete { await sync.deleteBackedUpFromDevice() } else { await sync.backupNew() }
            await library.loadStats()
            await library.refresh()
        }
    }
}

// MARK: - Aktivität

/// Wie lange atlas an jedem Tag wach war (aus dem Boot-Journal des Servers).
struct ActivityScreen: View {
    struct Report: Decodable {
        struct Day: Decodable, Identifiable {
            var d: String
            var min: Int
            var boots: Int
            var commits: Int
            var id: String { d }
            var date: Date { (try? Date(d, strategy: .iso8601.year().month().day())) ?? .now }
        }
        var days: [Day]
    }

    @Environment(Session.self) private var session
    @State private var report: Report?

    var body: some View {
        Form {
            if let report {
                Section {
                    Chart(report.days) { day in
                        BarMark(x: .value("Tag", day.date, unit: .day), y: .value("Stunden", Double(day.min) / 60))
                            .foregroundStyle(Color.orange.gradient)
                    }
                    .chartYAxisLabel("Stunden")
                    .frame(height: 200)
                    .padding(.vertical, 8)
                } header: {
                    Text("Wachzeit")
                } footer: {
                    let hours = report.days.reduce(0) { $0 + $1.min } / 60
                    Text("\(hours) Stunden in den letzten \(report.days.count) Tagen, bei \(report.days.reduce(0) { $0 + $1.boots }) Starts.")
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Aktivität")
        .navigationBarTitleDisplayMode(.inline)
        .task { report = try? await session.api?.get("system/activity") }
    }
}

// MARK: - Netzwerk

/// Das Tailnet aus Sicht des Servers.
struct NetworkScreen: View {
    struct Report: Decodable {
        struct Node: Decodable, Identifiable {
            var name: String?
            var dns: String?
            var os: String?
            var online: Bool?
            var offers_exit_node: Bool?
            var id: String { dns ?? name ?? UUID().uuidString }
        }
        var available: Bool
        var tailnet: String?
        var `self`: Node
        var peers: [Node]
    }

    @Environment(Session.self) private var session
    @State private var report: Report?

    var body: some View {
        Form {
            if let report {
                if report.available {
                    Section("Dieser Server") {
                        LabeledContent("Name", value: report.`self`.name ?? "")
                        LabeledContent("Tailnet", value: report.tailnet ?? "")
                        LabeledContent("Exit Node") {
                            Text(report.`self`.offers_exit_node == true ? "Angeboten" : "Aus")
                        }
                    }
                    Section("Geräte") {
                        ForEach(report.peers) { peer in
                            LabeledContent {
                                StateLabel(healthy: peer.online == true, text: peer.online == true ? "Online" : "Offline")
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(peer.name ?? "")
                                    Text(peer.os ?? "").font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } else {
                    ContentUnavailableView("Kein Tailnet", systemImage: "network.slash",
                                           description: Text("Tailscale läuft auf dem Server nicht."))
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Netzwerk")
        .navigationBarTitleDisplayMode(.inline)
        .task { report = try? await session.api?.get("system/network") }
    }
}
