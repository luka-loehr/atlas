import SwiftUI

/// Exit-node page: atlas as the tailnet's safe tunnel — ads blocked, hours
/// tunneled, bytes protected, and every device on the net.
struct VPNScreen: View {
    var host: String
    var token: String

    @State private var model = VPNModel()

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background
                ScrollView {
                    VStack(spacing: 16) {
                        ShieldHero(status: model.status, error: model.error)

                        if let s = model.status {
                            tiles(s)
                            if s.adguard.ok {
                                blockedBar(s.adguard)
                            } else {
                                adguardHint
                            }
                            peersCard(s)
                            footer(s)
                        } else if model.error == nil {
                            ProgressView().tint(.white).padding(.top, 60)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 30)
                }
                .scrollIndicators(.hidden)
                .refreshable { await model.refresh() }
            }
            .navigationTitle("Exit Node")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task {
            model.host = host
            model.token = token
            model.start()
        }
        .onDisappear { model.stop() }
    }

    // MARK: stat tiles

    private func tiles(_ s: VPNStatus) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                VPNTile(
                    icon: "shield.slash.fill", tint: Theme.hot,
                    value: s.adguard.ok ? "\((s.adguard.blocked ?? 0).formatted())" : "—",
                    label: "Ads geblockt"
                )
                VPNTile(
                    icon: "clock.fill", tint: Theme.accent,
                    value: Fmt.hours(s.tunnelS),
                    label: "im Tunnel"
                )
            }
            HStack(spacing: 10) {
                VPNTile(
                    icon: "lock.shield.fill", tint: Theme.good,
                    value: Fmt.bytes(s.bytes),
                    label: "Daten geschützt"
                )
                VPNTile(
                    icon: "network", tint: Theme.violet,
                    value: s.adguard.ok ? "\((s.adguard.queries ?? 0).formatted())" : "\(s.peers.count)",
                    label: s.adguard.ok ? "DNS-Anfragen" : "Geräte"
                )
            }
        }
    }

    // MARK: adguard

    private func blockedBar(_ a: VPNStatus.AdGuard) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Werbefilter", systemImage: "shield.lefthalf.filled")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                    Spacer()
                    Text(String(format: "%.1f %% geblockt", a.blockedRatio * 100))
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.hot)
                        .monoDigits()
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.08))
                        Capsule()
                            .fill(LinearGradient(colors: [Theme.hot.opacity(0.7), Theme.hot],
                                                 startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(6, geo.size.width * min(a.blockedRatio, 1)))
                            .animation(.smooth(duration: 0.5), value: a.blockedRatio)
                    }
                }
                .frame(height: 10)
                if let ms = a.avgMs {
                    Text(String(format: "Ø Antwortzeit %.1f ms", ms))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                        .monoDigits()
                }
            }
        }
    }

    private var adguardHint: some View {
        GlassCard(padding: 14) {
            HStack(spacing: 12) {
                Image(systemName: "shield.slash")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.warn)
                VStack(alignment: .leading, spacing: 2) {
                    Text("DNS-Blocker offline")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                    Text("AdGuard Home auf atlas antwortet nicht — Ad-Statistiken pausieren.")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
        }
    }

    // MARK: peers

    private func peersCard(_ s: VPNStatus) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("Geräte im Tailnet", systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                    Spacer()
                    Text("\(s.peers.filter(\.online).count)/\(s.peers.count) online")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.45))
                        .monoDigits()
                }
                VStack(spacing: 12) {
                    ForEach(s.peers.sorted { ($0.online ? 0 : 1, $0.host) < ($1.online ? 0 : 1, $1.host) }) { p in
                        HStack(spacing: 12) {
                            Circle()
                                .fill(p.online ? Theme.good : Color.white.opacity(0.15))
                                .frame(width: 9, height: 9)
                                .shadow(color: p.online ? Theme.good.opacity(0.6) : .clear, radius: 4)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.host)
                                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.white)
                                Text(p.os)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.4))
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Label(Fmt.bytes(p.rx), systemImage: "arrow.down")
                                Label(Fmt.bytes(p.tx), systemImage: "arrow.up")
                            }
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.45))
                        }
                    }
                }
            }
        }
    }

    private func footer(_ s: VPNStatus) -> some View {
        let since = Date(timeIntervalSince1970: TimeInterval(s.since))
        return Text("Tailscale \(s.version) · zählt seit \(since.formatted(date: .abbreviated, time: .omitted))")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.3))
            .padding(.top, 2)
    }
}

/// Big animated shield: pulsing rings while the tunnel is up.
struct ShieldHero: View {
    var status: VPNStatus?
    var error: String?

    private var up: Bool { status?.exitNode == true && status?.backend == "Running" }

    var body: some View {
        GlassCard(padding: 24) {
            VStack(spacing: 14) {
                ZStack {
                    if up {
                        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                            let t = context.date.timeIntervalSinceReferenceDate
                            ZStack {
                                ForEach(0..<3, id: \.self) { i in
                                    let phase = (t / 2.4 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                                    Circle()
                                        .stroke(Theme.good.opacity((1 - phase) * 0.35), lineWidth: 1.5)
                                        .frame(width: 90 + phase * 110, height: 90 + phase * 110)
                                }
                            }
                        }
                    }
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: up
                                    ? [Theme.good.opacity(0.35), Theme.good.opacity(0.06)]
                                    : [Color.white.opacity(0.10), .clear],
                                center: .center, startRadius: 6, endRadius: 60
                            )
                        )
                        .frame(width: 96, height: 96)
                    Image(systemName: up ? "checkmark.shield.fill" : "shield.slash.fill")
                        .font(.system(size: 44, weight: .semibold))
                        .foregroundStyle(up ? Theme.good : Theme.warn)
                        .shadow(color: up ? Theme.good.opacity(0.6) : .clear, radius: 14)
                }
                .frame(height: 130)

                VStack(spacing: 4) {
                    Text(error != nil ? "atlas offline"
                         : up ? "Exit Node aktiv"
                         : "Exit Node inaktiv")
                        .font(.system(size: 22, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                    Text(error ?? status?.selfDns ?? "…")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

/// One glass stat tile.
struct VPNTile: View {
    var icon: String
    var tint: Color
    var value: String
    var label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
            Text(value)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .monoDigits()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
                .textCase(.uppercase)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }
}
