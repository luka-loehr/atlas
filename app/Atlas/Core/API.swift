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

    /// One session for everything. Media responses are immutable and carry
    /// long cache lifetimes, so the URL cache is the thumbnail disk cache.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpMaximumConnectionsPerHost = 12
        configuration.timeoutIntervalForRequest = 30
        configuration.waitsForConnectivity = false
        configuration.urlCache = URLCache(memoryCapacity: 32 << 20, diskCapacity: 4 << 30)
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

    /// For players that cannot attach a header: the token rides in the query.
    func playerURL(_ path: String, query: [URLQueryItem] = []) -> URL {
        url(path, query: query + [URLQueryItem(name: "token", value: config.token)])
    }

    func thumbURL(_ id: String, size: Int) -> URL { url("assets/\(id)/thumb/\(size)") }
    func originalURL(_ id: String) -> URL { url("assets/\(id)/original") }
    func faceURL(_ face: Int) -> URL { url("faces/\(face)/crop") }

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

    /// The last answer the URL cache holds for this GET, without touching the
    /// network: what a screen shows while the fresh answer is on its way, or
    /// when the server is asleep.
    func cached<T: Decodable>(_ path: String, query: [URLQueryItem] = [], as type: T.Type = T.self) -> T? {
        var request = request(url(path, query: query))
        request.cachePolicy = .returnCacheDataDontLoad
        guard let hit = Self.session.configuration.urlCache?.cachedResponse(for: request) else { return nil }
        return try? Self.decoder.decode(T.self, from: hit.data)
    }

    @discardableResult
    func send<Body: Encodable, T: Decodable>(_ method: String, _ path: String, body: Body, as type: T.Type = T.self) async throws -> T {
        var request = request(url(path), method: method)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try Self.decoder.decode(T.self, from: try await data(for: request))
    }

    func send(_ method: String, _ path: String) async throws {
        try await data(for: request(url(path), method: method))
    }

    /// Stream a file to the server as a request body; nothing is read into
    /// memory. `progress` reports the fraction sent.
    func upload(file: URL, to path: String, headers: [String: String], progress: (@Sendable (Double) -> Void)? = nil) async throws -> Data {
        var request = request(url(path), method: "PUT")
        request.timeoutInterval = 3600
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let delegate = progress.map(UploadProgress.init)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await Self.session.upload(for: request, fromFile: file, delegate: delegate)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch is URLError {
            throw APIError.unreachable
        }
        try Self.check(response)
        return data
    }

    /// Download to a temporary file that carries `name`, for Quick Look and
    /// the share sheet. Served from the URL cache when it was fetched before.
    func download(_ url: URL, named name: String) async throws -> URL {
        let (temporary, response): (URL, URLResponse)
        do {
            (temporary, response) = try await Self.session.download(for: request(url))
        } catch is URLError {
            throw APIError.unreachable
        }
        try Self.check(response)
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appending(path: name.isEmpty ? "file" : name)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }
}

private final class UploadProgress: NSObject, URLSessionTaskDelegate, Sendable {
    let report: @Sendable (Double) -> Void
    init(_ report: @escaping @Sendable (Double) -> Void) { self.report = report }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        report(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }
}

/// Header values travel as latin-1: names with umlauts are percent-encoded.
func headerEncoded(_ name: String) -> String {
    name.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-._"))) ?? "file"
}

struct Updated: Decodable { var updated: Int? }
struct Empty: Decodable {}
struct IDs<ID: Encodable>: Encodable { var ids: [ID] }
struct IDsValue: Encodable { var ids: [String]; var value: Bool }
