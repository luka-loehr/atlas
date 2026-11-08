import SwiftUI
import BackgroundTasks

@main
struct AtlasApp: App {
    static let backupTaskID = "com.lukaloehr.atlas.ios.backup"
    static let refreshTaskID = "com.lukaloehr.atlas.ios.refresh"

    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var session = Session()

    init() { Self.registerBackgroundTasks() }

    var body: some Scene {
        WindowGroup {
            RootView().environment(session)
        }
    }

    // MARK: Background work while the app is closed

    private static func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: backupTaskID, using: nil) { task in
            guard let task = task as? BGProcessingTask else { return }
            handle(task, processing: true)
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshTaskID, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            handle(task, processing: false)
        }
    }

    /// Asks iOS for the next background windows: a short refresh (new photos
    /// are queued for upload) and a long processing run (backup and the
    /// thumbnail store). Safe to call repeatedly.
    static func scheduleBackgroundWork() {
        let processing = BGProcessingTaskRequest(identifier: backupTaskID)
        processing.requiresNetworkConnectivity = true
        processing.requiresExternalPower = false
        try? BGTaskScheduler.shared.submit(processing)
        let refresh = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        refresh.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(refresh)
    }

    private static func handle(_ task: BGTask, processing: Bool) {
        task.expirationHandler = {
            Task { @MainActor in
                BackupService.shared.cancelBackgroundWork()
                ThumbFill.shared.stop()
            }
        }
        Task { @MainActor in
            defer { scheduleBackgroundWork() }   // keep the chain alive
            let session = Session()
            guard session.isConnected else {
                task.setTaskCompleted(success: true)
                return
            }
            BackupService.shared.configure(host: session.base)
            var ok = await BackupService.shared.runInBackground(window: processing ? 64 : 24)
            if processing {
                // the timeline from disk and the server, then the thumbnails
                let library = Library()
                library.host = session.base
                await library.start()
                await WidgetShelf.shared.refresh(library: library, force: true)
                await ThumbFill.shared.finish()
                ok = ok && ThumbFill.shared.failed == 0
            }
            task.setTaskCompleted(success: ok)
        }
    }
}

/// Hands the background upload session's wake-ups to the backup service.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == BackupService.sessionID else { completionHandler(); return }
        MainActor.assumeIsolated {
            let session = Session()
            // no server, no session to deliver the events: iOS must not wait
            guard session.isConnected else { completionHandler(); return }
            BackupService.shared.backgroundEventsDone = completionHandler
            BackupService.shared.configure(host: session.base)
        }
    }
}
