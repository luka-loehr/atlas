import SwiftUI

@main
struct AtlasCommandCenterApp: App {
    var body: some Scene {
        WindowGroup { RootView() }
    }
}

struct RootView: View {
    @State private var model = DashboardModel()
    @AppStorage("atlas.host") private var host = "atlas.your-tailnet.ts.net:8787"
    @AppStorage("atlas.token") private var token = ""
    @State private var showSettings = false
    @State private var powerAction: PowerAction?

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background
                DashboardView(model: model)
            }
            .navigationTitle("Command Center")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { showSettings = true } label: {
                            Label("Einstellungen", systemImage: "gearshape")
                        }
                        Section("Strom") {
                            Button { powerAction = .restart } label: {
                                Label("Neustart", systemImage: "arrow.clockwise")
                            }
                            Button(role: .destructive) { powerAction = .shutdown } label: {
                                Label("Herunterfahren", systemImage: "power")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .sheet(isPresented: $showSettings) {
            SettingsView(host: $host, token: $token) {
                model.host = host
                model.token = token
                Task { await model.refresh() }
            }
        }
        .alert(
            powerAction?.title ?? "",
            isPresented: Binding(
                get: { powerAction != nil },
                set: { if !$0 { powerAction = nil } }
            ),
            presenting: powerAction
        ) { action in
            Button(action.confirm, role: .destructive) {
                Task { await model.sendPower(action.rawValue) }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: { action in
            Text(action.message)
        }
        .task {
            model.host = host
            model.token = token
            model.start()
        }
    }
}

enum PowerAction: String, Identifiable {
    case shutdown, restart
    var id: String { rawValue }
    var title: String {
        self == .shutdown ? "atlas herunterfahren?" : "atlas neu starten?"
    }
    var message: String {
        "Die Aktion wird sofort auf atlas ausgeführt und benötigt einen konfigurierten Token."
    }
    var confirm: String {
        self == .shutdown ? "Herunterfahren" : "Neustarten"
    }
}
