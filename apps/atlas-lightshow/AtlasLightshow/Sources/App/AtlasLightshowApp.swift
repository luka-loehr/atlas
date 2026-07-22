import SwiftUI

@main
struct AtlasLightshowApp: App {
    var body: some Scene {
        WindowGroup { RootView() }
    }
}

struct RootView: View {
    // Agent host is user-configured (Settings sheet); empty until set on first launch.
    @AppStorage("atlas.host") private var host = ""
    @AppStorage("atlas.token") private var token = ""
    @State private var showSettings = false
    @State private var tab = Int(ProcessInfo.processInfo.environment["ATLAS_TAB"] ?? "0") ?? 0

    var body: some View {
        TabView(selection: $tab) {
            Tab("Shows", systemImage: "sparkles", value: 0) {
                ShowsScreen(host: host, token: token, showSettings: $showSettings)
            }
            Tab("Lichter", systemImage: "lightbulb.led.fill", value: 1) {
                LightsScreen(host: host, token: token)
            }
        }
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .sheet(isPresented: $showSettings) {
            SettingsView(host: $host, token: $token)
        }
        .task {
            // No host configured yet — open Settings so the app isn't a dead end.
            if host.isEmpty { showSettings = true }
        }
    }
}
