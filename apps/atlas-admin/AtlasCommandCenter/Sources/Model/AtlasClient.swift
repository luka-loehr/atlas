import Foundation

// Detail / list payloads for the v2 endpoints.

struct ContainerDetail: Codable, Sendable {
    let name: String
    let state: String
    let image: String
    let started: String
    let restarts: Int
    let ports: String
    let logs: String
}

/// Talks to atlas-agent over the tailnet.
struct AtlasClient: Sendable {
    var host: String          // e.g. "atlas.your-tailnet.ts.net:8787"
    var token: String?

    private func request(_ path: String, method: String = "GET", body: String? = nil, timeout: TimeInterval = 8) throws -> URLRequest {
        guard let url = URL(string: "http://\(host)\(path)") else { throw URLError(.badURL) }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method
        if let token, !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body { req.httpBody = body.data(using: .utf8) }
        return req
    }

    private func get<T: Decodable>(_ path: String, _ type: T.Type) async throws -> T {
        let (data, resp) = try await URLSession.shared.data(for: request(path))
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    @discardableResult
    private func post(_ path: String, body: String? = nil) async throws -> Data {
        let (data, resp) = try await URLSession.shared.data(for: request(path, method: "POST", body: body))
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    // metrics ----------------------------------------------------------------
    func fetch() async throws -> Metrics { try await get("/api/metrics", Metrics.self) }

    // docker -----------------------------------------------------------------
    func containers() async throws -> [Metrics.Container] {
        try await get("/api/docker", [Metrics.Container].self)
    }
    func inspect(_ name: String) async throws -> ContainerDetail {
        try await get("/api/docker/\(name)", ContainerDetail.self)
    }

    // exit node / activity -----------------------------------------------------
    func vpn() async throws -> VPNStatus { try await get("/api/vpn", VPNStatus.self) }
    func activity() async throws -> ActivityData { try await get("/api/activity", ActivityData.self) }

    // power ------------------------------------------------------------------
    func power(_ action: String) async throws { try await post("/api/power/\(action)") }

    // terminal ---------------------------------------------------------------
    func terminalURL() -> URL? {
        var s = "ws://\(host)/term"
        if let token, !token.isEmpty { s += "?token=\(token)" }
        return URL(string: s)
    }
}
