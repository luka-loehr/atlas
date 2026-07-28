import Foundation

// MARK: - Models (shapes match the Paperclip board API exactly)

struct Dashboard: Decodable, Sendable {
    struct AgentCounts: Decodable, Sendable {
        var active: Int
        var running: Int
        var paused: Int
        var error: Int
    }
    struct TaskCounts: Decodable, Sendable {
        var open: Int
        var inProgress: Int
        var blocked: Int
        var done: Int
    }
    struct Costs: Decodable, Sendable {
        var monthSpendCents: Int
        var monthBudgetCents: Int
    }
    struct RunDay: Decodable, Sendable, Identifiable {
        var date: String
        var succeeded: Int
        var failed: Int
        var total: Int
        var id: String { date }
    }
    var agents: AgentCounts
    var tasks: TaskCounts
    var costs: Costs
    var pendingApprovals: Int
    var runActivity: [RunDay]
}

struct PCAgent: Decodable, Sendable, Identifiable {
    struct AdapterConfig: Decodable, Sendable {
        var model: String?
        var engine: String?
    }
    var id: String
    var name: String
    var role: String?
    var title: String?
    var icon: String?
    var status: String
    var reportsTo: String?
    var lastHeartbeatAt: String?
    var spentMonthlyCents: Int?
    var budgetMonthlyCents: Int?
    var adapterType: String?
    var adapterConfig: AdapterConfig?
    var pauseReason: String?
    var errorReason: String?

    var isRunning: Bool { status == "running" }
}

struct PCIssue: Decodable, Sendable, Identifiable {
    var id: String
    var identifier: String?
    var title: String
    var description: String?
    var status: String
    var priority: String?
    var assigneeAgentId: String?
    var createdByAgentId: String?
    var createdAt: String?
    var updatedAt: String?
    var completedAt: String?
}

struct PCActivity: Decodable, Sendable, Identifiable {
    var id: String
    var action: String
    var actorType: String?
    var agentId: String?
    var entityType: String?
    var entityId: String?
    var createdAt: String
}

struct PCArtifactPage: Decodable, Sendable {
    var artifacts: [PCArtifact]
    var nextCursor: String?
}

struct PCArtifact: Decodable, Sendable, Identifiable {
    struct IssueRef: Decodable, Sendable {
        var id: String
        var identifier: String?
        var title: String?
    }
    struct AgentRef: Decodable, Sendable {
        var id: String?
        var name: String?
    }
    struct ProjectRef: Decodable, Sendable {
        var id: String?
        var name: String?
    }
    var id: String
    var source: String?
    var mediaKind: String?
    var title: String?
    var previewText: String?
    var contentType: String?
    var updatedAt: String?
    var issue: IssueRef?
    var project: ProjectRef?
    var createdByAgent: AgentRef?

    /// "document:<uuid>" → "<uuid>"
    var documentId: String? {
        guard let r = id.range(of: "document:") else { return nil }
        return String(id[r.upperBound...])
    }
}

struct PCDocument: Decodable, Sendable, Identifiable {
    var id: String
    var issueId: String
    var key: String
    var title: String?
    var format: String?
    var body: String
    var latestRevisionNumber: Int?
    var createdByAgentId: String?
    var createdAt: String?
    var updatedAt: String?
}

struct HeartbeatRunRef: Decodable, Sendable {
    var id: String
    var status: String?
}

/// An agent asking Luka something and blocking on the answer.
struct PCInteraction: Decodable, Sendable, Identifiable {
    struct Payload: Decodable, Sendable {
        var prompt: String?
        var allowDeclineReason: Bool?
    }
    var id: String
    var issueId: String
    var kind: String
    var status: String
    var payload: Payload?
    var createdByAgentId: String?
    var createdAt: String?

    var prompt: String? { payload?.prompt }
    var isPending: Bool { status == "pending" }

