import Foundation

// Payloads from the drive endpoints ("Dateien") of the Atlas server.

struct DriveCrumb: Codable, Sendable, Identifiable, Hashable {
    let id: Int
    let name: String
}

struct DriveFolder: Codable, Sendable, Identifiable, Hashable {
    let id: Int
    let name: String
    let items: Int
    let bytes: Int64

    // search results name folders without their totals
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        items = try c.decodeIfPresent(Int.self, forKey: .items) ?? 0
        bytes = try c.decodeIfPresent(Int64.self, forKey: .bytes) ?? 0
    }
}

struct DriveFile: Codable, Sendable, Identifiable, Hashable {
    let id: Int
    let name: String
    let hash: String
    let size: Int64
    let mime: String?
    let modifiedAt: Date?
    // only present in search results: the containing folder's name and, for
    // content hits, the match context inside the file
    var folder: String? = nil
    var snippet: String? = nil

    enum CodingKeys: String, CodingKey {
        case id, name, hash, size, mime, folder, snippet
        case modifiedAt = "modified_at"
    }
}

struct DriveListing: Codable, Sendable {
    var path: [DriveCrumb] = []
    var folders: [DriveFolder] = []
    var files: [DriveFile] = []

    init(path: [DriveCrumb] = [], folders: [DriveFolder] = [], files: [DriveFile] = []) {
        self.path = path
        self.folders = folders
        self.files = files
    }

    // search responses carry no `path`
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decodeIfPresent([DriveCrumb].self, forKey: .path) ?? []
        folders = try c.decodeIfPresent([DriveFolder].self, forKey: .folders) ?? []
        files = try c.decodeIfPresent([DriveFile].self, forKey: .files) ?? []
    }
}

/// Talks to the drive endpoints of the Atlas server (same host as the photos).
struct DriveClient: Sendable {
    /// Server base URL, e.g. "http://atlas.your-tailnet.ts.net:8787".
    var host: String

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private func url(_ path: String) -> URL? { URL(string: "\(host)/v1/drive\(path)") }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        guard let url = url(path) else { throw URLError(.badURL) }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        AtlasAuth.apply(to: &req)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try Self.decoder.decode(T.self, from: data)
    }

    /// Send a JSON body; nil values are dropped (the server treats absent as root/null).
    private func send(_ method: String, _ path: String, _ body: [String: Any?] = [:]) async throws {
        guard let url = url(path) else { throw URLError(.badURL) }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        AtlasAuth.apply(to: &req)
        let clean = body.compactMapValues { $0 }
        req.httpBody = try JSONSerialization.data(withJSONObject: clean)
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
    }

    // MARK: Reads

    func list(folder: Int?) async throws -> DriveListing {
        try await get("/folders/" + (folder.map(String.init) ?? "root"))
    }

    func search(_ q: String) async throws -> DriveListing {
        let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(.init(charactersIn: "&+="))) ?? q
        return try await get("/search?q=\(enc)")
    }

    func trash() async throws -> [DriveFile] {
        let r: DriveListing = try await get("/trash")
        return r.files
    }

    // MARK: Mutations

    func createFolder(parent: Int?, name: String) async throws {
        try await send("POST", "/folders", ["parent_id": parent, "name": name])
    }

    func renameFolder(_ id: Int, to name: String) async throws {
        try await send("PATCH", "/folders/\(id)", ["name": name])
    }

    /// PERMANENT: folder + whole subtree. The UI confirms with the item count.
    func deleteFolder(_ id: Int) async throws {
        try await send("DELETE", "/folders/\(id)")
    }

    func renameFile(_ id: Int, to name: String) async throws {
        try await send("PATCH", "/files/\(id)", ["name": name])
    }

    func move(files: [Int] = [], folders: [Int] = [], to folder: Int?) async throws {
        try await send("POST", "/move", ["files": files, "folders": folders, "to": folder])
    }

    func trashFiles(_ ids: [Int]) async throws { try await send("POST", "/trash", ["ids": ids]) }
    func restore(_ ids: [Int]) async throws { try await send("POST", "/restore", ["ids": ids]) }
    func deletePermanent(_ ids: [Int]) async throws { try await send("POST", "/delete", ["ids": ids]) }
    func emptyTrash() async throws { try await send("POST", "/trash/empty") }

    // MARK: Upload / download

    /// Raw-body upload from a local file (no RAM spike for big files). The
    /// server hashes the bytes itself; the name travels percent-encoded so
    /// umlauts survive the latin-1 header encoding.
    func upload(file: URL, name: String, folder: Int?) async throws {
        guard let url = url("/files") else { throw URLError(.badURL) }
        var req = URLRequest(url: url, timeoutInterval: 3600)
        req.httpMethod = "PUT"
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let enc = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-._"))) ?? name
        req.setValue(enc, forHTTPHeaderField: "X-Filename")
        if let folder { req.setValue("\(folder)", forHTTPHeaderField: "X-Folder-Id") }
        if let mtime = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
            req.setValue("\(Int(mtime.timeIntervalSince1970))", forHTTPHeaderField: "X-Modified-At")
        }
        AtlasAuth.apply(to: &req)
        let (_, resp) = try await URLSession.shared.upload(for: req, fromFile: file)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
    }

    // content-addressed, immutable — safe to cache forever; the name segment
    // gives the download a real filename + content type
    func blobURL(_ f: DriveFile) -> URL? {
        let n = f.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(.init(charactersIn: "/?#"))) ?? f.name
        return url("/blobs/\(f.hash)/\(n)")
    }

    /// Download into a per-hash temp dir named with the display name (QuickLook
    /// picks type + title from it). Cached by hash — a re-tap is instant.
    func download(_ f: DriveFile) async throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("drive-\(f.hash)", isDirectory: true)
        let dest = dir.appendingPathComponent(f.name)
        if FileManager.default.fileExists(atPath: dest.path) { return dest }
        guard let url = blobURL(f) else { throw URLError(.badURL) }
        let (tmp, resp) = try await URLSession.shared.download(for: AtlasAuth.request(url, timeoutInterval: 600))
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }
}
