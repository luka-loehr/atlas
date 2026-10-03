import SwiftUI
import Charts
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
    private(set) var isLive = false

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
        var components = URLComponents(url: api.url("system/live"), resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(api.config.token)", forHTTPHeaderField: "Authorization")

        while !Task.isCancelled {
            let socket = API.session.webSocketTask(with: request)
            socket.resume()
            do {
                while !Task.isCancelled {
                    guard case .string(let text) = try await socket.receive(), let data = text.data(using: .utf8) else { continue }
                    if let history = try? JSONDecoder().decode(History.self, from: data) {
                        samples = history.history
                    } else if let sample = try? JSONDecoder().decode(MetricSample.self, from: data) {
                        samples.append(sample)
                        if samples.count > 1200 { samples.removeFirst(samples.count - 1200) }
                    }
                    isLive = true
                }
            } catch {
                isLive = false
            }
            socket.cancel(with: .goingAway, reason: nil)
            try? await Task.sleep(for: .seconds(3))
        }
        isLive = false
    }
}

struct ServerStatusScreen: View {
    private let roleNames = ["atlas-server": "API and Processing", "atlas-ml": "Search and Faces"]
    @Environment(Session.self) private var session
    @State private var machine = Machine.shared
    @State private var confirm: PowerAction?

    enum PowerAction: String, Identifiable {
        case restart, shutdown
        var id: String { rawValue }
    }

    var body: some View {
        Form {
            // always laid out: placeholder values until the first sample, so
            // the section never pops in under the user's finger
            let latest = machine.latest ?? MetricSample(ts: 0, cpu: 0, mem: 0, mem_gb: 0, gpu: 0, gpu_mem_mb: 0, rx: 0, tx: 0)
            Section {
                    MetricRow(title: "CPU", value: latest.cpu / 100, color: .blue, samples: machine.samples, keyPath: \.cpu,
                              detail: [machine.snapshot?.cpu.model, latest.cpu_temp.map { "\(Int($0)) °C" }].compactMap { $0 }.joined(separator: " · "))
                    if let gpu = machine.snapshot?.gpu ?? (machine.snapshot == nil ? SystemSnapshot.GPU(name: "GPU", mem_total_mb: 0) : nil) {
                        MetricRow(title: "GPU", value: latest.gpu / 100, color: .purple, samples: machine.samples, keyPath: \.gpu,
                                  detail: [gpu.name, "\(Int(latest.gpu_mem_mb).formatted()) / \(Int(gpu.mem_total_mb).formatted()) MB",
                                           latest.gpu_temp.map { "\(Int($0)) °C" }].compactMap { $0 }.joined(separator: " · "))
                    }
                    MetricRow(title: "Memory", value: latest.mem / 100, color: .teal, samples: machine.samples, keyPath: \.mem,
                              detail: String(format: "%.1f / %.0f GB", latest.mem_gb, machine.snapshot?.mem_total_gb ?? 0))
                    LabeledContent("Network") {
                        let rate = machine.throughput
                        Text("↓ \(Int64(rate.down).fileSize)/s  ↑ \(Int64(rate.up).fileSize)/s").monospacedDigit()
                    }
                    LabeledContent("Power") {
                        Text(latest.system_w.map { "\(Int($0)) W" } ?? "–").monospacedDigit()
                            .contentTransition(.numericText(value: latest.system_w ?? 0))
                    }
                } header: {
                    Text("Live")
                }
                .redacted(reason: machine.latest == nil ? .placeholder : [])

            if let snapshot = machine.snapshot {
                Section("Storage") {
                    ForEach(snapshot.disks) { disk in
                        VStack(alignment: .leading, spacing: 6) {
                            LabeledContent(disk.mount == "/" ? "System" : disk.mount,
                                           value: "\((disk.total - disk.used).fileSize) free of \(disk.total.fileSize)")
                            Gauge(value: disk.fraction) { EmptyView() }
                                .gaugeStyle(.linearCapacity)
                                .tint(disk.fraction > 0.9 ? .red : .accentColor)
                                .accessibilityLabel(disk.mount)
                                .accessibilityValue(Text(disk.fraction, format: .percent.precision(.fractionLength(0))))
                        }
                    }
                }
            }

            if let services = machine.services {
                Section("Services") {
                    ForEach(services.units) { unit in
                        LabeledContent {
                            StateLabel(healthy: unit.state == "active", text: unit.state == "active" ? "Active" : "Stopped")
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(unit.unit)
                                Text(roleNames[unit.unit] ?? unit.role).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                    LabeledContent("Database") {
                        Text("Postgres \(services.database.version.split(separator: " ").first.map(String.init) ?? "") · \(services.database.bytes.fileSize)")
                    }
                    LabeledContent("Search Model") {
                        if let model = services.ml {
                            StateLabel(healthy: true, text: model.embedder == "loaded" ? "Loaded" : "Ready")
                        } else {
                            StateLabel(healthy: false, text: "Offline")
                        }
                    }
                    NavigationLink {
                        QueueScreen(report: services)
                    } label: {
                        LabeledContent("Processing") {
                            Text(services.pending == 0 ? "Done" : "\(services.pending) pending").monospacedDigit()
                        }
                    }
                }
            }

            if let snapshot = machine.snapshot {
                Section("About") {
                    LabeledContent("Name", value: snapshot.hostname)
                    LabeledContent("Atlas", value: snapshot.version)
                    if let os = snapshot.os { LabeledContent("System", value: os) }
                    LabeledContent("Uptime", value: Duration.seconds(snapshot.uptime_s).formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated)))
                }
            }

            Section {
                Button("Restart Server", systemImage: "arrow.clockwise") { Task { await askPower(.restart) } }
                Button("Shut Down Server", systemImage: "power", role: .destructive) { Task { await askPower(.shutdown) } }
            }
            .confirmationDialog(confirm == .restart ? "Restart Server?" : "Shut Down Server?",
                                isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible) {
                if let action = confirm {
                    Button(action == .restart ? "Restart" : "Shut Down", role: .destructive) {
                        Task { try? await session.api?.send("POST", "system/power/\(action.rawValue)") }
                    }
                }
            }
        }
        .navigationTitle("Server")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if machine.snapshot == nil && machine.latest == nil && session.reachability == .offline {
                ServerUnavailableView()
            }
        }
        .task(id: session.config) {
            guard let api = session.api else { return }
            await machine.keepLive(api)
        }
        .refreshable {
            if let api = session.api { await machine.refresh(api) }
        }
    }
}