    var kindLabel: String {
        switch kind {
        case "request_confirmation": "Needs your confirmation"
        case "request_input": "Needs your input"
        case "request_decision": "Needs your decision"
        default: kind.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

struct PCComment: Decodable, Sendable, Identifiable {
    var id: String
    var body: String
    var authorType: String?
    var authorAgentId: String?
    var authorUserId: String?
    var createdAt: String?
}

struct PCRun: Decodable, Sendable, Identifiable {
    struct Usage: Decodable, Sendable {
        var costUsd: Double?
        var inputTokens: Int?
        var outputTokens: Int?
    }
    var runId: String
    var status: String
    var agentId: String?
    var startedAt: String?
    var finishedAt: String?
    var errorCode: String?
    var usageJson: Usage?

    var id: String { runId }
}

struct PCRunEvent: Decodable, Sendable, Identifiable {
    var id: Int
    var seq: Int
    var eventType: String?
    var stream: String?
    var level: String?
    var message: String?
    var createdAt: String?
}

struct PCCostSummary: Decodable, Sendable {
    var costCents: Int?
    var inputTokens: Int?
    var outputTokens: Int?
    var runCount: Int?
    var runtimeMs: Int?
}

struct PCProject: Decodable, Sendable, Identifiable {
    var id: String
    var name: String
    var status: String?
    var description: String?
}

struct PCSkill: Decodable, Sendable, Identifiable {
    var id: String
    var name: String
    var slug: String?
    var description: String?
    var folderPath: String?
}

struct PCRoutine: Decodable, Sendable, Identifiable {
    var id: String
    var title: String
    var status: String?
    var enabled: Bool?
    var scheduleKind: String?
}

/// Paperclip reports the model an agent is configured with, but atlas rewrites
/// some of those on the way to the CLI (see the model shim on the box), so the
/// label a human should read is not always the configured id.
enum ModelLabel {
    /// Mirrors /home/luka/.paperclip/model-map.conf on atlas.
    static let shim: [String: String] = ["claude-opus-4-8": "claude-opus-5"]

    /// Proper product names. Splitting on hyphens turns "haiku-4-5" into
    /// "Haiku 4 5", so map the ones we ship and fall back sensibly.
    private static let names: [String: String] = [
        "claude-opus-5": "Opus 5",
        "claude-opus-4-8": "Opus 4.8",
        "claude-opus-4-7": "Opus 4.7",
        "claude-opus-4-6": "Opus 4.6",
        "claude-sonnet-5": "Sonnet 5",
        "claude-sonnet-4-6": "Sonnet 4.6",
        "claude-haiku-4-5": "Haiku 4.5",
        "claude-fable-5": "Fable 5",
        "claude-mythos-5": "Mythos 5",
    ]

    /// nil when the agent has no model of its own — the caller decides whether
    /// that's worth showing at all, rather than printing "default".
    static func display(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let effective = shim[raw] ?? raw
        if let name = names[effective] { return name }
        // unknown id: strip the vendor prefix, keep the version readable
        let bare = effective.replacingOccurrences(of: "claude-", with: "")
        guard let first = bare.split(separator: "-").first else { return bare }
        let version = bare.dropFirst(first.count).replacingOccurrences(of: "-", with: ".")
        return first.capitalized + version
    }

    /// True when the shim is what makes this model different from the config.
    static func isRewritten(_ raw: String?) -> Bool {
        guard let raw else { return false }
        return shim[raw] != nil
    }
}

// MARK: - Client

struct PaperclipClient: Sendable {
    var host: String     // e.g. "atlas.your-tailnet.ts.net:3100"
    var token: String
    var companyId: String

    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func date(_ s: String?) -> Date? {
        guard let s else { return nil }
        return iso.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    enum ClientError: LocalizedError {
        case http(Int, String)
        var errorDescription: String? {
            if case let .http(code, body) = self { return "HTTP \(code): \(body)" }
            return nil
        }
    }

    private func request(_ path: String, method: String = "GET", json: [String: Any]? = nil) throws -> URLRequest {
        guard let url = URL(string: "http://\(host)\(path)") else { throw URLError(.badURL) }
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        return req
    }

    private func run<T: Decodable>(_ req: URLRequest, _ type: T.Type) async throws -> T {
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientError.http(http.statusCode, String(data: data.prefix(200), encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func get<T: Decodable>(_ path: String, _ type: T.Type) async throws -> T {
        try await run(try request(path), type)
    }

    // reads -----------------------------------------------------------------
    func dashboard() async throws -> Dashboard {
        try await get("/api/companies/\(companyId)/dashboard", Dashboard.self)
    }
    func agents() async throws -> [PCAgent] {
        try await get("/api/companies/\(companyId)/agents", [PCAgent].self)
    }
    func issues() async throws -> [PCIssue] {
        try await get("/api/companies/\(companyId)/issues", [PCIssue].self)
    }
    func activity(limit: Int = 30) async throws -> [PCActivity] {
        try await get("/api/companies/\(companyId)/activity?limit=\(limit)", [PCActivity].self)
    }
    func artifacts() async throws -> [PCArtifact] {
        try await get("/api/companies/\(companyId)/artifacts", PCArtifactPage.self).artifacts
    }
    func documents(issueId: String) async throws -> [PCDocument] {
        try await get("/api/issues/\(issueId)/documents", [PCDocument].self)
    }

    // writes ----------------------------------------------------------------
    /// Create an issue; the CEO triages everything that lands in todo.
    func createIssue(title: String, description: String, priority: String, assigneeAgentId: String?) async throws -> PCIssue {
        var body: [String: Any] = [
            "title": title,
            "status": "todo",
            "priority": priority,
        ]
        if !description.isEmpty { body["description"] = description }
        if let assigneeAgentId { body["assigneeAgentId"] = assigneeAgentId }
        return try await run(try request("/api/companies/\(companyId)/issues", method: "POST", json: body), PCIssue.self)
    }

    func wake(agentId: String) async throws {
        _ = try await run(try request("/api/agents/\(agentId)/heartbeat/invoke", method: "POST", json: [:]), HeartbeatRunRef.self)
    }

    // issue reads ------------------------------------------------------------
    func interactions(issueId: String) async throws -> [PCInteraction] {
        try await get("/api/issues/\(issueId)/interactions", [PCInteraction].self)
    }
    func comments(issueId: String) async throws -> [PCComment] {
        try await get("/api/issues/\(issueId)/comments", [PCComment].self)
    }
    func runs(issueId: String) async throws -> [PCRun] {
        try await get("/api/issues/\(issueId)/runs", [PCRun].self)
    }
    func costSummary(issueId: String) async throws -> PCCostSummary {
        try await get("/api/issues/\(issueId)/cost-summary", PCCostSummary.self)
    }
    func runEvents(runId: String) async throws -> [PCRunEvent] {
        try await get("/api/heartbeat-runs/\(runId)/events", [PCRunEvent].self)
    }
    func projects() async throws -> [PCProject] {
        try await get("/api/companies/\(companyId)/projects", [PCProject].self)
    }
    func skills() async throws -> [PCSkill] {
        try await get("/api/companies/\(companyId)/skills", [PCSkill].self)
    }
    func routines() async throws -> [PCRoutine] {
        try await get("/api/companies/\(companyId)/routines", [PCRoutine].self)
    }

    // issue actions ----------------------------------------------------------
    private func send(_ path: String, method: String = "POST", json: [String: Any]? = nil) async throws {
        let (data, resp) = try await URLSession.shared.data(for: try request(path, method: method, json: json))
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            throw ClientError.http(code, String(data: data.prefix(200), encoding: .utf8) ?? "")
        }
    }

    /// Accept the work — Paperclip closes the issue.
    func approve(issueId: String, comment: String?) async throws {
        var body: [String: Any] = ["status": "done"]
        if let comment, !comment.isEmpty { body["comment"] = comment }
        try await send("/api/issues/\(issueId)", method: "PATCH", json: body)
    }

    /// Send it back with a note; the assignee gets woken to act on it.
    func requestChanges(issueId: String, comment: String) async throws {
        try await send("/api/issues/\(issueId)", method: "PATCH",
                       json: ["status": "in_progress", "comment": comment, "reviewRequest": "changes_requested"])
    }

    func setStatus(issueId: String, status: String) async throws {
        try await send("/api/issues/\(issueId)", method: "PATCH", json: ["status": status])
    }
    func setPriority(issueId: String, priority: String) async throws {
        try await send("/api/issues/\(issueId)", method: "PATCH", json: ["priority": priority])
    }
    func reassign(issueId: String, agentId: String) async throws {
        try await send("/api/issues/\(issueId)", method: "PATCH", json: ["assigneeAgentId": agentId])
    }
    func comment(issueId: String, body: String) async throws {
        try await send("/api/issues/\(issueId)/comments", json: ["body": body])
    }

    // interaction actions ----------------------------------------------------
    func acceptInteraction(issueId: String, interactionId: String) async throws {
        try await send("/api/issues/\(issueId)/interactions/\(interactionId)/accept", json: [:])
    }
    func rejectInteraction(issueId: String, interactionId: String, reason: String) async throws {
        try await send("/api/issues/\(issueId)/interactions/\(interactionId)/reject",
                       json: reason.isEmpty ? [:] : ["reason": reason])
    }
    func respondInteraction(issueId: String, interactionId: String, response: String) async throws {
        try await send("/api/issues/\(issueId)/interactions/\(interactionId)/respond",
                       json: ["response": response])
    }

    // routines ---------------------------------------------------------------
    func runRoutine(routineId: String) async throws {
        try await send("/api/companies/\(companyId)/routines/\(routineId)/run", json: [:])
    }

    struct Empty: Decodable {}
    func pause(agentId: String) async throws {
        let req = try request("/api/agents/\(agentId)/pause", method: "POST", json: [:])
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }
    func resume(agentId: String) async throws {
        let req = try request("/api/agents/\(agentId)/resume", method: "POST", json: [:])
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }
}
