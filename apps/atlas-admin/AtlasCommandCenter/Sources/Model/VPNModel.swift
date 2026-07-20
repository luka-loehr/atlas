import Foundation
import Observation

/// Mirrors /api/vpn — the exit-node picture in one payload.
struct VPNStatus: Codable, Sendable {
    let backend: String
    let version: String
    let exitNode: Bool
    let selfDns: String
    let since: Int          // unix ts the accumulation started
    let tunnelS: Int        // seconds with real tunnel traffic
    let bytes: Int64        // bytes moved through the tailnet since `since`
    let adguard: AdGuard
    let peers: [Peer]

    enum CodingKeys: String, CodingKey {
        case backend, version, since, adguard, peers, bytes
        case exitNode = "exit_node"
        case selfDns = "self_dns"
        case tunnelS = "tunnel_s"
    }

    struct AdGuard: Codable, Sendable {
        let ok: Bool
        let queries: Int?
        let blocked: Int?
        let avgMs: Double?
        enum CodingKeys: String, CodingKey {
            case ok, queries, blocked
            case avgMs = "avg_ms"
        }
        var blockedRatio: Double {
            guard let q = queries, let b = blocked, q > 0 else { return 0 }
            return Double(b) / Double(q)
        }
    }

    struct Peer: Codable, Sendable, Identifiable {
        let host: String
        let os: String
        let online: Bool
        let active: Bool
        let rx: Int64
        let tx: Int64
        let lastSeen: String
        var id: String { host }
        enum CodingKeys: String, CodingKey {
            case host, os, online, active, rx, tx
            case lastSeen = "last_seen"
        }
    }
}

@MainActor
@Observable
final class VPNModel {
    var status: VPNStatus?
    var error: String?
    var host = ""
    var token = ""

    private var loopTask: Task<Void, Never>?
    private var client: AtlasClient { AtlasClient(host: host, token: token.isEmpty ? nil : token) }

    func start() {
        stop()
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    func refresh() async {
        do {
            status = try await client.vpn()
            error = nil
        } catch {
            self.error = "atlas nicht erreichbar"
        }
    }
}

enum Fmt {
    /// "1,2 TB" / "834 GB" / "12 MB"
    static func bytes(_ b: Int64) -> String {
        b.formatted(.byteCount(style: .decimal, allowedUnits: [.mb, .gb, .tb], spellsOutZero: false))
    }

    /// "3,4 h" under ten hours, "127 h" after, "—" for nothing yet.
    static func hours(_ seconds: Int) -> String {
        let h = Double(seconds) / 3600
        if h <= 0 { return "0 h" }
        if h < 10 { return String(format: "%.1f h", h) }
        return "\(Int(h.rounded())) h"
    }
}
