import Foundation
import SwiftUI

/// Everything the three screens read. Deliberately thin: the curated text is
/// authored on the server, so this holds it and nothing more.
@MainActor
@Observable
final class BoardStore {
    var issues: [BoardIssue] = []
    var fleet: Fleet = .empty
    var lastError: String?
    var lastRefresh: Date?
    var loading = false

    private var client: BridgeClient
    private var pollTask: Task<Void, Never>?

    init(client: BridgeClient) { self.client = client }

    func reconnect(_ client: BridgeClient) { self.client = client }

    var needsYou: [BoardIssue] { issues.filter(\.needsYou) }

    var active: [BoardIssue] {
        issues.filter { $0.status == "in_progress" || $0.status == "in_review" }
    }

    /// Board sections, in the order a person cares about them, empties dropped.
    var sections: [(status: String, issues: [BoardIssue])] {
        BoardWord.boardOrder.compactMap { st in
            let rows = issues.filter { $0.status == st }
            return rows.isEmpty ? nil : (st, rows)
        }
    }

    func refresh() async {
        loading = issues.isEmpty
        do {
            async let i = client.boardIssues()
            async let f = client.fleet()
            let (list, snap) = try await (i, f)
            issues = list.sorted {
                if $0.needsYou != $1.needsYou { return $0.needsYou }
                if BoardWord.rank($0.status) != BoardWord.rank($1.status) {
                    return BoardWord.rank($0.status) < BoardWord.rank($1.status)
                }
                return ($0.sourceUpdatedAt ?? "") > ($1.sourceUpdatedAt ?? "")
            }
            fleet = snap
            lastError = nil
            lastRefresh = Date()
        } catch {
            lastError = friendly(error)
        }
        loading = false
    }

    func detail(key: String) async -> BoardIssueDetail? {
        try? await client.boardIssue(key: key)
    }

    func startPolling(every seconds: TimeInterval = 30) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(seconds))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// URLError codes are meaningless on a phone screen. Say what to do instead.
    private func friendly(_ error: Error) -> String {
        guard let url = error as? URLError else { return error.localizedDescription }
        switch url.code {
        case .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet:
            return "Can't reach atlas. Is Tailscale on?"
        case .badServerResponse:
            return "atlas answered but rejected the request — check the token in Settings."
        case .timedOut:
            return "atlas didn't answer in time."
        default:
            return url.localizedDescription
        }
    }
}
