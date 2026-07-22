import SwiftUI

@main
struct AtlasCommandCenterApp: App {
    var body: some Scene {
        WindowGroup { RootView() }
    }
}

struct RootView: View {
    // Agent host ("host:port"); empty until configured in Settings on first launch.
    @AppStorage("atlas.host") private var host = ""
    @AppStorage("atlas.token") private var token = ""
    @State private var showSettings = false
    @State private var tab = Int(ProcessInfo.processInfo.environment["ATLAS_TAB"] ?? "0") ?? 0

    var body: some View {
        TabView(selection: $tab) {
            Tab("Command", systemImage: "gauge.with.dots.needle.67percent", value: 0) {
                DashboardScreen(host: host, token: token, showSettings: $showSettings)
            }
            Tab("Exit Node", systemImage: "lock.shield.fill", value: 1) {
                VPNScreen(host: host, token: token)
            }
            Tab("Aktivität", systemImage: "square.grid.3x3.fill", value: 2) {
                ActivityScreen(host: host, token: token)
            }
        }
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .sheet(isPresented: $showSettings) {
            SettingsView(host: $host, token: $token)
        }
        .onAppear { if host.isEmpty { showSettings = true } }
    }
}

enum PowerAction: String, Identifiable {
    case shutdown, restart
    var id: String { rawValue }
    var title: String { self == .shutdown ? "atlas herunterfahren?" : "atlas neu starten?" }
    var message: String {
        "Die Aktion wird sofort auf atlas ausgeführt und benötigt einen konfigurierten Token."
    }
    var confirm: String { self == .shutdown ? "Herunterfahren" : "Neustarten" }
}
