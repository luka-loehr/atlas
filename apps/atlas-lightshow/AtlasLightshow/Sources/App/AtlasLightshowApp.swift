import SwiftUI

@main
struct AtlasLightshowApp: App {
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
    }
}
