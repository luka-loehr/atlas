import SwiftUI
import AppKit

/// The server, in the form System Settings uses: grouped sections of
/// labelled rows. Activity (live curves), the drives with their health,
/// what Atlas keeps on this Mac, the services and what is still
/// processing, and the server and connection. Restart, shut down and the
/// terminal sit in the toolbar. It is the app's settings too (⌘,).
struct MacServerView: View {
    @Environment(Session.self) private var session
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var machine = Machine.shared
    @State private var storage = StorageUse()
    @State private var measured = false
    @State private var power: Power?
    @State private var confirmDisconnect = false
    /// The chosen cache size in bytes; 0 for automatic.
    @State private var cacheChoice: Int64 = MediaStore.chosenBudget ?? 0
    private static let cacheSizes = [5, 10, 25, 50, 100, 200]

    enum Power: String, Identifiable {
        case restart, shutdown
        var id: String { rawValue }
    }

    private static let roles = ["atlas-server": "API and processing", "atlas-ml": "Search, faces, pets and text"]
    private static let queueNames: [String: String] = [
        "thumb": "Thumbnails", "meta": "Metadata", "geocode": "Places", "embed": "Search index",
        "faces": "Faces, pets and text", "preview": "Video streams", "drive_text": "File text",
    ]

    var body: some View {
        NavigationStack {
            // grouped like System Settings, but in plain stacks: a Form's
            // rows are drawn in software on the Mac, so every frame of a
            // curve or gliding number redrew whole sections on the CPU
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if session.isConnected {
                        // its own view: a new sample (twice a second) only
                        // updates this panel, not the whole page
                        ActivityPanel(machine: machine)
                        drives
                        thisMac
                        services
                        processing
                    }
                    server
                }
                .labeledContentStyle(PanelRowStyle())
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Server")
            .navigationSubtitle(statusText)
            .toolbar { toolbar }
        }
        .task(id: session.config) {
            guard let api = session.api else { return }
            await machine.keepLive(api)
        }
        // services, the queue and the drives change while the page is open
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

    private var statusText: String {
        switch session.reachability {
        case .online: "Online"
        case .offline: "Offline"
        case .unauthorized: "Token rejected"
        case .unknown: model.library.online ? "Online" : "Connecting…"
        }
    }

    // MARK: - Activity

    // MARK: - Drives

    @ViewBuilder
    private var drives: some View {
        Panel("Drives") {
            if let drives = machine.drives?.drives {
                // the system drive first, then the others by size
                ForEach(drives.sorted { a, b in
                    let sa = a.mounts.contains { $0.mount == "/" }, sb = b.mounts.contains { $0.mount == "/" }
                    return sa != sb ? sa : a.size > b.size
                }) { drive in ServerDriveRow(drive: drive) }
            } else if let disks = machine.snapshot?.disks {
                // before the drives answer: the filesystems from the snapshot
                ForEach(disks) { disk in
                    UsageRow(title: disk.mount == "/" ? "System" : disk.mount, used: disk.used, total: disk.total)
                }
            } else {
                LabeledContent("Drives") { ProgressView().controlSize(.small) }
            }
        }
    }

    // MARK: - This Mac

