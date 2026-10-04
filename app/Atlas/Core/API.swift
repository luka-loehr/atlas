import Foundation

/// Where the server is and how to prove we may talk to it.
struct ServerConfig: Equatable, Sendable {
    var url: URL
    var token: String
}

enum APIError: LocalizedError {
    case notConnected
    case unauthorized
    case unreachable
    case server(Int)

    var errorDescription: String? {
        switch self {
        case .notConnected: "Not connected to a server."
        case .unauthorized: "The server rejected the access token."
        case .unreachable: "The server can’t be reached. On the tailnet? Is atlas awake?"
        case .server(let code): "The server reported an error (\(code))."
        }
    }
}

/// The Atlas HTTP API. A value type: cheap to copy into tasks, no shared state
/// beyond the URL session.
struct API: Sendable {
    let config: ServerConfig

    /// One session for the API: server status and power, and the live
    /// streams. Its answers are live, so nothing is cached; media lives in
    /// `MediaStore`.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpMaximumConnectionsPerHost = 12
        configuration.timeoutIntervalForRequest = 30
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = try? Date(text, strategy: .iso8601) { return date }
            // fractional seconds
            let style = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
            if let date = try? Date(text, strategy: style) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad date \(text)"))
        }
        return decoder
    }()

    // MARK: URLs

    func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        var components = URLComponents(url: config.url.appending(path: "v1/" + path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        return components.url!
    }

    func request(_ url: URL, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        return request
    }

    // MARK: Calls

    @discardableResult
    func data(for request: URLRequest) async throws -> Data {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch is URLError {
            throw APIError.unreachable
        }
        try Self.check(response)
        return data
    }

    static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw APIError.unreachable }
        switch http.statusCode {
        case 200..<300: return
        case 401: throw APIError.unauthorized
        default: throw APIError.server(http.statusCode)
        }
    }

    func get<T: Decodable>(_ path: String, query: [URLQueryItem] = [], as type: T.Type = T.self) async throws -> T {
        let data = try await data(for: request(url(path, query: query)))
        return try Self.decoder.decode(T.self, from: data)
    }

    func send(_ method: String, _ path: String) async throws {
        try await data(for: request(url(path), method: method))
    }
}
