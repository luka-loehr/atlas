import SwiftUI

struct DashboardScreen: View {
    var host: String
    var token: String
    @Binding var showSettings: Bool

    @State private var model = DashboardModel()
    @State private var powerAction: PowerAction?
    @State private var showTerminal = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background
                DashboardView(model: model)
            }
            .navigationTitle("atlas")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showTerminal = true
                    } label: {
                        Image(systemName: "apple.terminal.fill")
                    }
                }
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
        .alert(
            powerAction?.title ?? "",
            isPresented: Binding(get: { powerAction != nil }, set: { if !$0 { powerAction = nil } }),
            presenting: powerAction
        ) { action in
            Button(action.confirm, role: .destructive) {
                Task { await model.sendPower(action.rawValue) }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: { action in
            Text(action.message)
        }
        .fullScreenCover(isPresented: $showTerminal) {
            TerminalSheet(host: host, token: token)
        }
        .task {
            model.host = host
            model.token = token
            model.start()
        }
        .onDisappear { model.stop() }
    }
}
