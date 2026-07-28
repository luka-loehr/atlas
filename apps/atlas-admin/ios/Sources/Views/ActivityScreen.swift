import SwiftUI

/// GitHub-profile-style activity: a contribution heatmap of atlas' awake
/// hours (or monorepo commits), plus streak / totals tiles.
struct ActivityScreen: View {
    var host: String
    var token: String

    @State private var model = ActivityModel()
    @State private var metric: HeatMetric = .online

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background
                ScrollView {
                    VStack(spacing: 16) {
                        if let data = model.data {
                            Picker("Metrik", selection: $metric) {
                                ForEach(HeatMetric.allCases) { m in
                                    Text(m.title).tag(m)
                                }
                            }
                            .pickerStyle(.segmented)

                            HeatmapCard(days: data.days, metric: metric)
                            tiles
                            if let top = model.busiestDay, top.min > 0 {
                                busiest(top)
                            }
                        } else if model.error != nil {
                            offline
                        } else {
                            ProgressView().tint(.white).padding(.top, 80)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 30)
                }
                .scrollIndicators(.hidden)
                .refreshable { await model.load() }
            }
            .navigationTitle("Aktivität")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task {
            model.host = host
            model.token = token
            await model.load()
        }
    }

    private var tiles: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                VPNTile(
                    icon: "flame.fill", tint: Theme.warn,
                    value: "\(model.streak) \(model.streak == 1 ? "Tag" : "Tage")",
                    label: "Streak"
                )
                VPNTile(
                    icon: "clock.badge.checkmark.fill", tint: Theme.accent,
                    value: String(format: "%.0f h", model.hours30),
                    label: "online · 30 Tage"
                )
            }
            HStack(spacing: 10) {
                VPNTile(
                    icon: "power", tint: Theme.good,
                    value: "\(model.boots30)",
                    label: "Boots · 30 Tage"
                )
                VPNTile(
                    icon: "arrow.triangle.branch", tint: Theme.violet,
                    value: "\(model.commits30)",
                    label: "Commits · 30 Tage"
                )
            }
        }
    }

    private func busiest(_ day: ActivityData.Day) -> some View {
        GlassCard(padding: 14) {
            HStack(spacing: 12) {
                Image(systemName: "trophy.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.warn)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Fleißigster Tag")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                    Text("\(HeatmapCard.pretty(day.d)) — \(day.min / 60) h online, \(day.commits) Commits")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
        }
    }

    private var offline: some View {
        GlassCard(padding: 24) {
            VStack(spacing: 10) {
                Image(systemName: "moon.zzz.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Theme.violet)
                Text(model.error ?? "keine Verbindung")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.top, 40)
    }
}

enum HeatMetric: String, CaseIterable, Identifiable {
    case online, commits
    var id: String { rawValue }
    var title: String { self == .online ? "Online-Stunden" : "Commits" }
}

/// The contribution graph: columns = weeks (Mo–So), GitHub-style intensity.
struct HeatmapCard: View {
    var days: [ActivityData.Day]
    var metric: HeatMetric

    private let cell: CGFloat = 11
    private let gap: CGFloat = 3

    /// Weeks as columns; the first column is padded so rows align Mo…So.
    private var weeks: [[ActivityData.Day?]] {
        guard let first = days.first, let firstDate = Self.parse(first.d) else { return [] }
        // Monday = 0 … Sunday = 6
        let weekday = (Calendar.current.component(.weekday, from: firstDate) + 5) % 7
        var cells: [ActivityData.Day?] = Array(repeating: nil, count: weekday)
        cells.append(contentsOf: days.map { Optional($0) })
        while cells.count % 7 != 0 { cells.append(nil) }
        return stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<$0 + 7]) }
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(metric == .online ? "Wach-Stunden" : "Commits im Monorepo",
                          systemImage: metric == .online ? "sun.max.fill" : "arrow.triangle.branch")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                    Spacer()
                    Text("\(days.count) Tage")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.35))
                }

                monthLabels
                HStack(alignment: .top, spacing: gap) {
                    ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                        VStack(spacing: gap) {
                            ForEach(Array(week.enumerated()), id: \.offset) { _, day in
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(color(for: day))
                                    .frame(width: cell, height: cell)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)

                legend
            }
        }
    }

    /// A month label over the week that contains its 1st.
    private var monthLabels: some View {
        HStack(alignment: .top, spacing: gap) {
            ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                let label = week.compactMap { $0 }.first(where: { $0.d.hasSuffix("-01") })
                Text(label.map { Self.monthName($0.d) } ?? " ")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(width: cell)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(width: cell, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var legend: some View {
        HStack(spacing: 4) {
            Spacer()
            Text("weniger")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.35))
            ForEach(0..<5, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2)
                    .fill(level(Double(i) / 4))
                    .frame(width: 9, height: 9)
            }
            Text("mehr")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.35))
        }
    }

    private func color(for day: ActivityData.Day?) -> Color {
        guard let day else { return .clear }
        let value: Double
        switch metric {
        case .online: value = Double(day.min) / 60  // hours
        case .commits: value = Double(day.commits)
        }
        if value <= 0 { return Color.white.opacity(0.06) }
        // GitHub-ish buckets: online 0–2–6–12–24 h, commits 1–2–4–8+
        let steps: [Double] = metric == .online ? [2, 6, 12, 24] : [2, 4, 8, 99]
        let idx = steps.firstIndex(where: { value < $0 }) ?? 3
        return level(Double(idx + 1) / 4)
    }

    private func level(_ t: Double) -> Color {
        t <= 0 ? Color.white.opacity(0.06) : Theme.good.opacity(0.25 + t * 0.75)
    }

    // MARK: date helpers

    static func parse(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)
    }

    static func pretty(_ s: String) -> String {
        guard let d = parse(s) else { return s }
        return d.formatted(date: .abbreviated, time: .omitted)
    }

    static func monthName(_ s: String) -> String {
        guard let d = parse(s) else { return "" }
        return d.formatted(.dateTime.month(.abbreviated))
    }
}
