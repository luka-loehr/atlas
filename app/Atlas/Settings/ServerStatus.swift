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

struct ContainerList: Decodable {
    struct Container: Decodable, Identifiable {
        var name: String
        var image: String
        var state: String
        var status: String
        var id: String { name }
    }
    var containers: [Container]
}

/// Live machine metrics over the server's WebSocket: ten minutes of history
/// on connect, then one sample a second, for as long as a screen watches.
@MainActor @Observable
final class Machine {
    private(set) var samples: [MetricSample] = []
    private(set) var snapshot: SystemSnapshot?
    private(set) var services: ServiceReport?
    private(set) var containers: [ContainerList.Container] = []
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
        async let containers = try? api.get("system/containers", as: ContainerList.self)
        if let fresh = await snapshot { self.snapshot = fresh }
        if let fresh = await services { self.services = fresh }
        if let fresh = await containers { self.containers = fresh.containers }
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
                        if samples.count > 600 { samples.removeFirst(samples.count - 600) }
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
    private let roleNames = ["atlas-server": "API und Verarbeitung", "atlas-ml": "Suche und Gesichter"]
    @Environment(Session.self) private var session
    @State private var machine = Machine()
    @State private var confirm: PowerAction?

    enum PowerAction: String, Identifiable {
        case restart, shutdown
        var id: String { rawValue }
    }

    var body: some View {
        Form {
            if let latest = machine.latest {
                Section {
                    MetricRow(title: "CPU", value: latest.cpu / 100, color: .blue, samples: machine.samples, keyPath: \.cpu,
                              detail: [machine.snapshot?.cpu.model, latest.cpu_temp.map { "\(Int($0)) °C" }].compactMap { $0 }.joined(separator: " · "))
                    if let gpu = machine.snapshot?.gpu {
                        MetricRow(title: "GPU", value: latest.gpu / 100, color: .purple, samples: machine.samples, keyPath: \.gpu,
                                  detail: [gpu.name, "\(Int(latest.gpu_mem_mb).formatted()) / \(Int(gpu.mem_total_mb).formatted()) MB",
                                           latest.gpu_temp.map { "\(Int($0)) °C" }].compactMap { $0 }.joined(separator: " · "))
                    }
                    MetricRow(title: "Arbeitsspeicher", value: latest.mem / 100, color: .teal, samples: machine.samples, keyPath: \.mem,
                              detail: String(format: "%.1f / %.0f GB", latest.mem_gb, machine.snapshot?.mem_total_gb ?? 0))
                    LabeledContent("Netzwerk") {
                        let rate = machine.throughput
                        Text("↓ \(Int64(rate.down).fileSize)/s  ↑ \(Int64(rate.up).fileSize)/s").monospacedDigit()
                    }
                    if let watts = latest.system_w {
                        LabeledContent("Leistung") {
                            Text("\(Int(watts)) W").monospacedDigit().contentTransition(.numericText(value: watts))
                        }
                    }
                } header: {
                    Text("Live")
                }
            }

            if let snapshot = machine.snapshot {
                Section("Speicher") {
                    ForEach(snapshot.disks) { disk in
                        VStack(alignment: .leading, spacing: 6) {
                            LabeledContent(disk.mount == "/" ? "System" : disk.mount,
                                           value: "\((disk.total - disk.used).fileSize) frei von \(disk.total.fileSize)")
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
                Section("Dienste") {
                    ForEach(services.units) { unit in
                        LabeledContent {
                            StateLabel(healthy: unit.state == "active", text: unit.state == "active" ? "Aktiv" : "Gestoppt")
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(unit.unit)
                                Text(roleNames[unit.unit] ?? unit.role).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                    LabeledContent("Datenbank") {
                        Text("Postgres \(services.database.version.split(separator: " ").first.map(String.init) ?? "") · \(services.database.bytes.fileSize)")
                    }
                    LabeledContent("Suchmodell") {
                        if let model = services.ml {
                            StateLabel(healthy: true, text: model.embedder == "loaded" ? "Geladen" : "Bereit")
                        } else {
                            StateLabel(healthy: false, text: "Offline")
                        }
                    }
                    NavigationLink {
                        QueueScreen(report: services)
                    } label: {
                        LabeledContent("Verarbeitung") {
                            Text(services.pending == 0 ? "Fertig" : "\(services.pending) offen").monospacedDigit()
                        }
                    }
                }
            }

            if !machine.containers.isEmpty {
                Section("Container") {
                    ForEach(machine.containers) { container in
                        LabeledContent {
                            StateLabel(healthy: container.state == "running", text: container.status)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(container.name)
                                Text(container.image).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
            }

            if let snapshot = machine.snapshot {
                Section("Über") {
                    LabeledContent("Name", value: snapshot.hostname)
                    LabeledContent("Atlas", value: snapshot.version)
                    if let os = snapshot.os { LabeledContent("System", value: os) }
                    LabeledContent("Laufzeit", value: Duration.seconds(snapshot.uptime_s).formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated)))
                }
            }

            Section {
                Button("Server neu starten", systemImage: "arrow.clockwise") { confirm = .restart }
                Button("Server ausschalten", systemImage: "power", role: .destructive) { confirm = .shutdown }
            }
            .confirmationDialog(confirm == .restart ? "Server neu starten?" : "Server ausschalten?",
                                isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible) {
                if let action = confirm {
                    Button(action == .restart ? "Neu starten" : "Ausschalten", role: .destructive) {
                        Task { try? await session.api?.send("POST", "system/power/\(action.rawValue)") }
                    }
                }
            }
        }
        .navigationTitle("Server")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if machine.snapshot == nil && machine.latest == nil {
                if session.reachability == .offline {
                    ServerUnavailableView()
                } else {
                    ProgressView()
                }
            }
        }
        .task(id: session.config) {
            guard let api = session.api else { return }
            await machine.refresh(api)
            await machine.watch(api)
        }
        .refreshable {
            if let api = session.api { await machine.refresh(api) }
        }
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
        "thumb": "Vorschaubilder", "meta": "Metadaten", "geocode": "Orte", "embed": "Suchindex",
        "faces": "Gesichter", "preview": "Video-Streams", "drive_text": "Dateitext",
    ]

    var body: some View {
        List {
            Section {
                ForEach(report.queue.keys.sorted(), id: \.self) { kind in
                    let counts = report.queue[kind] ?? [:]
                    LabeledContent {
                        let waiting = (counts["pending"] ?? 0) + (counts["running"] ?? 0)
                        Text(waiting == 0 ? "Fertig" : "\(waiting) offen")
                            .monospacedDigit()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Self.names[kind] ?? kind)
                            Text("\(counts["done"] ?? 0) erledigt").font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
            } footer: {
                Text("\(report.vectors) Fotos und Videos sind nach Inhalt durchsuchbar.")
            }
            if !report.failed.isEmpty {
                Section("Fehlgeschlagen") {
                    ForEach(report.failed) { job in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Self.names[job.kind] ?? job.kind)
                            Text(job.error ?? "").font(.footnote).foregroundStyle(.secondary).lineLimit(3)
                        }
                    }
                }
            }
        }
        .navigationTitle("Verarbeitung")
        .navigationBarTitleDisplayMode(.inline)
    }
}
