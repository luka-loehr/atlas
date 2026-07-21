import SwiftUI
import Charts

/// Strom & Kosten: 24-h-Hochrechnung aus der aktuellen Leistung, kumulierte
/// Kosten seit Messbeginn und ein Balken pro Tag (Farbe = Höhe der Kosten).
/// Der €/kWh-Tarif ist in den Einstellungen konfigurierbar.
struct CostCard: View {
    var history: PowerHistory?
    var systemW: Double?
    @AppStorage("power.pricePerKwh") private var price = 0.40

    private var projectedDaily: Double? { systemW.map { $0 / 1000 * 24 * price } }
    private var totalCost: Double { (history?.totalWh ?? 0) / 1000 * price }
    private var days: [PowerDay] { history?.days ?? [] }
    private var maxCost: Double { max(days.map { $0.kwh * price }.max() ?? 0.01, 0.01) }

    private struct Bar: Identifiable {
        let id: String
        let date: Date
        let cost: Double
        let tint: Color
    }

    // precomputed so the Chart closure stays trivial (fast to type-check)
    private var bars: [Bar] {
        let mx = maxCost
        return days.compactMap { d in
            guard let date = d.date else { return nil }
            let cost = d.kwh * price
            return Bar(id: d.day, date: date, cost: cost,
                       tint: Theme.heat(min(cost / mx, 1)))
        }
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    tile(title: "Heute · 24h-Hochrechnung", value: projectedDaily,
                         icon: "sun.max.fill", tint: Theme.warn)
                    tile(title: "Gesamt seit Messbeginn", value: totalCost,
                         icon: "eurosign.circle.fill", tint: Theme.good)
                }
                if !days.isEmpty {
                    chart
                } else {
                    Text("Tagesverlauf wird ab jetzt aufgezeichnet …")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                }
                HStack {
                    Text("Tarif").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                    Spacer()
                    Text(String(format: "%.2f €/kWh", price))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
        }
    }

    private func tile(title: String, value: Double?, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon).font(.system(size: 14)).foregroundStyle(tint)
            Text(value.map { String(format: "%.2f €", $0) } ?? "–")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .contentTransition(.numericText(value: value ?? 0))
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }

    private var chart: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Kosten pro Tag")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
            Chart(bars) { b in
                BarMark(
                    x: .value("Tag", b.date, unit: .day),
                    y: .value("Kosten", b.cost)
                )
                .foregroundStyle(b.tint)
                .cornerRadius(3)
            }
            .chartYAxis {
                AxisMarks(position: .leading) { v in
                    AxisGridLine().foregroundStyle(.white.opacity(0.06))
                    AxisValueLabel {
                        if let c = v.as(Double.self) {
                            Text(String(format: "%.1f€", c))
                                .font(.system(size: 8)).foregroundStyle(.white.opacity(0.4))
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: max(days.count / 6, 1))) { _ in
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                        .font(.system(size: 8))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .frame(height: 120)
        }
    }
}
