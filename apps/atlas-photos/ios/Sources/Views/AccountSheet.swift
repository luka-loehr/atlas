import SwiftUI

struct AccountSheet: View {
    var library: Library
    @AppStorage("photos.host") private var host = "atlas.your-tailnet.ts.net:8788"
    @Environment(\.dismiss) private var dismiss
    @State private var sync: DeviceSync?
    @State private var showSync = false
    @State private var heat: [String: Int] = [:]

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemBackground).ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 20) {
                        header
                        if let s = library.stats {
                            statsGrid(s)
                            span(s)
                        }
                        if !heat.isEmpty {
                            heatmapCard
                        }
                        settingsLink
                        hostRow
                    }
                    .padding(20)
                }
            }
            .navigationTitle("atlas Fotos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task {
            if sync == nil { sync = DeviceSync(client: library.client) }
            if heat.isEmpty, let days = try? await library.client.heatmap() {
                heat = Dictionary(days.map { ($0.d, $0.n) }, uniquingKeysWith: { a, _ in a })
            }
        }
        .sheet(isPresented: $showSync) { if let sync { SyncProgressView(sync: sync) } }
    }

    private var settingsLink: some View {
        NavigationLink {
            SettingsScreen(
                library: library,
                onSyncNow: { startSync(delete: false) },
                onCleanupDevice: { startSync(delete: true) },
                onEmptyTrash: { Task { try? await library.client.emptyTrash(); await library.loadStats() } })
        } label: {
            HStack {
                Image(systemName: "gearshape.fill").foregroundStyle(.blue)
                Text("Einstellungen & iPhone-Sync")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 13)).foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func startSync(delete: Bool) {
        guard let sync else { return }
        showSync = true
        Task {
            guard await sync.requestAccess() else { return }
            await sync.scan()
            if delete { await sync.deleteBackedUpFromDevice() }
            else { await sync.backupNew() }
            await library.loadStats()
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            // Liquid-Glass-Logo statt Farbverlauf — ruhig und material-nativ.
            Image(systemName: "photo.stack")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 78, height: 78)
                .glassEffect(.regular, in: Circle())
            Text("Deine Bibliothek")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
        }
    }

    // MARK: - Aktivitäts-Heatmap (GitHub-Stil, Liquid Glass)

    private var heatTop: (date: String, n: Int)? {
        guard let m = heat.max(by: { $0.value < $1.value }) else { return nil }
        return (m.key, m.value)
    }

    private var heatmapCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "square.grid.4x3.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.blue)
                Text("Aktivität")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Text("\(heat.values.reduce(0, +)) Fotos · 12 Monate")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            HeatmapGrid(counts: heat)
                .frame(height: 58)
            if let top = heatTop, let d = HeatmapGrid.keyFormatter.date(from: top.date) {
                Text("Top-Tag: \(d.formatted(.dateTime.day().month(.wide).year())) · \(top.n) Fotos")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18))
    }

    private func statsGrid(_ s: LibraryStats) -> some View {
        HStack(spacing: 12) {
            stat("\(s.total - s.videos)", "Fotos", "photo")
            stat("\(s.videos)", "Videos", "video")
            stat("\(s.albums)", "Alben", "rectangle.stack")
            stat(bytes(s.bytes), "Größe", "internaldrive")
        }
    }

    private func stat(_ value: String, _ label: String, _ icon: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 16)).foregroundStyle(.blue)
            Text(value).font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(.primary).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func span(_ s: LibraryStats) -> some View {
        Group {
            if let o = s.oldest, let n = s.newest {
                Text("\(o.formatted(.dateTime.month().year())) – \(n.formatted(.dateTime.month().year()))")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var hostRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SERVER")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
            HStack {
                Image(systemName: "server.rack").foregroundStyle(.secondary)
                TextField("host:port", text: $host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .foregroundStyle(.primary)
                    .font(.system(size: 13, design: .monospaced))
                    .onSubmit { library.host = host; Task { await library.refresh() } }
            }
            .padding(12)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func bytes(_ b: Int64) -> String {
        let gb = Double(b) / 1_073_741_824
        return gb >= 1 ? String(format: "%.0f GB", gb)
                       : String(format: "%.0f MB", Double(b) / 1_048_576)
    }
}

/// GitHub-Style-Aktivitäts-Heatmap: 53 Wochen × 7 Tage, eine Zelle pro Tag,
/// Intensität = Fotoanzahl. Als EINE Canvas gezeichnet (~370 Rechtecke +
/// Monatslabels) statt 370 Views — rendert in einem Draw-Pass.
struct HeatmapGrid: View {
    /// "yyyy-MM-dd" → Anzahl Fotos an dem Tag.
    let counts: [String: Int]

    static let keyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()

    private static let monthNames = ["Jan", "Feb", "Mär", "Apr", "Mai", "Jun",
                                     "Jul", "Aug", "Sep", "Okt", "Nov", "Dez"]

    var body: some View {
        Canvas { ctx, size in
            let cal = Calendar.current
            let today = cal.startOfDay(for: .now)

            // Start: der Montag vor (heute − 364 Tage) → volle Wochenspalten.
            var start = cal.date(byAdding: .day, value: -364, to: today) ?? today
            let wd = cal.component(.weekday, from: start)      // 1 = So … 7 = Sa
            start = cal.date(byAdding: .day, value: -((wd + 5) % 7), to: start) ?? start

            let totalDays = (cal.dateComponents([.day], from: start, to: today).day ?? 0) + 1
            let weeks = Int(ceil(Double(totalDays) / 7.0))

            let labelH: CGFloat = 11
            let step = min(size.width / CGFloat(weeks), (size.height - labelH) / 7)
            let side = step - 1.4
            let x0 = (size.width - CGFloat(weeks) * step) / 2

            // Skala: p95 als Deckel, damit ein einzelner Extremtag
            // nicht alle anderen Zellen platt macht.
            let sorted = counts.values.sorted()
            let cap = max(sorted.isEmpty ? 1 : sorted[Int(Double(sorted.count - 1) * 0.95)], 1)

            var day = start
            var lastMonth = -1
            for w in 0..<weeks {
                for r in 0..<7 {
                    if day > today { break }
                    let key = Self.keyFormatter.string(from: day)
                    let n = counts[key] ?? 0
                    let rect = CGRect(x: x0 + CGFloat(w) * step,
                                      y: labelH + CGFloat(r) * step,
                                      width: side, height: side)
                    let path = Path(roundedRect: rect, cornerRadius: side * 0.3)
                    if n == 0 {
                        ctx.fill(path, with: .color(Color(.quaternarySystemFill)))
                    } else {
                        let t = pow(min(Double(n) / Double(cap), 1), 0.5)
                        ctx.fill(path, with: .color(.blue.opacity(0.22 + 0.78 * t)))
                    }
                    // Monatslabel über der Spalte, in der ein Monat beginnt
                    if r == 0 {
                        let m = cal.component(.month, from: day)
                        if m != lastMonth {
                            if lastMonth != -1 {   // erste Spalte nicht labeln
                                ctx.draw(
                                    Text(Self.monthNames[m - 1])
                                        .font(.system(size: 8, weight: .medium))
                                        .foregroundStyle(.secondary),
                                    at: CGPoint(x: x0 + CGFloat(w) * step, y: 0),
                                    anchor: .topLeading)
                            }
                            lastMonth = m
                        }
                    }
                    day = cal.date(byAdding: .day, value: 1, to: day) ?? day
                }
            }
        }
    }
}
