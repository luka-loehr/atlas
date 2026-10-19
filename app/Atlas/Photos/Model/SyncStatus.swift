import Foundation
import Observation

/// One short line on what is being synced right now, on this iPhone and on
/// atlas: the Sync row under Backup in Settings. Nothing pops up; it is
/// there to look at.
@MainActor
@Observable
final class SyncStatus {
    static let shared = SyncStatus()

    /// atlas' jobs in progress by kind (GET /v1/work); empty when idle or
    /// unreachable.
    private(set) var server: [String: Int] = [:]

    /// Reads atlas' work every few seconds while someone looks (the Settings
    /// sheet runs this as its task, so it stops when the sheet closes).
    func watch(_ client: PhotoClient) async {
        while !Task.isCancelled {
            server = (try? await client.work()) ?? [:]
            try? await Task.sleep(for: .seconds(4))
        }
    }

    /// What is happening, and whether anything is.
    func line(_ library: Library) -> (text: String, busy: Bool) {
        let parts = [onPhone(library), onServer()].compactMap { $0 }
        return parts.isEmpty ? ("Up to date", false) : (parts.joined(separator: " · "), true)
    }

    private func onPhone(_ library: Library) -> String? {
        let backup = BackupService.shared
        if case .scanning(let done, let total) = backup.phase {
            return "Checking new photos \(done.formatted())/\(total.formatted())"
        }
        if backup.uploading > 0 {
            let of = backup.pending > backup.uploading ? " of \(backup.pending.formatted())" : ""
            return "Uploading \(backup.uploading.formatted())\(of)"
        }
        let fill = ThumbFill.shared
        if fill.total > 0, !fill.complete, fill.running || fill.paused != nil {
            if let reason = fill.paused { return "Thumbnails: \(reason)" }
            return "Getting thumbnails, \((fill.total - fill.stored).formatted()) left"
        }
        if library.refreshing { return "Updating library" }
        return nil
    }

    private func onServer() -> String? {
        let n = { (kind: String) in self.server[kind] ?? 0 }
        let count = { (n: Int) in n.formatted() }
        if n("thumb") + n("meta") > 0 { return "atlas preparing \(count(max(n("thumb"), n("meta"))))" }
        if n("embed") > 0 { return "atlas indexing \(count(n("embed"))) for search" }
        if n("faces") > 0 { return "atlas finding faces in \(count(n("faces")))" }
        if n("preview") > 0 { return "atlas optimizing \(count(n("preview"))) videos" }
        if n("drive_text") > 0 { return "atlas reading \(count(n("drive_text"))) files" }
        if n("geocode") > 0 { return "atlas placing \(count(n("geocode")))" }
        return nil
    }
}

extension PhotoClient {
    /// atlas' jobs in progress by kind.
    func work() async throws -> [String: Int] {
        try await get("/work")
    }
}
