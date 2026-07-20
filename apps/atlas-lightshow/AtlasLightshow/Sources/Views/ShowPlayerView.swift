import SwiftUI

struct ShowPlayerView: View {
    var model: ShowModel
    var show: Show

    @State private var audio = ShowAudio()
    @State private var stopping = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VisualizerView(buffer: audio.buffer, bandCount: ShowAudio.bandCount)
                .ignoresSafeArea()

            // pulsating gradient hugging the display edges, driven by the music
            EdgeGlow(buffer: audio.buffer)
                .allowsHitTesting(false)

            VStack {
                header
                Spacer()
                if audio.finished {
                    finishedCard
                } else {
                    controls
                }
            }
            .padding(.horizontal, 20)
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .task {
            async let lights: () = { try? await model.client.startShow(show.name) }()
            if let url = model.client.audioURL(show.name) {
                await audio.play(url: url)
            }
            await lights
        }
        .onDisappear {
            audio.stop()
            let client = model.client
            Task.detached { try? await client.stopShow() }
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            Text(show.title)
                .font(.system(size: 20, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
            HStack(spacing: 6) {
                Circle().fill(audio.finished ? Theme.good : Theme.hot).frame(width: 7, height: 7)
                Text(audio.loading ? "Lichter laufen · Song lädt …"
                     : audio.finished ? "Show beendet"
                     : "LIVE · Lichter auf atlas · Sound am iPhone")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
            }
            // non-seekable progress
            if audio.duration > 0 {
                VStack(spacing: 4) {
                    ProgressView(value: min(audio.currentTime, audio.duration), total: audio.duration)
                        .progressViewStyle(.linear)
                        .tint(.white.opacity(0.85))
                    HStack {
                        Text(timeText(audio.currentTime))
                        Spacer()
                        Text(timeText(audio.duration))
                    }
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.5))
                }
                .padding(.top, 4)
            }
        }
        .padding(.top, 8)
    }

    private var controls: some View {
        HStack(spacing: 24) {
            FogHoldButton(client: model.client)

            VStack(spacing: 6) {
                Button {
                    stopShowAndClose()
                } label: {
                    Group {
                        if stopping {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 26, weight: .semibold))
                        }
                    }
                    .frame(width: 64, height: 64)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .tint(Theme.hot)
                .disabled(stopping)
                Text("Stop")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(.bottom, 30)
    }

    private var finishedCard: some View {
        GlassCard(padding: 22) {
            VStack(spacing: 14) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 38))
                    .foregroundStyle(Theme.good)
                Text("Show beendet")
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("Die Lichter sind aus, atlas ist bereit für die nächste Show.")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
                Button {
                    stopShowAndClose()
                } label: {
                    Text("Schließen")
                        .font(.system(size: 16, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.glassProminent)
                .tint(Theme.good)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.bottom, 30)
    }

    private func stopShowAndClose() {
        guard !stopping else { return }
        stopping = true
        audio.stop()
        Task {
            try? await model.client.stopShow()
            await model.load()
            dismiss()
        }
    }

    private func timeText(_ t: TimeInterval) -> String {
        let s = Int(t.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Lock-screen-style pulsating gradient hugging the display edges,
/// breathing with the audio level.
struct EdgeGlow: View {
    var buffer: BandBuffer

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let level = CGFloat(buffer.level())
            let breathe = 0.5 + 0.5 * sin(t * 1.6)          // slow idle pulse
            let strength = 0.25 + 0.18 * breathe + level * 0.8
            let width = 10 + breathe * 6 + level * 26

            let gradient = AngularGradient(
                colors: [
                    Color(red: 1.00, green: 0.42, blue: 0.62),
                    Color(red: 0.62, green: 0.40, blue: 1.00),
                    Color(red: 0.25, green: 0.60, blue: 1.00),
                    Color(red: 0.30, green: 0.90, blue: 0.95),
                    Color(red: 1.00, green: 0.65, blue: 0.35),
                    Color(red: 1.00, green: 0.42, blue: 0.62),
                ],
                center: .center,
                angle: .degrees(t * 14)                      // slow color drift
            )

            ZStack {
                RoundedRectangle(cornerRadius: 58, style: .continuous)
                    .strokeBorder(gradient, lineWidth: width)
                    .blur(radius: 22)
                RoundedRectangle(cornerRadius: 58, style: .continuous)
                    .strokeBorder(gradient, lineWidth: width * 0.35)
                    .blur(radius: 5)
            }
            .opacity(strength)
            .ignoresSafeArea()
        }
    }
}

/// Hold-to-fog, fail-safe edition: while the finger is down the app renews a
/// SHORT fog window (1.5 s) every 0.5 s instead of opening one long 30 s
/// window. If the release packet gets lost, the phone dies or the app is
/// killed mid-press, fog stops on its own within ~1.5 s. Release additionally
/// sends two explicit stops.
struct FogHoldButton: View {
    var client: AtlasClient
    @State private var fogging = false
    @State private var heartbeat: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "smoke.fill")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(fogging ? Color.black : Theme.accent)
                .frame(width: 64, height: 64)
                .glassEffect(fogging ? .regular.tint(Theme.accent) : .regular, in: .circle)
                .scaleEffect(fogging ? 1.08 : 1)
                .animation(.smooth(duration: 0.15), value: fogging)
            Text(fogging ? "NEBEL" : "halten für Nebel")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in press() }
                .onEnded { _ in release() }
        )
        .onDisappear { release() }
    }

    private func press() {
        guard !fogging else { return }
        fogging = true
        heartbeat?.cancel()
        let client = client
        heartbeat = Task {
            while !Task.isCancelled {
                try? await client.fog(ms: 1500)
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func release() {
        guard fogging else { return }
        fogging = false
        heartbeat?.cancel()
        heartbeat = nil
        let client = client
        Task {
            try? await client.fogStop()
            try? await Task.sleep(for: .milliseconds(150))
            try? await client.fogStop()
        }
    }
}
