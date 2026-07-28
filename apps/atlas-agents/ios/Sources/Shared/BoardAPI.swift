import Foundation

// The curated board view. Every field here was written by the Atlas Agents
// Curator agent, not derived in the app — that is the whole point. The app
// renders; it never guesses which commit belongs to which issue.
//
// Served by agents/paperclip-bridge on the tailnet:
//   GET /board/issues[?status=]   summaries
//   GET /board/issues/{key}       one issue, full text + links
//   GET /board/fleet              who is working right now

struct BoardIssue: Decodable, Sendable, Identifiable, Hashable {
    var issueId: String
    var issueKey: String?
    var title: String
    var status: String
    var assignee: String?
    var headline: String?
    var needsLuka: String?
    var linkCount: Int?
    var sourceUpdatedAt: String?
    var curatedAt: String?

    var id: String { issueId }
    var key: String { issueKey ?? "—" }
    /// The curated line if we have one, the raw engineering title if we don't.
    var display: String { headline?.isEmpty == false ? headline! : title }
    var needsYou: Bool { !(needsLuka ?? "").isEmpty }
}

struct BoardIssueDetail: Decodable, Sendable {
    struct Link: Decodable, Sendable, Identifiable, Hashable {
        var kind: String?
        var repo: String?
        var ref: String?
        var subject: String?
        var url: String?
        var id: String { (repo ?? "") + (ref ?? UUID().uuidString) }
        var shortRef: String { String((ref ?? "").prefix(7)) }
    }
    var issueId: String
    var issueKey: String?
    var title: String
    var status: String
    var assignee: String?
    var headline: String?
    var needsLuka: String?
    var whatItIs: String?
    var whyItMatters: String?
    var currentState: String?
    var links: [Link]?
    var curatedAt: String?

    var key: String { issueKey ?? "—" }
    var needsYou: Bool { !(needsLuka ?? "").isEmpty }
}

struct Fleet: Decodable, Sendable {
    struct Worker: Decodable, Sendable, Identifiable, Hashable {
        var agentName: String?
        var issueKey: String?
        var headline: String?
        var startedAt: String?
        var id: String { (agentName ?? "") + (issueKey ?? "") + (startedAt ?? "") }
    }
    var present: Bool
    var takenAt: String?
    var running: Int
    var queued: Int
    var agents: [Worker]
    var ageSeconds: Double?

    static let empty = Fleet(present: false, takenAt: nil, running: 0, queued: 0,
                             agents: [], ageSeconds: nil)

    /// The snapshot is written by the Curator, so it can go stale if that agent
    /// stalls. Saying so is better than showing a confident wrong number.
    var isStale: Bool { (ageSeconds ?? 0) > 900 }
}

private struct BoardIssuesEnvelope: Decodable, Sendable {
    var issues: [BoardIssue]
    var count: Int?
    var truncated: Bool?
}

extension BridgeClient {
    func boardIssues(status: String? = nil) async throws -> [BoardIssue] {
        var path = "/board/issues"
        if let status, !status.isEmpty { path += "?status=\(status)" }
        return try await runBoard(path, BoardIssuesEnvelope.self).issues
    }

    func boardIssue(key: String) async throws -> BoardIssueDetail {
        try await runBoard("/board/issues/\(key)", BoardIssueDetail.self)
    }

    func fleet() async throws -> Fleet {
        try await runBoard("/board/fleet", Fleet.self)
    }

    private func runBoard<T: Decodable>(_ path: String, _ type: T.Type) async throws -> T {
        guard let url = URL(string: "http://\(host)\(path)") else { throw URLError(.badURL) }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - Naming
//
// The board's internal vocabulary is not what a person reads on a phone.
// "queued" made Luka think agents were stuck; "blocked" made him think
// something was broken. Neither is true, so neither word appears in the UI.

enum BoardWord {
    static func status(_ raw: String) -> String {
        switch raw {
        case "todo":        return "Not started"
        case "in_progress": return "Being worked on"
        case "in_review":   return "Done, awaiting your look"
        case "blocked":     return "Waiting on something"
        case "backlog":     return "Parked"
        case "done":        return "Finished"
        case "cancelled":   return "Dropped"
        default:            return raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// Sort order for the board — what needs attention first, noise last.
    static func rank(_ raw: String) -> Int {
        switch raw {
        case "in_progress": return 0
        case "in_review":   return 1
        case "blocked":     return 2
        case "todo":        return 3
        case "backlog":     return 4
        case "done":        return 5
        default:            return 6
        }
    }

    static let boardOrder = ["in_progress", "in_review", "blocked", "todo", "backlog", "done"]
}
