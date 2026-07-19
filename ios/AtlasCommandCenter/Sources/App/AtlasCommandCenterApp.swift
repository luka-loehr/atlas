import SwiftUI

@main
struct AtlasCommandCenterApp: App {
    var body: some Scene {
        WindowGroup { RootView() }
    }
}

struct RootView: View {
    @AppStorage("atlas.host") private var host = "atlas.your-tailnet.ts.net:8787"
    @AppStorage("atlas.token") private var token = ""
    @State private var showSettings = false
    @State private var tab = Int(ProcessInfo.processInfo.environment["ATLAS_TAB"] ?? "0") ?? 0

    var body: some View {
        TabView(selection: $tab) {
            Tab("Command", systemImage: "gauge.with.dots.needle.67percent", value: 0) {
                DashboardScreen(host: host, token: token, showSettings: $showSettings)
            }
            Tab("Terminal", systemImage: "apple.terminal.fill", value: 1) {
                TerminalScreen(host: host, token: token)
            }
            Tab("Docker", systemImage: "shippingbox.fill", value: 2) {
                DockerScreen(host: host, token: token)
            }
            Tab("Show", systemImage: "sparkles", value: 3) {
                ShowScreen(host: host, token: token)
            }
        }
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .sheet(isPresented: $showSettings) {
            SettingsView(host: $host, token: $token) {}
        }
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
