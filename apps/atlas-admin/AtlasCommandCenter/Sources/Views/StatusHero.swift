import SwiftUI

/// Top card: the machine's identity + online state + uptime.
struct StatusHero: View {
    var metrics: Metrics?
    var online: Bool
    var updatedAt: Date?

    var body: some View {
        GlassCard(padding: 22) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        PulseDot(online: online)
                        Text(online ? "ONLINE" : "OFFLINE")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(online ? Theme.good : Theme.hot)
                            .kerning(1.2)
                    }
                    Text(metrics?.hostname ?? "atlas")
                        .font(.system(size: 40, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                    if online, let m = metrics {
                        Text("seit \(m.uptimeText) online · \(m.cpu.cores) Kerne")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.5))
                            .monoDigits()
                    } else {
                        Text("keine Verbindung übers Tailnet")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
                Spacer()
                Image(systemName: online ? "cpu.fill" : "moon.zzz.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(online ? Theme.accent : .white.opacity(0.3))
                    .padding(14)
                    .glassEffect(.regular, in: .circle)
            }
        }
    }
}

struct PulseDot: View {
    var online: Bool
    @State private var animate = false

    var body: some View {
        let color = online ? Theme.good : Theme.hot
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
            .overlay(
                Circle()
                    .stroke(color, lineWidth: 2)
                    .scaleEffect(animate ? 2.4 : 1)
                    .opacity(animate ? 0 : 0.8)
            )
            .onAppear {
                guard online else { return }
                withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                    animate = true
                }
            }
    }
}
