import SwiftUI

struct DashboardView: View {
    var model: DashboardModel

    var body: some View {
        ScrollView {
            GlassEffectContainer(spacing: 16) {
                VStack(spacing: 16) {
                    StatusHero(
                        metrics: model.metrics,
                        online: model.online,
                        updatedAt: model.updatedAt
                    )

                    if model.online, let m = model.metrics {
                        gauges(m)
                        chips(m)
                        SectionLabel(text: "Verlauf")
                        LoadChart(cpu: model.cpuHistory, gpu: model.gpuHistory)
                        NetChart(down: model.netDownHistory, up: model.netUpHistory,
                                 downNow: model.netDownMbps, upNow: model.netUpMbps)
                        SectionLabel(text: "Speicher")
                        bars(m)
                        SectionLabel(text: "Container")
                        ContainersCard(containers: m.containers)
                        footer
                    } else if model.metrics == nil && model.lastError == nil {
                        loading
                    } else {
                        offline
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 30)
            }
        }
        .scrollIndicators(.hidden)
        .refreshable { await model.refresh() }
    }

    // MARK: rings

    private func gauges(_ m: Metrics) -> some View {
        GlassCard(padding: 16) {
            HStack(spacing: 6) {
                RingGauge(
                    value: m.cpu.usage, label: "CPU", systemImage: "cpu",
                    detail: "\(m.cpu.cores) Kerne"
                )
                if let g = m.gpu {
                    RingGauge(
                        value: g.usage, label: "GPU", systemImage: "cpu.fill",
                        detail: memText(g.memUsedMb, g.memTotalMb)
                    )
                }
                RingGauge(
                    value: m.mem.usage, label: "RAM", systemImage: "memorychip",
                    detail: String(format: "%.1f/%.0f GB", m.mem.usedGb, m.mem.totalGb)
                )
            }
        }
    }

    // MARK: chips

    private func chips(_ m: Metrics) -> some View {
        HStack(spacing: 10) {
            if let t = m.cpu.tempC {
                StatChip(icon: "thermometer.medium", value: "\(Int(t))°",
                         label: "CPU", tint: Theme.heat(t / 90))
            }
            if let g = m.gpu {
                StatChip(icon: "thermometer.high", value: "\(Int(g.tempC))°",
                         label: "GPU", tint: Theme.heat(g.tempC / 90))
                StatChip(icon: "bolt.fill", value: String(format: "%.0fW", g.powerW),
                         label: "Power", tint: Theme.warn)
            }
            StatChip(icon: "gauge.with.dots.needle.50percent",
                     value: String(format: "%.2f", m.load.first ?? 0),
                     label: "Load", tint: Theme.accent)
        }
    }

    // MARK: bars

    private func bars(_ m: Metrics) -> some View {
        GlassCard {
            VStack(spacing: 18) {
                UsageBar(
                    title: "Speicher", systemImage: "memorychip.fill",
                    ratio: m.mem.usage / 100,
                    caption: String(format: "%.1f / %.0f GB", m.mem.usedGb, m.mem.totalGb)
                )
                UsageBar(
                    title: "Festplatte", systemImage: "internaldrive.fill",
                    ratio: m.disk.usage / 100,
                    caption: "\(Int(m.disk.usedGb)) / \(Int(m.disk.totalGb)) GB"
                )
            }
        }
    }

    private var footer: some View {
        Text(model.updatedAt.map { "aktualisiert \($0.formatted(date: .omitted, time: .standard))" } ?? "")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.3))
            .monoDigits()
            .padding(.top, 2)
    }

    // MARK: states

    private var loading: some View {
        VStack(spacing: 14) {
            ProgressView().tint(.white)
            Text("verbinde mit atlas …")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity).padding(.vertical, 60)
    }

    private var offline: some View {
        GlassCard(padding: 24) {
            VStack(spacing: 12) {
                Image(systemName: "moon.zzz.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(Theme.violet)
                Text("atlas ist offline")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text(model.lastError ?? "keine Verbindung")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
                Text("Wecken per Wake-on-LAN geht nur im Heimnetz (atlas boot).")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.35))
                    .multilineTextAlignment(.center)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func memText(_ used: Double, _ total: Double) -> String {
        String(format: "%.1f/%.0f GB", used / 1024, total / 1024)
    }
}
