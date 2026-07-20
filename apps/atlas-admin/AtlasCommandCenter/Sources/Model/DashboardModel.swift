import Foundation
import Observation

@MainActor
@Observable
final class DashboardModel {
    var metrics: Metrics?
    var online = false
    var lastError: String?
    var updatedAt: Date?

    // rolling history for the sparkline (usage %, newest last)
    var cpuHistory: [Double] = []
    var gpuHistory: [Double] = []

    // network rates in Mbit/s, derived from the agent's cumulative counters
    var netDownHistory: [Double] = []
    var netUpHistory: [Double] = []
    var netDownMbps: Double = 0
    var netUpMbps: Double = 0
    var memSamples: [(Date, Double)] = []
    var memGbLive: Double = 0

    // smoothed live values for the hero rings (fallback: polled metrics)
    var cpuLive: Double? { wsConnected ? cpuSamples.last?.1 : nil }
    var gpuLive: Double? { wsConnected ? gpuSamples.last?.1 : nil }
    var memLive: Double? { wsConnected ? memSamples.last?.1 : nil }
    private var lastNet: (rx: UInt64, tx: UInt64, at: Date)?

    // Time-stamped live samples for the charts: fed every 500 ms by the
    // /ws/metrics push stream, or every 2 s by the HTTP fallback while the
    // socket is down. The charts render a sliding 60 s window, so keep ~75 s.
    var cpuSamples: [(Date, Double)] = []
    var gpuSamples: [(Date, Double)] = []
    var downSamples: [(Date, Double)] = []
    var upSamples: [(Date, Double)] = []
    var wsConnected = false

    var host: String = "atlas.your-tailnet.ts.net:8787"
    var token: String = ""

    private var loopTask: Task<Void, Never>?
    private var wsTask: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private var lastWSNet: (rx: UInt64, tx: UInt64, tsMs: UInt64)?
    private let maxHistory = 60
    private let sampleWindow: TimeInterval = 75

    func start() {
        stop()
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        wsTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.runSocket()
                if Task.isCancelled { return }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
        wsTask?.cancel()
        wsTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        wsConnected = false
        lastWSNet = nil
    }

    func refresh() async {
        let client = AtlasClient(host: host, token: token.isEmpty ? nil : token)
        do {
            let m = try await client.fetch()
            metrics = m
            online = true
            lastError = nil
            updatedAt = Date()
            if !wsConnected {
                push(&cpuHistory, m.cpu.usage)
                push(&gpuHistory, m.gpu?.usage ?? 0)
                let now = Date()
                appendSample(&cpuSamples, now, m.cpu.usage)
                appendSample(&gpuSamples, now, m.gpu?.usage ?? 0)
            }
            if let net = m.net {
                let now = Date()
                if !wsConnected, let last = lastNet, net.rxBytes >= last.rx, net.txBytes >= last.tx {
                    let dt = now.timeIntervalSince(last.at)
                    if dt > 0.2 {
                        netDownMbps = Double(net.rxBytes - last.rx) * 8 / dt / 1_000_000
                        netUpMbps = Double(net.txBytes - last.tx) * 8 / dt / 1_000_000
                        push(&netDownHistory, netDownMbps)
                        push(&netUpHistory, netUpMbps)
                        appendSample(&downSamples, now, netDownMbps)
                        appendSample(&upSamples, now, netUpMbps)
                    }
                }
                lastNet = (net.rxBytes, net.txBytes, now)
            }
        } catch {
            online = false
            lastError = friendly(error)
        }
    }

    func sendPower(_ action: String) async {
        let client = AtlasClient(host: host, token: token.isEmpty ? nil : token)
        try? await client.power(action)
    }

    // MARK: live metrics stream (/ws/metrics)

    /// One JSON text frame every 500 ms, see the agent's wire format.
    private struct WSFrame: Decodable {
        let tsMs: UInt64
        let cpu: Double
        let mem: Double
        let memGb: Double
        let gpu: Double
        let gpuMemMb: Double
        let rx: UInt64
        let tx: UInt64
        enum CodingKeys: String, CodingKey {
            case cpu, mem, gpu, rx, tx
            case tsMs = "ts_ms"
            case memGb = "mem_gb"
            case gpuMemMb = "gpu_mem_mb"
        }
    }

