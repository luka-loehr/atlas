import SwiftUI
import Charts

/// The Einstellungen tab. The backup runs by itself (`BackupService`); the
/// screen only shows its state.
struct SettingsTab: View {
    var library: Library

    var body: some View {
        SettingsScreen(library: library)
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
    @State private var loaded = false

    var body: some View {
        Form {
            if let report {
                Section {
                    Chart(report.days) { day in
                        BarMark(x: .value("Day", day.date, unit: .day), y: .value("Hours", Double(day.min) / 60))
                            .foregroundStyle(Color.orange.gradient)
                    }
                    .chartYAxisLabel("Hours")
                    .frame(height: 200)
                    .padding(.vertical, 8)
                } header: {
                    Text("Awake Time")
                } footer: {
                    let hours = report.days.reduce(0) { $0 + $1.min } / 60
                    Text("\(hours) hours in the last \(report.days.count) days, across \(report.days.reduce(0) { $0 + $1.boots }) boots.")
                }
            }
        }
        .overlay { if report == nil { LoadingOrUnavailable(loaded: loaded) } }
        .navigationTitle("Activity")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            report = try? await session.api?.get("system/activity")
            loaded = true
        }
        .refreshable { report = try? await session.api?.get("system/activity") }
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
    @State private var loaded = false

    var body: some View {
        Form {
            if let report, report.available {
                Section("This Server") {
                    LabeledContent("Name", value: report.`self`.name ?? "")
                    LabeledContent("Tailnet", value: report.tailnet ?? "")
                    LabeledContent("Exit Node") {
                        Text(report.`self`.offers_exit_node == true ? "Offered" : "Off")
                    }
                }
                Section("Devices") {
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
            }
        }
        .overlay {
            if let report, !report.available {
                ContentUnavailableView("No Tailnet", systemImage: "network.slash",
                                       description: Text("Tailscale isn’t running on the server."))
            } else if report == nil {
                LoadingOrUnavailable(loaded: loaded)
            }
        }
        .navigationTitle("Network")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            report = try? await session.api?.get("system/network")
            loaded = true
        }
        .refreshable { report = try? await session.api?.get("system/network") }
    }
}

/// A spinner while a server screen loads; once the request has failed, the
/// same message the other server screens show.
struct LoadingOrUnavailable: View {
    let loaded: Bool
    var body: some View {
        if loaded {
            ServerUnavailableView()
        } else {
            ProgressView()
        }
    }
}

/// The server could not be reached.
struct ServerUnavailableView: View {
    var body: some View {
        ContentUnavailableView("atlas Unreachable", systemImage: "moon.zzz.fill",
                               description: Text("Check that atlas is running and this iPhone is on the tailnet."))
    }
}
