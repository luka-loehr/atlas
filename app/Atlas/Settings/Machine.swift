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
    struct Model: Decodable { var embedder: String; var faces: Bool }
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
        if let fresh = await snapshot { self.snapshot = fresh }
        if let fresh = await services { self.services = fresh }
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
