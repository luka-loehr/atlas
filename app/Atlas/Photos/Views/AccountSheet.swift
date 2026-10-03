import SwiftUI

/// The library at a glance, from the button on the Fotos tab: counts, the
/// covered time span and a year of activity. Settings live in their own tab.
struct AccountSheet: View {
    var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var heat: [String: Int] = [:]

    var body: some View {
        NavigationStack {
            List {
                if let s = library.stats {
                    Section {
                        LabeledContent("Photos", value: (s.total - s.videos).formatted())
                        LabeledContent("Videos", value: s.videos.formatted())
                        LabeledContent("Albums", value: s.albums.formatted())
                        LabeledContent("Size", value: s.bytes.fileSize)
                        if let o = s.oldest, let n = s.newest {
                            LabeledContent("Time Span",
                                           value: "\(o.formatted(.dateTime.month().year())) – \(n.formatted(.dateTime.month().year()))")
                        }
                    }
                    .monospacedDigit()
                } else {
                    HStack { Spacer(); ProgressView(); Spacer() }
                        .listRowBackground(Color.clear)
                }
                if !heat.isEmpty {
                    Section("Photos per Day") {
                        HeatmapGrid(counts: heat)
                            .frame(height: 64)
                            .padding(.vertical, 6)
                            .accessibilityHidden(true)
                        LabeledContent("Last 12 Months", value: "\(heat.values.reduce(0, +).formatted()) photos")
                        if let top = heatTop, let d = HeatmapGrid.keyFormatter.date(from: top.date) {
                            LabeledContent("Busiest Day",
                                           value: "\(d.formatted(.dateTime.day().month(.wide).year())) · \(top.n) photos")
                        }
                    }
                    .monospacedDigit()
                }
            }
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task {
            if heat.isEmpty, let days = try? await library.client.heatmap() {
                heat = Dictionary(days.map { ($0.d, $0.n) }, uniquingKeysWith: { a, _ in a })
            }
        }
    }

    private var heatTop: (date: String, n: Int)? {
        guard let m = heat.max(by: { $0.value < $1.value }) else { return nil }
        return (m.key, m.value)
    }
}

/// Aktivitäts-Heatmap: 53 Wochen × 7 Tage, eine Zelle pro Tag,
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

    private static let monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                                     "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

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
