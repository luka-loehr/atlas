import Foundation

// Write-path + curation endpoints of the Atlas server.
// Kept in its own file so PhotoClient.swift stays the read-only surface.

extension PhotoClient {

    // MARK: - Wire helpers

    private static let mutationEncoder = JSONEncoder()

    /// JSON request body: `{"ids":[...]}` and, when set, `"value":Bool`.
    /// `value == nil` is omitted (synthesized `encodeIfPresent`).
    private struct IDsBody: Encodable {
        let ids: [String]
        let value: Bool?
    }

    private struct HashesBody: Encodable {
        let hashes: [String]
    }

    private struct EmptyBody: Encodable {}

    /// Send a JSON body; returns the raw response data. Accepts any 2xx.
    @discardableResult
    func sendRaw<B: Encodable>(_ method: String = "POST", _ path: String, body: B) async throws -> Data {
        guard let url = url(path) else { throw URLError(.badURL) }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        AtlasAuth.apply(to: &req)
        req.httpBody = try Self.mutationEncoder.encode(body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    /// Shared shape for the `{ids, value?}` mutations.
    private func mutate(_ path: String, ids: [String], value: Bool? = nil) async throws {
        try await sendRaw("POST", path, body: IDsBody(ids: ids, value: value))
    }

    // MARK: - Mutations (POST, {"ids":[...], "value"?:Bool})

    func favorite(_ ids: [String], _ value: Bool) async throws {
        try await mutate("/assets/favorite", ids: ids, value: value)
    }

    func archive(_ ids: [String], _ value: Bool) async throws {
        try await mutate("/assets/archive", ids: ids, value: value)
    }

    func trash(_ ids: [String]) async throws {
        try await mutate("/assets/trash", ids: ids)
    }

    func restore(_ ids: [String]) async throws {
        try await mutate("/assets/restore", ids: ids)
    }

    func lock(_ ids: [String], _ value: Bool) async throws {
        try await mutate("/assets/lock", ids: ids, value: value)
    }

    func deletePermanent(_ ids: [String]) async throws {
        try await mutate("/assets/delete", ids: ids)
    }

    func emptyTrash() async throws {
        try await sendRaw("POST", "/library/trash/empty", body: EmptyBody())
    }

    // MARK: - Special-album listings

    func listArchive() async throws -> [Asset] { try await collection("/library/archive") }
    func listTrash() async throws -> [Asset] { try await collection("/library/trash") }
    func listLocked() async throws -> [Asset] { try await collection("/library/locked") }

    // MARK: - Dedup probe (POST {"hashes":[...]} → {"have":[...]})

    /// Returns the subset of `hashes` already present on the server.
    func exists(hashes: [String]) async throws -> Set<String> {
        struct R: Codable { let have: [String] }
        let data = try await sendRaw("POST", "/assets/exists", body: HashesBody(hashes: hashes))
        return Set(try Self.decoder.decode(R.self, from: data).have)
    }

    // MARK: - Upload (PUT /v1/assets, the file as the body)

    /// Uploads one asset straight from its exported file: the body is streamed
    /// from disk, so a multi-gigabyte video costs no memory. `hash` is the
    /// SHA-256 the phone computed; the server hashes what it receives and
    /// refuses the upload if the two differ.
    func upload(file: URL, filename: String, takenAt: Date?, hash: String) async throws {
        guard let url = url("/assets") else { throw URLError(.badURL) }
        var req = URLRequest(url: url, timeoutInterval: 3600)
        req.httpMethod = "PUT"
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        AtlasAuth.apply(to: &req)
        // header values travel as latin-1: names with umlauts are percent-encoded
        let name = filename.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-._"))) ?? "upload"
        req.setValue(name, forHTTPHeaderField: "X-Filename")
        req.setValue(hash, forHTTPHeaderField: "X-Content-Hash")
        req.setValue("iphone", forHTTPHeaderField: "X-Source")
        if let takenAt {
            req.setValue(String(Int(takenAt.timeIntervalSince1970)), forHTTPHeaderField: "X-Taken-At")
        }
        let (_, resp) = try await URLSession.shared.upload(for: req, fromFile: file)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }
}
