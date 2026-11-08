import SwiftUI
import AppKit

/// The server, all on one page made for a wide window: who it is and
/// whether it answers, its live load, its disks next to what Atlas keeps on
/// this Mac, its services and what is still processing, and the connection.
/// Restart, shut down and the terminal sit in the toolbar. There is no
/// separate Settings window: this page is it (⌘,).
struct MacServerView: View {
    @Environment(Session.self) private var session
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var machine = Machine.shared
    @State private var storage = StorageUse()
    @State private var measured = false
    @State private var power: Power?
    @State private var confirmDisconnect = false

    enum Power: String, Identifiable {
        case restart, shutdown
        var id: String { rawValue }
    }

    private static let roles = ["atlas-server": "API and Processing", "atlas-ml": "Search, Faces, Pets and Text"]
    private static let queueNames: [String: String] = [
        "thumb": "Thumbnails", "meta": "Metadata", "geocode": "Places", "embed": "Search Index",
        "faces": "Faces, Pets and Text", "preview": "Video Streams", "drive_text": "File Text",
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header
                    if session.isConnected {
                        live
                        storageRow
                        servicesRow
                    }
                    connection
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
                .frame(maxWidth: 1180, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Server")
            .toolbar { toolbar }
        }
        .task(id: session.config) {
            guard let api = session.api else { return }
            await machine.keepLive(api)
        }
        // services, the queue and the disks change while the page is open
        .task(id: session.config) {
            guard let api = session.api else { return }
            while !Task.isCancelled {
                await machine.refresh(api)
                await session.probe()
                try? await Task.sleep(for: .seconds(10))
            }
        }
        .task {
            storage = await StorageUse.measure()
            measured = true
        }
        .confirmationDialog(power == .restart ? "Restart atlas?" : "Shut Down atlas?",
                            isPresented: Binding(get: { power != nil }, set: { if !$0 { power = nil } }),
                            titleVisibility: .visible, presenting: power) { action in
            Button(action == .restart ? "Restart" : "Shut Down", role: .destructive) {
                Task { try? await session.api?.send("POST", "system/power/\(action.rawValue)") }
            }
        } message: { action in
            Text(action == .restart ? "Photos and files are unavailable until it is back, about a minute."
                 : "atlas stays off until it is woken (atlas boot).")
        }
        .confirmationDialog("Disconnect from \(session.info?.hostname ?? "atlas")?", isPresented: $confirmDisconnect) {
            Button("Disconnect", role: .destructive) { session.disconnect() }
        } message: {
            Text("Atlas forgets the server and its token, and removes the timeline it keeps on this Mac. Your photos stay on the server.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: "server.rack")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(.tint)
                .frame(width: 56, height: 56)
                .background(.tint.opacity(0.12), in: .rect(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 3) {
                Text(machine.snapshot?.hostname ?? session.info?.hostname ?? "atlas")
                    .font(.system(size: 26, weight: .bold))
                Text(about)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            StateLabel(healthy: online, text: statusText)
                .font(.headline)
        }
    }

    private var online: Bool { session.reachability != .offline && session.reachability != .unauthorized }

    private var statusText: String {
        switch session.reachability {
        case .online: "Online"
        case .offline: "Offline"
        case .unauthorized: "Token Rejected"
        case .unknown: model.library.online ? "Online" : "Connecting…"
        }
    }

    private var about: String {
        guard let s = machine.snapshot else { return session.base }
        let uptime = Duration.seconds(s.uptime_s).formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated))
        return ["Atlas \(s.version)", s.os, "up \(uptime)"].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: - Live

    private var live: some View {
        let latest = machine.latest ?? MetricSample(ts: 0, cpu: 0, mem: 0, mem_gb: 0, gpu: 0, gpu_mem_mb: 0, rx: 0, tx: 0)
        let snapshot = machine.snapshot
        return Section {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14)], spacing: 14) {
                LiveCard(title: "CPU", value: latest.cpu / 100, color: .blue, series: machine.series(\.cpu),
                         detail: [snapshot?.cpu.model, snapshot.map { "\($0.cpu.cores) cores" },
                                  latest.cpu_temp.map { "\(Int($0)) °C" }].compactMap { $0 }.joined(separator: " · "))
                if snapshot == nil || snapshot?.gpu != nil {
                    LiveCard(title: "GPU", value: latest.gpu / 100, color: .purple, series: machine.series(\.gpu),
                             detail: [snapshot?.gpu?.name,
                                      snapshot?.gpu.map { "\(Int(latest.gpu_mem_mb / 1024)) / \(Int($0.mem_total_mb / 1024)) GB" },
                                      latest.gpu_temp.map { "\(Int($0)) °C" }].compactMap { $0 }.joined(separator: " · "))
                }
                LiveCard(title: "Memory", value: latest.mem / 100, color: .teal, series: machine.series(\.mem),
                         detail: String(format: "%.1f of %.0f GB", latest.mem_gb, snapshot?.mem_total_gb ?? 0))
                FactCard(title: "Network", symbol: "arrow.up.arrow.down") {
                    let rate = machine.throughput
                    VStack(alignment: .leading, spacing: 4) {
                        Text("↓ \(Int64(rate.down).fileSize)/s").font(.title2.weight(.semibold))
                        Text("↑ \(Int64(rate.up).fileSize)/s").font(.title3).foregroundStyle(.secondary)
                    }
                    .monospacedDigit()
                }
                FactCard(title: "Power", symbol: "bolt.fill") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(latest.system_w.map { "\(Int($0)) W" } ?? "–").font(.title2.weight(.semibold))
                        Text([latest.cpu_w.map { "CPU \(Int($0)) W" }, latest.gpu_w.map { "GPU \(Int($0)) W" }]
                                .compactMap { $0 }.joined(separator: " · "))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .monospacedDigit()
                }
                if let load = snapshot?.load, load.count == 3 {
                    FactCard(title: "Load", symbol: "gauge.with.dots.needle.33percent") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(String(format: "%.2f", load[0])).font(.title2.weight(.semibold))
                            Text(String(format: "5 min %.2f · 15 min %.2f", load[1], load[2]))
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        .monospacedDigit()
                    }
                }
            }
            .redacted(reason: machine.latest == nil ? .placeholder : [])
        } header: {
            SectionTitle("Live")
        }
    }

    // MARK: - Storage

    private var storageRow: some View {
        Section {
            HStack(alignment: .top, spacing: 14) {
                Card {
                    VStack(alignment: .leading, spacing: 14) {
                        Label("On atlas", systemImage: "internaldrive").font(.headline)
                        if let disks = machine.snapshot?.disks {
                            ForEach(disks) { disk in
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text(disk.mount == "/" ? "System" : disk.mount)
                                        Spacer()
                                        Text("\((disk.total - disk.used).fileSize) free of \(disk.total.fileSize)")
                                            .foregroundStyle(.secondary).monospacedDigit()
                                    }
                                    Gauge(value: disk.fraction) { EmptyView() }
                                        .gaugeStyle(.linearCapacity)
                                        .tint(disk.fraction > 0.9 ? .red : .accentColor)
                                        .accessibilityLabel(disk.mount)
                                        .accessibilityValue(Text(disk.fraction, format: .percent.precision(.fractionLength(0))))
                                }
                            }
                            if let db = machine.services?.database {
                                HStack {
                                    Text("Database")
                                    Spacer()
                                    Text(db.bytes.fileSize).foregroundStyle(.secondary).monospacedDigit()
                                }
                            }
                        } else {
                            ProgressView().frame(maxWidth: .infinity)
                        }
                    }
                }
                Card {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Label("On this Mac", systemImage: "laptopcomputer").font(.headline)
                            Spacer()
                            Button("Show in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([MediaStore.shared.directory])
                            }
                            .controlSize(.small)
                        }
                        StorageBar(use: storage)
                            .redacted(reason: measured ? [] : .placeholder)
                        Text("Every grid thumbnail stays on this Mac, so the library opens complete, also offline. Previews, originals and videos share \(MediaStore.budget.fileSize) and make room on their own, least used first.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        } header: {
            SectionTitle("Storage")
        }
    }

    // MARK: - Services and processing

    private var servicesRow: some View {
        Section {
            HStack(alignment: .top, spacing: 14) {
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Services", systemImage: "gearshape.2").font(.headline)
                        if let services = machine.services {
                            ForEach(services.units) { unit in
                                HStack {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(unit.unit)
                                        Text(Self.roles[unit.unit] ?? unit.role).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if let memory = unit.memory {
                                        Text(memory.fileSize).foregroundStyle(.secondary).monospacedDigit()
                                    }
                                    StateLabel(healthy: unit.state == "active", text: unit.state == "active" ? "Active" : "Stopped")
                                }
                            }
                            Divider()
                            row("Database", "Postgres \(services.database.version.split(separator: " ").first.map(String.init) ?? "")")
                            HStack {
                                Text("Search Model")
                                Spacer()
                                if let ml = services.ml {
                                    StateLabel(healthy: true, text: ml.embedder == "loaded" ? "Loaded" : "Ready")
                                } else {
                                    StateLabel(healthy: false, text: "Offline")
                                }
                            }
                            row("Searchable by content", services.vectors.formatted())
                        } else {
                            ProgressView().frame(maxWidth: .infinity)
                        }
                    }
                }
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label("Processing", systemImage: "arrow.triangle.2.circlepath").font(.headline)
                            Spacer()
                            if let services = machine.services {
                                Text(services.pending == 0 ? "All done" : "\(services.pending.formatted()) waiting")
                                    .foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                        if let services = machine.services {
                            ForEach(services.queue.keys.sorted(), id: \.self) { kind in
                                let counts = services.queue[kind] ?? [:]
                                let waiting = (counts["pending"] ?? 0) + (counts["running"] ?? 0)
                                HStack {
                                    Text(Self.queueNames[kind] ?? kind)
                                    Spacer()
                                    Text("\((counts["done"] ?? 0).formatted()) done").foregroundStyle(.secondary)
                                    Text(waiting == 0 ? "✓" : "\(waiting.formatted()) waiting")
                                        .foregroundStyle(waiting == 0 ? .green : .orange)
                                        .frame(minWidth: 90, alignment: .trailing)
                                }
                                .monospacedDigit()
                            }
                            if !services.failed.isEmpty {
                                Divider()
                                Text("Failed").font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
                                ForEach(services.failed) { job in
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(Self.queueNames[job.kind] ?? job.kind)
                                        Text(job.error ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                }
                            }
                        } else {
                            ProgressView().frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        } header: {
            SectionTitle("Services")
        }
    }

    // MARK: - Connection

    private var connection: some View {
        Section {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    if session.isConnected {
                        row("Address", session.base)
                        if let info = session.info {
                            row("Version", info.version)
                            row("Time Zone", info.timezone)
                        }
                        row("Library", model.library.assets.count == 1 ? "1 item" : "\(model.library.assets.count.formatted()) items")
                        Divider()
                        HStack {
                            Text("The access token is kept in your keychain on this Mac.")
                                .font(.callout).foregroundStyle(.secondary)
                            Spacer()
                            Button("Disconnect…") { confirmDisconnect = true }
                        }
                    } else {
                        Text("Not connected. Connect in the main window, or open the link “atlas connect” prints.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            SectionTitle("Connection")
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary).monospacedDigit().textSelection(.enabled)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Terminal", systemImage: "terminal") { openWindow(id: "terminal") }
                .help("Open a shell on atlas")
            Menu("Power", systemImage: "power") {
                Button("Restart atlas…", systemImage: "arrow.clockwise") { Task { await ask(.restart) } }
                Button("Shut Down atlas…", systemImage: "power", role: .destructive) { Task { await ask(.shutdown) } }
            }
            .help("Restart or shut down atlas")
            .disabled(!session.isConnected)
        }
    }

    /// Touch ID or the password first, then the confirmation.
    private func ask(_ action: Power) async {
        guard await Biometric.authenticate(reason: action == .restart ? "restart atlas" : "shut down atlas") else { return }
        power = action
    }
}

/// A rounded panel on the page.
private struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: .rect(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
    }
}

private struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.title3.weight(.semibold)).padding(.bottom, 2)
    }
}

/// One live measure: its value, a 60 s curve and what it is.
private struct LiveCard: View {
    let title: String
    let value: Double
    let color: Color
    let series: [LiveSparkline.Point]
    let detail: String

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.headline)
                    Spacer()
                    Text(value, format: .percent.precision(.fractionLength(0)))
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: value))
                        .animation(.smooth, value: value)
                }
                LiveSparkline(series: series, color: color)
                    .frame(height: 64)
                Text(detail.isEmpty ? " " : detail)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(value, format: .percent.precision(.fractionLength(0))))
    }
}

/// A measure without a curve, as tall as a live card.
private struct FactCard<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: Content

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label(title, systemImage: symbol).font(.headline)
                content
                Spacer(minLength: 0)
            }
            .frame(height: 120, alignment: .topLeading)
        }
        .accessibilityElement(children: .combine)
    }
}
