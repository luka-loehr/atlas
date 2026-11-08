import SwiftUI

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
            // its own view: a sample (twice a second) updates only this section
            LiveSection(machine: machine)

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
        .inlineNavigationTitle()
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
    let series: [LiveSparkline.Point]
    let detail: String
    @State private var previous: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Spacer()
                // rolls in on Core Animation layers: `.numericText` redrew
                // the glyphs through a blur on every frame of every change
                RollingText("\(Int((value * 100).rounded())) %", rising: value >= previous, size: 20, weight: .semibold)
                    .onChange(of: value) { old, _ in previous = old }
            }
            // like the old dashboard: a 60 s window that slides every frame, the
            // newest value glides in instead of popping
            LiveSparkline(series: series, color: color)
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
        .inlineNavigationTitle()
    }
}

/// CPU, GPU and memory with their curves, then network and power: the only
/// part of the screen that reads the live samples.
private struct LiveSection: View {
    let machine: Machine

    var body: some View {
            // always laid out: placeholder values until the first sample, so
            // the section never pops in under the user's finger
        let latest = machine.latest ?? MetricSample(ts: 0, cpu: 0, mem: 0, mem_gb: 0, gpu: 0, gpu_mem_mb: 0, rx: 0, tx: 0)
        Section {
                    MetricRow(title: "CPU", value: latest.cpu / 100, color: .blue, series: machine.series(\.cpu),
                              detail: [machine.snapshot?.cpu.model, latest.cpu_temp.map { "\(Int($0)) °C" }].compactMap { $0 }.joined(separator: " · "))
                    if let gpu = machine.snapshot?.gpu ?? (machine.snapshot == nil ? SystemSnapshot.GPU(name: "GPU", mem_total_mb: 0) : nil) {
                        MetricRow(title: "GPU", value: latest.gpu / 100, color: .purple, series: machine.series(\.gpu),
                                  detail: [gpu.name, "\(Int(latest.gpu_mem_mb).formatted()) / \(Int(gpu.mem_total_mb).formatted()) MB",
                                           latest.gpu_temp.map { "\(Int($0)) °C" }].compactMap { $0 }.joined(separator: " · "))
                    }
                    MetricRow(title: "Memory", value: latest.mem / 100, color: .teal, series: machine.series(\.mem),
                              detail: String(format: "%.1f / %.0f GB", latest.mem_gb, machine.snapshot?.mem_total_gb ?? 0))
                    LabeledContent("Network") {
                        let rate = machine.throughput
                        RollingText("↓ \(Int64(rate.down).fileSize)/s  ↑ \(Int64(rate.up).fileSize)/s", size: 17, secondary: true)
                    }
                    LabeledContent("Power") {
                        RollingText(latest.system_w.map { "\(Int($0)) W" } ?? "–", size: 17, secondary: true)
                    }
                } header: {
                    Text("Live")
                }
                .redacted(reason: machine.latest == nil ? .placeholder : [])
    }
}
