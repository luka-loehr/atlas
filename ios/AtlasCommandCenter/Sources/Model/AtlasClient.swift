import Foundation

/// Talks to atlas-agent over the tailnet.
struct AtlasClient: Sendable {
    var host: String          // e.g. "atlas.your-tailnet.ts.net:8787"
    var token: String?

    private func request(_ path: String, method: String = "GET") throws -> URLRequest {
        guard let url = URL(string: "http://\(host)\(path)") else { throw URLError(.badURL) }
        var req = URLRequest(url: url, timeoutInterval: 6)
        req.httpMethod = method
        if let token, !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return req
    }

    func fetch() async throws -> Metrics {
        let (data, resp) = try await URLSession.shared.data(for: request("/api/metrics"))
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(Metrics.self, from: data)
    }

    /// action = "shutdown" | "restart" (requires a token on the agent side).
    func power(_ action: String) async throws {
        let (_, resp) = try await URLSession.shared.data(for: request("/api/power/\(action)", method: "POST"))
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
    }
}
