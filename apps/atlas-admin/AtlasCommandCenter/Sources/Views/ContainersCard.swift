import SwiftUI

/// Running docker containers on atlas.
struct ContainersCard: View {
    var containers: [Metrics.Container]

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("Container", systemImage: "shippingbox.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                    Spacer()
                    Text("\(containers.count)")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.5))
                        .monoDigits()
                }

                if containers.isEmpty {
                    Text("keine laufenden Container")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.4))
                        .padding(.vertical, 4)
                } else {
                    VStack(spacing: 10) {
                        ForEach(containers) { c in
                            HStack(spacing: 12) {
                                Circle()
                                    .fill(Theme.good)
                                    .frame(width: 8, height: 8)
                                    .shadow(color: Theme.good.opacity(0.6), radius: 4)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(c.name)
                                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                                        .foregroundStyle(.white)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Text(c.status)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.4))
                                }
                                Spacer()
                            }
                        }
                    }
                }
            }
        }
    }
}
