import SwiftUI

/// YouTube link -> show, with a live animated pipeline: thumbnail, download
/// progress bar, pulsing analyze waveform, commit/push log, done state.
struct CreateShowSheet: View {
    var model: ShowModel
    @State private var url = ""
    @Environment(\.dismiss) private var dismiss

    private var status: CreateStatus? { model.createStatus }
    private var phase: String { status?.phase ?? "idle" }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background
                ScrollView {
                    VStack(spacing: 18) {
                        if model.creating || status != nil {
                            progressFlow
                        } else {
                            inputForm
                        }
                    }
                    .padding(20)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle("Neue Show")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                        .disabled(model.creating && !(status?.done ?? false))
                }
            }
        }
        .interactiveDismissDisabled(model.creating)
    }

    // MARK: input

    private var inputForm: some View {
        VStack(spacing: 18) {
            Image(systemName: "link.badge.plus")
                .font(.system(size: 40))
                .foregroundStyle(Theme.accent)
                .padding(.top, 20)
            Text("Show aus YouTube")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text("Link einfügen — atlas lädt den Song, analysiert Beats & Drops auf der GPU, baut die Show und pusht sie ins Repo.")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)

            TextField("https://youtu.be/…", text: $url)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .padding(14)
                .glassEffect(.regular, in: .rect(cornerRadius: 16))
                .foregroundStyle(.white)

            Button {
                Task { await model.create(url: url) }
            } label: {
                Text("Show erstellen")
                    .font(.system(size: 16, weight: .bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.glassProminent)
            .tint(Theme.accent)
            .disabled(!url.hasPrefix("http"))
        }
    }

    // MARK: live pipeline

    private var progressFlow: some View {
        VStack(spacing: 16) {
            thumbnailCard
            stepRow(icon: "arrow.down.circle.fill", label: "Song laden",
                    state: stepState(for: "download"),
                    detail: phase == "download" ? String(format: "%.0f %%", status?.percent ?? 0) : nil) {
                if phase == "download" {
                    ProgressView(value: (status?.percent ?? 0) / 100)
                        .tint(Theme.accent)
                }
            }
            stepRow(icon: "waveform", label: "GPU-Analyse — Beats & Drops",
                    state: stepState(for: "analyze"), detail: nil) {
                if phase == "analyze" { AnalyzeWaveform() }
            }
            stepRow(icon: "wand.and.stars", label: "Show kompilieren",
                    state: stepState(for: "compile"), detail: nil) { EmptyView() }
            stepRow(icon: "arrow.triangle.branch", label: "Commit & Push",
                    state: stepState(for: "commit"),
                    detail: nil) {
                if phase == "commit" || phase == "done" { gitLog }
            }

            if status?.done == true {
                doneCard
            } else if status?.failed == true {
                failedCard
            }
        }
    }

    private var thumbnailCard: some View {
        Group {
            if status?.thumb == true, let u = model.client.createThumbURL() {
                AsyncImage(url: u) { img in
                    img.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    RoundedRectangle(cornerRadius: 20).fill(Color.white.opacity(0.05))
                        .overlay(ProgressView().tint(.white))
                }
                .frame(height: 170)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .overlay(alignment: .bottomLeading) {
                    if let t = status?.title, !t.isEmpty {
                        Text(t)
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.black.opacity(0.45))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 20))
            } else {
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color.white.opacity(0.05))
                    .frame(height: 170)
                    .overlay {
                        VStack(spacing: 8) {
                            ProgressView().tint(.white)
                            Text("verbinde mit YouTube …")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                    }
            }
        }
    }

    private enum StepState { case pending, active, done }

    private func stepState(for step: String) -> StepState {
        let order = ["start", "download", "analyze", "compile", "commit", "done"]
        let cur = order.firstIndex(of: phase) ?? 0
        let mine = order.firstIndex(of: step) ?? 0
        if status?.done == true { return .done }
        if cur == mine { return .active }
        return cur > mine ? .done : .pending
    }

    @ViewBuilder
    private func stepRow(icon: String, label: String, state: StepState,
                         detail: String?, @ViewBuilder extra: () -> some View) -> some View {
        GlassCard(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(state == .done ? Theme.good.opacity(0.18)
                                  : state == .active ? Theme.accent.opacity(0.18)
                                  : Color.white.opacity(0.05))
                            .frame(width: 34, height: 34)
                        if state == .done {
                            Image(systemName: "checkmark")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(Theme.good)
                        } else if state == .active {
                            ProgressView().tint(Theme.accent).scaleEffect(0.75)
                        } else {
                            Image(systemName: icon)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.35))
                        }
                    }
                    Text(label)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(state == .pending ? .white.opacity(0.4) : .white)
                    Spacer()
                    if let detail {
                        Text(detail)
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(Theme.accent)
                    }
                }
                extra()
            }
        }
    }

    private var gitLog: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach((status?.log ?? "").split(separator: "\n").filter { $0.hasPrefix("git:") }, id: \.self) { line in
                Text(String(line))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.good.opacity(0.9))
            }
        }
    }

    private var doneCard: some View {
        GlassCard(padding: 18) {
            HStack(spacing: 14) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Theme.good)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Show ist fertig!")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(status?.name ?? "")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                }
                Spacer()
                Button("Öffnen") { dismiss() }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.good)
            }
        }
    }

    private var failedCard: some View {
        GlassCard(padding: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Fehlgeschlagen", systemImage: "xmark.octagon.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.hot)
                Text((status?.log ?? "").split(separator: "\n").suffix(5).joined(separator: "\n"))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
    }
}

/// Pulsing bars while the GPU chews on the song — pure animation, no data.
struct AnalyzeWaveform: View {
    @State private var t = false

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<28, id: \.self) { i in
                Capsule()
                    .fill(Theme.accent.opacity(0.85))
                    .frame(width: 4,
                           height: t ? CGFloat(6 + (i * 13 % 26)) : CGFloat(6 + ((i + 9) * 7 % 26)))
            }
        }
        .frame(height: 34)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.45).repeatForever(autoreverses: true)) {
                t = true
            }
        }
    }
}
