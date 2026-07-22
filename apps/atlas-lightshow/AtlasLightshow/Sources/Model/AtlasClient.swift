import Foundation

struct Show: Codable, Sendable, Identifiable, Hashable {
    let name: String
    let title: String
    let bpm: Double
    let durationS: Double
    let running: Bool
    var id: String { name }
    enum CodingKeys: String, CodingKey {
        case name, title, bpm, running
        case durationS = "duration_s"
    }
}

struct ShowsResponse: Codable, Sendable {
    let bridge: Bool
    let shows: [Show]
}

struct CreateStatus: Codable, Sendable {
    let running: Bool
    let done: Bool
    let failed: Bool
    let phase: String       // idle|start|download|analyze|gemini|claude|compile|commit|done
    let percent: Double     // download progress 0…100
    let title: String
    let thumb: Bool
    let name: String?
    let ai: String          // live claude thinking/output ticker (last lines)
    let summary: String     // AI dramaturgy summary once composed
    let log: String
}

/// Manual-control state from /api/lights.
struct LightsState: Codable, Sendable {
    let bridge: Bool
    let on: Bool
    let channels: [Int]     // the held 21-channel DMX frame
}

/// Talks to atlas-agent over the tailnet — the lightshow slice of the API.
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

    // shows ------------------------------------------------------------------
    func shows() async throws -> ShowsResponse { try await get("/api/shows", ShowsResponse.self) }
    func createShow(url: String, ai: Bool = true) async throws {
        try await post("/api/shows/create", body: ai ? "ai \(url)" : url)
    }
    func createStatus() async throws -> CreateStatus { try await get("/api/shows/create/status", CreateStatus.self) }
    func startShow(_ name: String) async throws { try await post("/api/shows/start", body: name) }
    func stopShow() async throws { try await post("/api/shows/stop") }
    func stopBridge() async throws { try await post("/api/bridge/stop") }
    func audioURL(_ name: String) -> URL? { URL(string: "http://\(host)/api/shows/audio/\(name)") }
    func createThumbURL() -> URL? { URL(string: "http://\(host)/api/shows/create/thumb") }
    func showThumbURL(_ name: String) -> URL? { URL(string: "http://\(host)/api/shows/thumb/\(name)") }

    // manual lights ------------------------------------------------------------
    func lights() async throws -> LightsState { try await get("/api/lights", LightsState.self) }
    @discardableResult
    func lightsSet(_ channels: [Int]) async throws -> LightsState {
        let body = channels.map(String.init).joined(separator: ",")
        let data = try await post("/api/lights/set", body: body)
        return try JSONDecoder().decode(LightsState.self, from: data)
    }
    func lightsOff() async throws { try await post("/api/lights/off") }

    // fog --------------------------------------------------------------------
    func fog(ms: Int) async throws { try await post("/api/fog", body: String(ms)) }
    func fogStop() async throws { try await post("/api/fog/stop") }

    // calibration ------------------------------------------------------------
    func saveCalibration(ms: Double) async throws {
        try await post("/api/calibrate/save", body: String(format: "%.0f", ms))
    }
}
