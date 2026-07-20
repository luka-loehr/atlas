import SwiftUI

/// Live-Fortschritt für iPhone→atlas-Backup und Geräte-Aufräumen.
/// Beobachtet eine `DeviceSync` (scan → backup / delete) und zeigt Zähler,
/// Balken und Ergebnis. Der eigentliche Ablauf wird vom Aufrufer gestartet.
struct SyncProgressView: View {
    @Bindable var sync: DeviceSync
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                VStack(spacing: 28) {
                    hero
                    if sync.deviceCount > 0 { counts }
                    if let err = sync.lastError, case .failed = sync.phase {
                        Text(err)
                            .font(.system(size: 13))
                            .foregroundStyle(.red.opacity(0.8))
                            .multilineTextAlignment(.center)
                    }
                    Spacer()
                    footer
                }
                .padding(24)
            }
            .navigationTitle("iPhone-Sync")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(sync.running ? "Stopp" : "Fertig") {
                        if sync.running { sync.cancel() } else { dismiss() }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(sync.running)
    }

    // MARK: - Hero (phase icon + primary progress)

    private var hero: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.15))
                    .frame(width: 92, height: 92)
                Image(systemName: icon)
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(tint)
                    .symbolEffect(.pulse, isActive: sync.running)
            }
            Text(headline)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)
            if !sync.currentName.isEmpty, sync.running {
                Text(sync.currentName)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
            }
            if let progress {
                ProgressView(value: progress)
                    .tint(tint)
                    .padding(.horizontal, 8)
            } else if sync.running {
                ProgressView().tint(tint)
            }
        }
    }

    // MARK: - Count chips

    private var counts: some View {
        HStack(spacing: 10) {
            chip("Gerät", sync.deviceCount, "iphone", .white)
            chip("Gesichert", sync.backedUpCount, "checkmark.icloud", .green)
            chip("Offen", sync.missingCount, "icloud.and.arrow.up", .blue)
        }
    }

    private func chip(_ title: String, _ value: Int, _ system: String, _ color: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: system).font(.system(size: 16, weight: .semibold)).foregroundStyle(color)
            Text("\(value)").font(.system(size: 20, weight: .bold)).foregroundStyle(.white).monospacedDigit()
            Text(title).font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Footer result line

    @ViewBuilder private var footer: some View {
        switch sync.phase {
        case .done where sync.deletedFromDevice > 0:
            resultLine("\(sync.deletedFromDevice) vom iPhone gelöscht · \(fmt(sync.reclaimedBytes)) frei", .green)
        case .done where sync.uploaded > 0:
            resultLine("\(sync.uploaded) auf atlas gesichert", .green)
        case .done:
            resultLine("Alles aktuell — nichts zu tun", .white.opacity(0.5))
        case .failed(let m):
            resultLine(m, .red)
        default:
            EmptyView()
        }
    }

    private func resultLine(_ text: String, _ color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill").font(.system(size: 13))
            Text(text).font(.system(size: 14, weight: .medium))
        }
        .foregroundStyle(color)
        .frame(maxWidth: .infinity)
        .padding(14)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Phase → presentation

    private var progress: Double? {
        switch sync.phase {
        case .scanning where sync.deviceCount > 0:
            return Double(sync.scanned) / Double(sync.deviceCount)
        case .backing where sync.total > 0:
            return Double(sync.uploaded) / Double(sync.total)
        default:
            return nil
        }
    }

    private var headline: String {
        switch sync.phase {
        case .idle:     return "Bereit"
        case .scanning: return "Durchsuche Bibliothek …"
        case .backing:  return "Sichere \(sync.uploaded)/\(sync.total)"
        case .deleting: return "Räume iPhone auf …"
        case .done:     return "Fertig"
        case .failed:   return "Fehlgeschlagen"
        }
    }

    private var icon: String {
        switch sync.phase {
        case .idle:     return "arrow.triangle.2.circlepath"
        case .scanning: return "magnifyingglass"
        case .backing:  return "icloud.and.arrow.up.fill"
        case .deleting: return "iphone.slash"
        case .done:     return "checkmark.circle.fill"
        case .failed:   return "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch sync.phase {
        case .failed: return .red
        case .done:   return .green
        case .deleting: return .orange
        default:      return .blue
        }
    }

    private func fmt(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }
}