    private var thisMac: some View {
        Panel {
            StorageBar(use: storage)
                .redacted(reason: measured ? [] : .placeholder)
            LabeledContent("Cache size") { cachePicker }
            LabeledContent("Cache folder") {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([MediaStore.shared.directory])
                }
            }
        } header: {
            Text("On This Mac")
        } footer: {
            Text("Every grid thumbnail stays on this Mac, so the library opens complete, also offline. Previews, originals and videos fill up to \(MediaStore.budget.fileSize) as you browse and make room on their own, least used first, and sooner when the disk runs low. Automatic is a tenth of the free space.")
        }
    }

    private var cachePicker: some View {
            Picker("Cache size", selection: Binding(
                get: { cacheChoice },
                set: { choice in
                    cacheChoice = choice
                    MediaStore.chosenBudget = choice == 0 ? nil : choice
                    Task { storage = await StorageUse.measure() }
                })) {
                Text("Automatic (\(MediaStore.automaticBudget.fileSize))").tag(Int64(0))
                Divider()
                ForEach(Self.cacheSizes, id: \.self) { gb in
                    Text("\(gb) GB").tag(Int64(gb) << 30)
                }
            }
            .labelsHidden()
            .fixedSize()
    }

    // MARK: - Services and processing

    @ViewBuilder
    private var services: some View {
        Panel("Services") {
            if let services = machine.services {
                ForEach(services.units) { unit in
                    LabeledContent {
                        HStack(spacing: 10) {
                            if let memory = unit.memory { Text(memory.fileSize).foregroundStyle(.secondary).monospacedDigit() }
                            StateLabel(healthy: unit.state == "active", text: unit.state == "active" ? "Running" : "Stopped")
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(unit.unit)
                            Text(Self.roles[unit.unit] ?? unit.role).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                LabeledContent("Database", value: "Postgres \(services.database.version.split(separator: " ").first.map(String.init) ?? "") · \(services.database.bytes.fileSize)")
                LabeledContent("Search model") {
                    if let ml = services.ml {
                        StateLabel(healthy: true, text: ml.embedder == "loaded" ? "Loaded" : "Ready")
                    } else {
                        StateLabel(healthy: false, text: "Offline")
                    }
                }
            } else {
                LabeledContent("Services") { ProgressView().controlSize(.small) }
            }
        }
    }

    @ViewBuilder
    private var processing: some View {
        if let services = machine.services {
            Panel {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 24, alignment: .leading)],
                          alignment: .leading, spacing: 10) {
                    ForEach(services.queue.keys.sorted { (Self.queueNames[$0] ?? $0) < (Self.queueNames[$1] ?? $1) }, id: \.self) { kind in
                        let counts = services.queue[kind] ?? [:]
                        let waiting = (counts["pending"] ?? 0) + (counts["running"] ?? 0)
                        HStack(spacing: 8) {
                            Image(systemName: waiting == 0 ? "checkmark.circle.fill" : "clock.fill")
                                .foregroundStyle(waiting == 0 ? .green : .orange)
                            Text(Self.queueNames[kind] ?? kind)
                            Spacer(minLength: 6)
                            RollingText(waiting == 0 ? (counts["done"] ?? 0).formatted() : "\(waiting.formatted()) left", secondary: true)
                        }
                    }
                }
                .padding(.vertical, 4)
                ForEach(services.failed) { job in
                    LabeledContent {
                        Text(job.error ?? "").lineLimit(2).foregroundStyle(.secondary)
                    } label: {
                        Label(Self.queueNames[job.kind] ?? job.kind, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            } header: {
                Text("Processing")
            } footer: {
                Text(services.pending == 0 ? "Everything is processed." : "\(services.pending.formatted()) jobs are waiting.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Server and connection

    private var server: some View {
        Panel {
            if session.isConnected {
                if let s = machine.snapshot {
                    LabeledContent("Name", value: s.hostname)
                    LabeledContent("Atlas", value: s.version)
                    if let os = s.os { LabeledContent("System", value: os) }
                    if let kernel = s.kernel { LabeledContent("Kernel", value: kernel) }
                    if let cpu = s.cpu.model { LabeledContent("Processor", value: "\(cpu), \(s.cpu.cores) threads") }
                    if let gpu = s.gpu { LabeledContent("Graphics", value: gpu.name) }
                    LabeledContent("Uptime", value: Duration.seconds(s.uptime_s)
                        .formatted(.units(allowed: [.days, .hours, .minutes], width: .wide)))
                }
                LabeledContent("Address") { Text(session.base).textSelection(.enabled) }
                if let info = session.info { LabeledContent("Time zone", value: info.timezone) }
                LabeledContent("Library", value: model.library.assets.count == 1 ? "1 item" : "\(model.library.assets.count.formatted()) items")
                LabeledContent("Access token") {
                    Button("Disconnect…") { confirmDisconnect = true }
                }
            } else {
                Text("Not connected. Connect in the main window, or open the link “atlas connect” prints.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Server")
        } footer: {
            if session.isConnected {
                Text("The access token is kept in your keychain on this Mac.").foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Terminal", systemImage: "apple.terminal") { openWindow(id: "terminal") }
                .help("Open a shell on atlas")
            Menu("Power", systemImage: "power") {
                Button("Restart atlas…", systemImage: "arrow.clockwise") { Task { await ask(.restart) } }
                Button("Shut Down atlas…", systemImage: "power") { Task { await ask(.shutdown) } }
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

/// One live measure: name, value gliding as it changes, its last minute as
/// a curve, and what it is in absolute terms.
private struct Meter: View {
    let title: String
    let value: Double
    let color: Color
    let series: [LiveSparkline.Point]
    let detail: String
    @State private var previous: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).foregroundStyle(.secondary)
                Spacer()
                RollingText("\(Int(value.rounded())) %", rising: value >= previous, size: 22, weight: .semibold)
                    .onChange(of: value) { old, _ in previous = old }
            }
            LiveSparkline(series: series, color: color)
                .frame(height: 48)
            RollingText(detail.isEmpty ? " " : detail, size: 12, secondary: true)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(value / 100, format: .percent.precision(.fractionLength(0))))
    }
}

/// A value without a curve, its changed characters rolling in.
private struct Fact: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).foregroundStyle(.secondary)
            RollingText(text, size: 15, weight: .medium)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// A drive: what it is and its health, then each filesystem on it with how
/// full it is.
private struct ServerDriveRow: View {
    let drive: DriveReport.Drive

    var body: some View {
        LabeledContent {
            health
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(drive.model ?? drive.name)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: drive.transport == "usb" ? "externaldrive" : "internaldrive")
                    .foregroundStyle(.secondary)
            }
        }
        ForEach(drive.mounts) { mount in
            UsageRow(title: mount.mount == "/" ? "System (/)" : mount.mount, used: mount.used, total: mount.size)
                .padding(.leading, 28)
        }
    }

    private var detail: String {
        let kind = drive.isSSD ? (drive.transport == "nvme" ? "NVMe SSD" : "SSD") : "Hard disk"
        let via = drive.transport.map { $0 == "nvme" ? nil : $0.uppercased() } ?? nil
        var parts = [kind, via, drive.size.fileSize].compactMap { $0 }
        if let h = drive.health {
            if let t = h.temperature { parts.append("\(t) °C") }
            if let hours = h.hours { parts.append("\(hours.formatted()) h") }
            if let rpm = h.rpm { parts.append("\(rpm.formatted()) rpm") }
            if let wear = h.wear { parts.append("\(wear) % worn") }
            if let written = h.written { parts.append("\(written.fileSize) written") }
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var health: some View {
        if let h = drive.health {
            if h.asleep == true {
                Label("Asleep", systemImage: "moon.zzz.fill").foregroundStyle(.secondary)
            } else if h.passed == false {
                StateLabel(healthy: false, text: "Failing")
            } else if h.problems > 0 {
                StateLabel(healthy: false, text: "\(h.problems) bad sectors")
            } else {
                StateLabel(healthy: true, text: "Healthy")
            }
        } else {
            Text("No health data").foregroundStyle(.secondary)
        }
    }
}

/// A filesystem and how full it is: a plain bar, not a control.
private struct UsageRow: View {
    let title: String
    let used: Int64
    let total: Int64

    private var fraction: Double { total > 0 ? Double(used) / Double(total) : 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                Spacer()
                Text("\((total - used).fileSize) free of \(total.fileSize)")
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.trackFill)
                    Capsule().fill(fraction > 0.9 ? Color.red : fraction > 0.75 ? Color.orange : Color.accentColor)
                        .frame(width: max(geo.size.width * fraction, 4))
                }
            }
            .frame(height: 6)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text("\((total - used).fileSize) free of \(total.fileSize)"))
    }
}

/// A titled group of rows on a rounded panel, as a grouped Form draws it.
private struct Panel<Content: View, Header: View, Footer: View>: View {
    @ViewBuilder var content: Content
    @ViewBuilder var header: Header
    @ViewBuilder var footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
                .font(.headline)
                .padding(.horizontal, 10)
                .padding(.bottom, 2)
            VStack(spacing: 0) {
                Group(subviews: content) { rows in
                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                        if i > 0 { Divider().padding(.horizontal, 10) }
                        row
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                    }
                }
            }
            .background(Color.panelFill, in: .rect(cornerRadius: 10))
            footer
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
                .padding(.top, 2)
        }
    }
}