extension ServerStatusScreen {
    /// Power actions: Face ID first, then the confirmation.
    @MainActor func askPower(_ action: PowerAction) async {
        let reason = action == .restart ? "Restart atlas" : "Shut down atlas"
        guard await Biometric.authenticate(reason: reason) else { return }
        confirm = action
    }
}

/// Status as words and a symbol, never as color alone.
struct StateLabel: View {
    let healthy: Bool
    let text: String
    var body: some View {
        Label(text, systemImage: healthy ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .labelStyle(.titleAndIcon)
            .foregroundStyle(healthy ? .green : .orange)
            .font(.subheadline)
            .lineLimit(1)
    }
}

private struct MetricRow: View {
    let title: String
    let value: Double
    let color: Color
    let samples: [MetricSample]
    let keyPath: KeyPath<MetricSample, Double>
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Spacer()
                Text(value, format: .percent.precision(.fractionLength(0)))
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: value))
                    .animation(.smooth, value: value)
            }
            Chart(samples.suffix(300)) { sample in
                AreaMark(x: .value("Time", sample.date), y: .value("Load", sample[keyPath: keyPath]))
                    .foregroundStyle(color.opacity(0.16))
                LineMark(x: .value("Time", sample.date), y: .value("Load", sample[keyPath: keyPath]))
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            .chartYScale(domain: 0...100)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 48)
            if !detail.isEmpty {
                Text(detail).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(value, format: .percent.precision(.fractionLength(0))))
    }
}

/// What the ingest workers still have to do, and what went wrong.
private struct QueueScreen: View {
    let report: ServiceReport

    private static let names: [String: String] = [
        "thumb": "Thumbnails", "meta": "Metadata", "geocode": "Places", "embed": "Search Index",
        "faces": "Faces", "preview": "Video Streams", "drive_text": "File Text",
    ]

    var body: some View {
        List {
            Section {
                ForEach(report.queue.keys.sorted(), id: \.self) { kind in
                    let counts = report.queue[kind] ?? [:]
                    LabeledContent {
                        let waiting = (counts["pending"] ?? 0) + (counts["running"] ?? 0)
                        Text(waiting == 0 ? "Done" : "\(waiting) pending")
                            .monospacedDigit()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Self.names[kind] ?? kind)
                            Text("\(counts["done"] ?? 0) done").font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
            } footer: {
                Text("\(report.vectors) photos and videos are searchable by content.")
            }
            if !report.failed.isEmpty {
                Section("Failed") {
                    ForEach(report.failed) { job in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Self.names[job.kind] ?? job.kind)
                            Text(job.error ?? "").font(.footnote).foregroundStyle(.secondary).lineLimit(3)
                        }
                    }
                }
            }
        }
        .navigationTitle("Processing")
        .navigationBarTitleDisplayMode(.inline)
    }
}
