import Foundation
import Observation
import Security

/// The app's connection to one Atlas server: where it is, the token, and
/// whether it currently answers.
@MainActor @Observable
final class Session {
    enum Reachability: Equatable { case unknown, online, offline, unauthorized }

    private(set) var config: ServerConfig?
    private(set) var reachability: Reachability = .unknown
    private(set) var info: ServerInfo?

    var api: API? { config.map(API.init) }
    var isConnected: Bool { config != nil }
    /// "http://atlas.example.ts.net:8787", the base the photo and drive
    /// clients build their URLs from.
    var base: String {
        guard let text = config?.url.absoluteString else { return "" }
        return text.hasSuffix("/") ? String(text.dropLast()) : text
    }

    struct ServerInfo: Decodable, Equatable {
        var name: String
        var version: String
        var hostname: String
        var timezone: String
    }

    init() {
        if let text = UserDefaults.standard.string(forKey: "server.url"), let url = URL(string: text),
           let token = Keychain.read("server.token") {
            config = ServerConfig(url: url, token: token)
            Keychain.pinToDevice("server.token")
        }
        #if targetEnvironment(simulator)
        // A simulator is connected from the command line instead of by typing:
        //   SIMCTL_CHILD_ATLAS_URL=... SIMCTL_CHILD_ATLAS_TOKEN=... xcrun simctl launch booted com.lukaloehr.atlas.ios
        let environment = ProcessInfo.processInfo.environment
        if config == nil, let address = environment["ATLAS_URL"], let url = Self.normalize(address), let token = environment["ATLAS_TOKEN"] {
            config = ServerConfig(url: url, token: token)
        }
        #endif
        AtlasAuth.token = config?.token ?? ""
    }

    /// Verify the server and the token, then remember both.
    func connect(to address: String, token: String) async throws {
        guard let url = Self.normalize(address) else { throw APIError.unreachable }
        let candidate = ServerConfig(url: url, token: token.trimmingCharacters(in: .whitespacesAndNewlines))
        let info: ServerInfo = try await API(config: candidate).get("server")
        guard info.name == "atlas" else { throw APIError.unreachable }
        UserDefaults.standard.set(url.absoluteString, forKey: "server.url")
        Keychain.write("server.token", candidate.token)
        AtlasAuth.token = candidate.token
        self.config = candidate
        self.info = info
        self.reachability = .online
    }

    func disconnect() {
        UserDefaults.standard.removeObject(forKey: "server.url")
        Keychain.delete("server.token")
        AtlasAuth.token = ""
        config = nil
        info = nil
        reachability = .unknown
    }

    /// Ask the server who it is; the answer is the app's idea of "online".
    func probe() async {
        guard let api else { return }
        do {
            info = try await api.get("server")
            reachability = .online
        } catch APIError.unauthorized {
            reachability = .unauthorized
        } catch is CancellationError {
        } catch {
            reachability = .offline
        }
    }

    /// A connect link, waiting for the owner to confirm it.
    struct ConnectLink: Identifiable, Equatable {
        let address: String
        let token: String
        var id: String { address }
        /// The server's host, what the confirmation names.
        var host: String { Session.normalize(address)?.host() ?? address }
    }

    /// atlas://connect?url=...&token=... — what `atlas connect` prints, so a
    /// phone is set up by opening one link. Any web page or QR code can open
    /// such a link, and the app would then back up the library to whatever
    /// server it names: it is only parsed here, and connects once the owner
    /// has confirmed the server (`connect(to:token:)`).
    static func connectLink(_ link: URL) -> ConnectLink? {
        guard link.scheme == "atlas", link.host() == "connect",
              let items = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems,
              let address = items.first(where: { $0.name == "url" })?.value,
              let token = items.first(where: { $0.name == "token" })?.value,
              normalize(address) != nil else { return nil }
        return ConnectLink(address: address, token: token)
    }

    /// "atlas.example.ts.net" -> http://atlas.example.ts.net:8787
    nonisolated static func normalize(_ address: String) -> URL? {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "http://" + text }
        guard var components = URLComponents(string: text), let host = components.host, !host.isEmpty else { return nil }
        if components.port == nil, components.scheme == "http" { components.port = 8787 }
        components.path = ""
        return components.url
    }
}

/// The access token lives in the keychain, not in preferences.
enum Keychain {
    private static func query(_ key: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: "com.lukaloehr.atlas.ios", kSecAttrAccount: key]
    }

    static func read(_ key: String) -> String? {
        var query = query(key)
        query[kSecReturnData] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ key: String, _ value: String) {
        delete(key)
        var query = query(key)
        query[kSecValueData] = Data(value.utf8)
        query[kSecAttrAccessible] = accessible
        SecItemAdd(query as CFDictionary, nil)
    }

    /// Readable in the background (uploads run after the first unlock), and
    /// never carried to another device by a backup or iCloud Keychain.
    private static let accessible = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

    /// Moves an item stored before `accessible` was this device only.
    static func pinToDevice(_ key: String) {
        SecItemUpdate(query(key) as CFDictionary, [kSecAttrAccessible: accessible] as CFDictionary)
    }

    static func delete(_ key: String) {
        SecItemDelete(query(key) as CFDictionary)
    }
}