extension Panel where Footer == EmptyView {
    init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header) {
        self.init(content: content, header: header, footer: { EmptyView() })
    }
}

extension Panel where Header == Text, Footer == EmptyView {
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.init(content: content, header: { Text(title) }, footer: { EmptyView() })
    }
}

/// A row: label on the left, its value on the right in the secondary color.
private struct PanelRowStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: 12) {
            configuration.label
            Spacer(minLength: 12)
            configuration.content
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}

private extension Color {
    /// A grouped Form's panel: white in light mode, a faint lift in dark.
    static let panelFill = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.03) : NSColor.white
    })
}

/// CPU, GPU and memory with their curves, then network, power and load.
/// The only part of the page that reads the live samples.
private struct ActivityPanel: View {
    let machine: Machine

    var body: some View {
        let latest = machine.latest ?? MetricSample(ts: 0, cpu: 0, mem: 0, mem_gb: 0, gpu: 0, gpu_mem_mb: 0, rx: 0, tx: 0)
        let snapshot = machine.snapshot
        let rate = machine.throughput
        return Panel("Activity") {
            // each value once: the three loads with their curves, then
            // network, power and load average, all gliding as they change
            Grid(horizontalSpacing: 28, verticalSpacing: 18) {
                GridRow {
                    Meter(title: "CPU", value: latest.cpu, color: .blue, series: machine.series(\.cpu),
                          detail: latest.cpu_temp.map { "\(Int($0)) °C" } ?? "")
                    if snapshot?.gpu != nil || snapshot == nil {
                        Meter(title: "GPU", value: latest.gpu, color: .purple, series: machine.series(\.gpu),
                              detail: [snapshot?.gpu.map { String(format: "%.1f of %.0f GB", latest.gpu_mem_mb / 1024, $0.mem_total_mb / 1024) },
                                       latest.gpu_temp.map { "\(Int($0)) °C" }].compactMap { $0 }.joined(separator: " · "))
                    }
                    Meter(title: "Memory", value: latest.mem, color: .teal, series: machine.series(\.mem),
                          detail: String(format: "%.1f of %.0f GB", latest.mem_gb, snapshot?.mem_total_gb ?? 0))
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                GridRow {
                    Fact(title: "Network", text: "↓ \(Int64(rate.down).fileSize)/s  ↑ \(Int64(rate.up).fileSize)/s")
                    Fact(title: "Power", text: [latest.system_w.map { "\(Int($0)) W" }, latest.cpu_w.map { "CPU \(Int($0))" },
                                                latest.gpu_w.map { "GPU \(Int($0))" }].compactMap { $0 }.joined(separator: " · "))
                    Fact(title: "Load average", text: snapshot.map { $0.load.map { String(format: "%.2f", $0) }.joined(separator: " · ") } ?? "–")
                }
            }
            .padding(.vertical, 6)
            .redacted(reason: machine.latest == nil ? .placeholder : [])
        }
    }

}
