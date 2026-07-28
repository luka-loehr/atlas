import Foundation

// The bridge is our own service on atlas (agents/paperclip-bridge). It owns
// everything Paperclip doesn't model well: the curated board (BoardAPI.swift),
// the questions agents raise, and what the fleet is costing.
//
// Read-only on purpose. The bridge routes GET /asks but has no route that
// answers one, so asks are surfaced here and answered elsewhere (the CLI on
// atlas). Do not add an answer() call until the bridge grows the endpoint.

struct Ask: Decodable, Sendable, Identifiable, Hashable {
    struct Option: Decodable, Sendable, Hashable {
        var label: String
        var value: String
        var kind: String
    }
    var id: String
    var createdAt: Double
    var agent: String
    var issue: String?
    var headline: String
    var detail: String?
    var options: [Option]
    var urgency: String
    var status: String

    var date: Date { Date(timeIntervalSince1970: createdAt) }
}

struct Spend: Decodable, Sendable {
    struct AgentSpend: Decodable, Sendable, Identifiable {
        var agentId: String
        var name: String?
        var model: String?
        var inputTokens: Int
        var outputTokens: Int
        var cachedInputTokens: Int
        var usd: Double
        var id: String { agentId }
    }
    struct Totals: Decodable, Sendable {
        var inputTokens: Int
        var outputTokens: Int
        var cachedInputTokens: Int
        var usd: Double
    }
    var agents: [AgentSpend]
    var totals: Totals

    static let empty = Spend(
        agents: [],
        totals: .init(inputTokens: 0, outputTokens: 0, cachedInputTokens: 0, usd: 0)
    )
}

struct BridgeClient: Sendable {
    var host: String
    var token: String

    private func request(_ path: String) throws -> URLRequest {
        guard let url = URL(string: "http://\(host)\(path)") else { throw URLError(.badURL) }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return req
    }

    private func run<T: Decodable>(_ req: URLRequest, _ type: T.Type) async throws -> T {
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func asks() async throws -> [Ask] {
        try await run(try request("/asks"), [Ask].self)
    }

    func spend() async throws -> Spend {
        try await run(try request("/spend"), Spend.self)
    }
}
