import SwiftUI

struct DashboardView: View {
    var model: DashboardModel

    var body: some View {
        ScrollView {
            // KEIN GlassEffectContainer um den ganzen Scroll-Inhalt: der lässt
            // alle Glass-Layer beim Scrollen permanent gegeneinander blenden
            // (Compositing-Kosten pro Frame) — die Karten tragen ihr Glass selbst.
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
                        LoadChart(cpu: model.cpuSamples, gpu: model.gpuSamples)
                        NetChart(down: model.downSamples, up: model.upSamples,
                                 downNow: model.netDownMbps, upNow: model.netUpMbps)
                        SectionLabel(text: "Speicher")
                        bars(m)
                        SectionLabel(text: "Strom & Kosten")
                        CostCard(history: model.power, systemW: m.power?.systemW)
                        SectionLabel(text: "Container")
                        ContainersCard(containers: m.containers)
                        if let s = m.system {
                            systemInfo(s, uptime: m.uptimeS)
                        }
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
        .scrollIndicators(.hidden)
        .refreshable { await model.refresh() }
    }

    // MARK: rings

    private func gauges(_ m: Metrics) -> some View {
        GlassCard(padding: 16) {
            HStack(spacing: 6) {
                RingGauge(
                    value: model.cpuLive ?? m.cpu.usage, label: "CPU", systemImage: "cpu",
                    detail: "\(m.cpu.cores) Kerne"
                )
                if let g = m.gpu {
                    RingGauge(
                        value: model.gpuLive ?? g.usage, label: "GPU", systemImage: "cpu.fill",
                        detail: memText(g.memUsedMb, g.memTotalMb)
                    )
                }
                RingGauge(
                    value: model.memLive ?? m.mem.usage, label: "RAM", systemImage: "memorychip",
                    detail: String(format: "%.1f/%.0f GB",
                                   model.memGbLive > 0 ? model.memGbLive : m.mem.usedGb,
                                   m.mem.totalGb)
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
            }
            // Ganzsystem-Leistung (CPU+GPU+Baseline), nicht mehr nur die GPU.
            if let sys = m.power?.systemW {
                StatChip(icon: "bolt.fill", value: String(format: "%.0fW", sys),
                         label: "System", tint: Theme.warn)
            } else if let g = m.gpu {
                StatChip(icon: "bolt.fill", value: String(format: "%.0fW", g.powerW),
                         label: "GPU", tint: Theme.warn)
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

    private func systemInfo(_ s: Metrics.SystemInfo, uptime: Int) -> some View {
        GlassCard {
            VStack(spacing: 0) {
                infoRow("Betriebssystem", s.os, "opticaldisc.fill")
                infoDivider
                infoRow("Kernel", s.kernel, "cpu.fill")
                infoDivider
                infoRow("Laufzeit", uptimeText(uptime), "clock.arrow.circlepath")
            }
        }
    }

    private func infoRow(_ label: String, _ value: String, _ icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 13))
                .foregroundStyle(Theme.accent).frame(width: 20)
            Text(label).font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
            Spacer()
            Text(value).font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white).lineLimit(1).truncationMode(.middle)
        }
        .padding(.vertical, 9)
    }

    private var infoDivider: some View {
        Rectangle().fill(.white.opacity(0.07)).frame(height: 1)
    }

    private func uptimeText(_ s: Int) -> String {
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d) d \(h) h" }
        if h > 0 { return "\(h) h \(m) m" }
        return "\(m) m"
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
