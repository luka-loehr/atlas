import Foundation
import Observation

/// One reading of the machine, as the server streams them.
struct MetricSample: Decodable, Identifiable {
    var ts: Double
    var cpu: Double
    var mem: Double
    var mem_gb: Double
    var gpu: Double
    var gpu_mem_mb: Double
    var rx: Double
    var tx: Double
    var cpu_temp: Double?
    var gpu_temp: Double?
    var cpu_w: Double?
    var gpu_w: Double?
    var system_w: Double?

    var id: Double { ts }
    var date: Date { Date(timeIntervalSince1970: ts / 1000) }
}

struct SystemSnapshot: Decodable {
    struct CPU: Decodable { var model: String?; var cores: Int }
    struct GPU: Decodable { var name: String; var mem_total_mb: Double }
    struct Disk: Decodable, Identifiable {
        var mount: String
        var used: Int64
        var total: Int64
        var id: String { mount }
        var fraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
    }
    var hostname: String
    var version: String
    var os: String?
    var kernel: String?
    var uptime_s: Int
    var load: [Double]
    var cpu: CPU
    var mem_total_gb: Double
    var gpu: GPU?
    var disks: [Disk]
}

struct ServiceReport: Decodable {
    struct Unit: Decodable, Identifiable {
        var unit: String
        var role: String
        var state: String
        var memory: Int64?
        var id: String { unit }
    }
    struct Database: Decodable { var version: String; var bytes: Int64 }
    /// The model worker. `vision` replaced `faces` on the server; neither is
    /// required, so a renamed field never again fails the whole report.
    struct Model: Decodable { var embedder: String; var vision: Bool?; var faces: Bool? }
    struct Failed: Decodable, Identifiable {
        var kind: String
        var owner: String
        var error: String?
        var id: String { kind + owner }
    }
    var units: [Unit]
    var database: Database
    var ml: Model?
    var vectors: Int
    var queue: [String: [String: Int]]
    var failed: [Failed]

    var pending: Int { queue.values.reduce(0) { $0 + ($1["pending"] ?? 0) + ($1["running"] ?? 0) } }
}

/// The drives inside the server, with SMART health (`/system/drives`).
struct DriveReport: Decodable {
    struct Drive: Decodable, Identifiable {
        struct Mount: Decodable, Identifiable {
            var mount: String
            var size: Int64
            var used: Int64
            var id: String { mount }
            var fraction: Double { size > 0 ? Double(used) / Double(size) : 0 }
        }
        struct Health: Decodable {
            var asleep: Bool?
            var passed: Bool?
            var temperature: Int?
            var hours: Int?
            var rpm: Int?
            var wear: Int?
            var spare: Int?
            var written: Int64?
            var media_errors: Int?
            var reallocated: Int?
            var pending: Int?
            var uncorrectable: Int?
            /// Sectors or media errors the drive reports.
            var problems: Int { (reallocated ?? 0) + (pending ?? 0) + (uncorrectable ?? 0) + (media_errors ?? 0) }
        }
        var name: String
        var model: String?
        var kind: String
        var transport: String?
        var size: Int64
        var mounts: [Mount]
        var health: Health?
        var id: String { name }
        var isSSD: Bool { kind == "ssd" }
    }
    var drives: [Drive]
}

/// Live machine metrics over the server's WebSocket: ten minutes of history
/// on connect, then two samples a second. One shared instance: Settings
/// starts it when it opens, so the server screen is already filled when it
/// is pushed, and nothing jumps in.
@MainActor @Observable
final class Machine {
    static let shared = Machine()
    @ObservationIgnored private var watcher: Task<Void, Never>?
    @ObservationIgnored private var watchers = 0

    /// Keep the stream (and the snapshot) live while the caller's task runs.
    func keepLive(_ api: API) async {
        watchers += 1
        if watcher == nil {
            watcher = Task { [weak self] in
                guard let self else { return }
                await self.refresh(api)
                await self.watch(api)
            }
        }
        // wait until the caller goes away
        while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
        watchers -= 1
        if watchers == 0 {
            watcher?.cancel()
            watcher = nil
        }
    }

    private(set) var samples: [MetricSample] = []
    private(set) var snapshot: SystemSnapshot?
    private(set) var services: ServiceReport?
    private(set) var drives: DriveReport?
    @ObservationIgnored private let decoder = JSONDecoder()

    var latest: MetricSample? { samples.last }

    /// Bytes per second over the last few samples.
    var throughput: (down: Double, up: Double) {
        guard samples.count >= 2 else { return (0, 0) }
        let a = samples[max(samples.count - 4, 0)], b = samples[samples.count - 1]
        let seconds = max((b.ts - a.ts) / 1000, 0.5)
        return (max(b.rx - a.rx, 0) / seconds, max(b.tx - a.tx, 0) / seconds)
    }

    func refresh(_ api: API) async {
        async let snapshot = try? api.get("system", as: SystemSnapshot.self)
        async let services = try? api.get("system/services", as: ServiceReport.self)
        async let drives = try? api.get("system/drives", as: DriveReport.self)
        if let fresh = await snapshot { self.snapshot = fresh }
        if let fresh = await services { self.services = fresh }
        if let fresh = await drives { self.drives = fresh }
    }

    /// Runs until the calling task is cancelled; reconnects on drops.
    func watch(_ api: API) async {
        struct History: Decodable { var history: [MetricSample] }
        let request = api.webSocketRequest("system/live")

        while !Task.isCancelled {
            let socket = API.session.webSocketTask(with: request)
            socket.resume()
            do {
                while !Task.isCancelled {
                    guard case .string(let text) = try await socket.receive(), let data = text.data(using: .utf8) else { continue }
                    if let history = try? decoder.decode(History.self, from: data) {
                        samples = history.history
                    } else if let sample = try? decoder.decode(MetricSample.self, from: data) {
                        samples.append(sample)
                        if samples.count > 1200 { samples.removeFirst(samples.count - 1200) }
                    }
                }
            } catch {}
            socket.cancel(with: .goingAway, reason: nil)
            try? await Task.sleep(for: .seconds(3))
        }
    }
}
