import BackgroundTasks
import SwiftUI

@main
struct AtlasAgentsApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: "com.lukaloehr.AtlasAgents.refresh", using: nil) { task in
            Self.handleRefresh(task: task as! BGAppRefreshTask)
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .task {
                    NotificationEngine.requestPermission()
                    model.startPolling()
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        model.startPolling()
                    case .background:
                        model.stopPolling()
                        Self.scheduleRefresh()
                    default:
                        break
                    }
                }
        }
    }

    // MARK: background refresh → local notifications while the app is closed

    static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: "com.lukaloehr.AtlasAgents.refresh")
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    static func handleRefresh(task: BGAppRefreshTask) {
        scheduleRefresh()  // keep the chain alive
        let host = UserDefaults.standard.string(forKey: "pcHost") ?? Secrets.host
        let token = UserDefaults.standard.string(forKey: "pcToken") ?? Secrets.token
        let client = PaperclipClient(host: host, token: token, companyId: Secrets.companyId)
        let work = Task {
            do {
                async let issues = client.issues()
                async let artifacts = client.artifacts()
                let (_, arts) = try await (issues, artifacts)
                let bridge = BridgeClient(
                    host: UserDefaults.standard.string(forKey: "bridgeHost") ?? Secrets.bridgeHost,
                    token: token)
                let asks = (try? await bridge.asks()) ?? []
                NotificationEngine.diffAndNotify(asks: asks, artifacts: arts)
                task.setTaskCompleted(success: true)
            } catch {
                task.setTaskCompleted(success: false)
            }
        }
        task.expirationHandler = { work.cancel() }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var board: BoardStore?

    var body: some View {
        @Bindable var model = model
        Group {
            if let board {
                TabView(selection: $model.selectedTab) {
                    NowScreen()
                        .tabItem { Label("Now", systemImage: "bolt.fill") }
                        .badge(board.needsYou.count)
                        .tag(1)
                    BoardScreen()
                        .tabItem { Label("Board", systemImage: "square.stack") }
                        .tag(2)
                    SettingsScreen()
                        .tabItem { Label("Settings", systemImage: "gearshape") }
                        .tag(3)
                }
                .environment(board)
            } else {
                ZStack { Theme.background; ProgressView().tint(.white) }
            }
        }
        .task {
            // one store for the whole app, rebuilt if the connection changes
            let store = board ?? BoardStore(client: model.bridge)
            store.reconnect(model.bridge)
            board = store
            store.startPolling()
        }
    }
}
