import SwiftUI
import BackgroundTasks

@main
struct AtlasApp: App {
    static let backupTaskID = "com.lukaloehr.Atlas.backup"

    @State private var session = Session()

    init() { Self.registerBackupTask() }

    var body: some Scene {
        WindowGroup {
            RootView().environment(session)
        }
    }

    // MARK: Background backup (BGProcessingTask)

    /// The sync driven by the current background task — lets the expiration
    /// handler cancel it from any queue.
    @MainActor private static var backgroundSync: DeviceSync?

    private static func registerBackupTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: backupTaskID, using: nil) { task in
            guard let task = task as? BGProcessingTask else { return }
            handleBackup(task)
        }
    }

    /// Asks iOS to run the backup task at a good moment (charging not required,
    /// network required). Safe to call repeatedly — one pending request per id.
    static func scheduleBackup() {
        let request = BGProcessingTaskRequest(identifier: backupTaskID)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func handleBackup(_ task: BGProcessingTask) {
        task.expirationHandler = {
            Task { @MainActor in backgroundSync?.cancel() }
        }
        Task { @MainActor in
            defer {
                backgroundSync = nil
                scheduleBackup()   // keep the chain alive for the next window
            }
            // without a connected server there is nothing to back up to
            let session = Session()
            guard UserDefaults.standard.bool(forKey: "photos.autoBackup"), session.isConnected else {
                task.setTaskCompleted(success: true)
                return
            }
            let sync = DeviceSync(client: PhotoClient(host: session.base))
            backgroundSync = sync
            guard await sync.requestAccess() else {
                task.setTaskCompleted(success: false)
                return
            }
            await sync.scan()
            if case .failed = sync.phase {
                task.setTaskCompleted(success: false)
                return
            }
            await sync.backupNew()
            task.setTaskCompleted(success: sync.failed == 0)
        }
    }
}

struct RootView: View {
    @Environment(Session.self) private var session
    @State private var library = Library()
    @State private var watchSync: DeviceSync?
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("photos.autoBackup") private var autoBackup = false
    @State private var tab = "photos"
    @State private var linkError: String?

    var body: some View {
        Group {
            if session.isConnected {
                TabView(selection: $tab) {
                    Tab("Fotos", systemImage: "photo.on.rectangle.angled", value: "photos") {
                        PhotosScreen(library: library)
                    }
                    Tab("Alben", systemImage: "rectangle.stack", value: "albums") {
                        AlbumsScreen(library: library)
                    }
                    Tab("Dateien", systemImage: "folder", value: "drive") {
                        DriveScreen(library: library)
                    }
                    Tab("Einstellungen", systemImage: "gearshape", value: "settings") {
                        SettingsTab(library: library)
                    }
                    Tab(value: "search", role: .search) {
                        SearchScreen(library: library)
                    }
                }
                .tint(.primary)
            } else {
                ConnectScreen()
            }
        }
        .task(id: session.config) {
            #if targetEnvironment(simulator)
            // ATLAS_TAB=albums|drive|settings|search opens a simulator on that tab
            if let wanted = ProcessInfo.processInfo.environment["ATLAS_TAB"] { tab = wanted }
            #endif
            guard session.isConnected else {
                library.host = ""
                library.reset()
                return
            }
            library.host = session.base
            if autoBackup, watchSync == nil {
                let sync = DeviceSync(client: library.client)
                sync.startWatching()
                watchSync = sync
            }
            await library.start()
        }
        .onChange(of: scenePhase) { _, phase in
            guard session.isConnected else { return }
            if phase == .background, autoBackup {
                AtlasApp.scheduleBackup()
            }
            if phase == .active {
                Task { await library.refresh() }
            }
            // instant foreground sync: photos taken while the app was closed
            // appear in the grid within a second (local thumb seeded, upload
            // runs behind it) — Google-Photos-Gefühl beim Öffnen
            if phase == .active, autoBackup {
                Task {
                    let sync = watchSync ?? DeviceSync(client: library.client)
                    sync.client = library.client
                    if watchSync == nil { watchSync = sync }
                    guard await sync.requestAccess() else { return }
                    await sync.quickSync(into: library)
                }
            }
        }
        .onOpenURL { url in
            Task {
                do { try await session.handle(url) } catch { linkError = error.localizedDescription }
            }
        }
        .alert("Verbindung fehlgeschlagen", isPresented: Binding(get: { linkError != nil }, set: { if !$0 { linkError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(linkError ?? "")
        }
    }
}

/// Erster Start: Wo steht der Server, und wie lautet das Zugangstoken.
struct ConnectScreen: View {
    @Environment(Session.self) private var session
    @State private var address = ""
    @State private var token = ""
    @State private var connecting = false
    @State private var error: String?
    @FocusState private var focus: Field?

    private enum Field { case address, token }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "photo.stack")
                            .font(.system(size: 30, weight: .medium))
                            .foregroundStyle(.primary)
                            .frame(width: 78, height: 78)
                            .glassEffect(.regular, in: Circle())
                        Text("Mit atlas verbinden")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                        Text("Deine Fotos und Dateien liegen auf deinem eigenen Server. Gib seine Adresse und das Zugangstoken ein.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .listRowBackground(Color.clear)
                }
                Section {
                    TextField("Serveradresse", text: $address, prompt: Text("atlas.your-tailnet.ts.net"))
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(size: 15, design: .monospaced))
                        .focused($focus, equals: .address)
                        .submitLabel(.next)
                        .onSubmit { focus = .token }
                    SecureField("Zugangstoken", text: $token)
                        .textContentType(.password)
                        .focused($focus, equals: .token)
                        .submitLabel(.go)
                        .onSubmit { connect() }
                } footer: {
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    } else {
                        Text("„atlas connect“ auf dem Mac zeigt einen Link, der beides ausfüllt.")
                    }
                }
                Section {
                    Button {
                        connect()
                    } label: {
                        HStack {
                            Spacer()
                            if connecting { ProgressView() } else { Text("Verbinden").fontWeight(.semibold) }
                            Spacer()
                        }
                    }
                    .disabled(address.isEmpty || token.isEmpty || connecting)
                }
            }
        }
    }

    private func connect() {
        guard !address.isEmpty, !token.isEmpty else { return }
        connecting = true
        error = nil
        Task {
            defer { connecting = false }
            do {
                try await session.connect(to: address, token: token)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