    /// Connects, pumps frames into the sample buffers, returns when the
    /// socket dies. The outer task reconnects with a 2 s backoff.
    private func runSocket() async {
        guard let url = metricsSocketURL() else { return }
        var request = URLRequest(url: url, timeoutInterval: 8)
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let task = URLSession.shared.webSocketTask(with: request)
        socket = task
        task.resume()
        defer {
            task.cancel(with: .goingAway, reason: nil)
            if socket === task { socket = nil }
            wsConnected = false
            lastWSNet = nil
        }
        while !Task.isCancelled {
            guard let message = try? await task.receive() else { break }
            handle(message)
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data?
        switch message {
        case .string(let text): data = text.data(using: .utf8)
        case .data(let raw): data = raw
        @unknown default: data = nil
        }
        guard let data else { return }
        if let boot = try? JSONDecoder().decode(WSBootstrap.self, from: data) {
            seed(boot.history)
            return
        }
        guard let frame = try? JSONDecoder().decode(WSFrame.self, from: data) else { return }
        apply(frame)
    }

    private func apply(_ f: WSFrame) {
        wsConnected = true
        let now = Date()
        appendSample(&cpuSamples, now, f.cpu)
        appendSample(&gpuSamples, now, f.gpu)
        appendSample(&memSamples, now, f.mem)
        memGbLive = f.memGb
        if let last = lastWSNet {
            // cumulative counters: a smaller value means the agent restarted — skip that delta
            if f.rx >= last.rx, f.tx >= last.tx, f.tsMs > last.tsMs {
                let dt = Double(f.tsMs - last.tsMs) / 1000
                if dt > 0.05 {
                    appendSample(&downSamples, now, Double(f.rx - last.rx) * 8 / dt / 1_000_000)
                    appendSample(&upSamples, now, Double(f.tx - last.tx) * 8 / dt / 1_000_000)
                    // labels read the SMOOTHED series — calm numbers, no flicker
                    netDownMbps = downSamples.last?.1 ?? 0
                    netUpMbps = upSamples.last?.1 ?? 0
                }
            }
        }
        lastWSNet = (f.rx, f.tx, f.tsMs)
    }

    private struct WSBootstrap: Decodable { let history: [WSFrame] }

    /// Seeds the buffers from the agent's 10-minute ring buffer so charts are
    /// filled the moment the screen opens. Server timestamps are mapped onto
    /// the client clock via the newest frame; EMA runs over the seed exactly
    /// like over live data.
    private func seed(_ frames: [WSFrame]) {
        guard let latest = frames.last else { return }
        wsConnected = true
        cpuSamples = []; gpuSamples = []; memSamples = []
        downSamples = []; upSamples = []
        let now = Date()
        var prevNet: (rx: UInt64, tx: UInt64, tsMs: UInt64)?
        for f in frames {
            let t = now.addingTimeInterval(-Double(latest.tsMs - f.tsMs) / 1000)
            appendSample(&cpuSamples, t, f.cpu)
            appendSample(&gpuSamples, t, f.gpu)
            appendSample(&memSamples, t, f.mem)
            if let p = prevNet, f.rx >= p.rx, f.tx >= p.tx, f.tsMs > p.tsMs {
                let dt = Double(f.tsMs - p.tsMs) / 1000
                appendSample(&downSamples, t, Double(f.rx - p.rx) * 8 / dt / 1_000_000)
                appendSample(&upSamples, t, Double(f.tx - p.tx) * 8 / dt / 1_000_000)
            }
            prevNet = (f.rx, f.tx, f.tsMs)
        }
        memGbLive = latest.memGb
        netDownMbps = downSamples.last?.1 ?? 0
        netUpMbps = upSamples.last?.1 ?? 0
        lastWSNet = (latest.rx, latest.tx, latest.tsMs)
    }

    private func metricsSocketURL() -> URL? {
        var s = "ws://\(host)/ws/metrics"
        if !token.isEmpty { s += "?token=\(token)" }
        return URL(string: s)
    }

    /// Appends with exponential smoothing (EMA): raw 500ms samples of cpu/gpu
    /// swing violently (0↔100 between ticks) and render as seismograph noise —
    /// the smoothed series flows in gentle waves instead. α=0.30 ≈ the feel of
    /// Apple's activity charts; header rate labels calm down for free.
    private func appendSample(_ arr: inout [(Date, Double)], _ t: Date, _ v: Double) {
        let smoothed: Double
        if let last = arr.last {
            smoothed = last.1 + 0.30 * (v - last.1)
        } else {
            smoothed = v
        }
        arr.append((t, smoothed))
        let cutoff = t.addingTimeInterval(-sampleWindow)
        while let first = arr.first, first.0 < cutoff { arr.removeFirst() }
    }

    private func push(_ arr: inout [Double], _ v: Double) {
        arr.append(v)
        if arr.count > maxHistory { arr.removeFirst(arr.count - maxHistory) }
    }

    private func friendly(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .cannotConnectToHost, .cannotFindHost, .networkConnectionLost:
                return "atlas nicht erreichbar – schläft er?"
            default: return urlError.localizedDescription
            }
        }
        return error.localizedDescription
    }
}
