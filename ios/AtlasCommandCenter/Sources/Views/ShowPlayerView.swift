import SwiftUI

struct ShowPlayerView: View {
    var model: ShowModel
    var show: Show

    @State private var audio = ShowAudio()
    @State private var fogging = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VisualizerView(buffer: audio.buffer, bandCount: ShowAudio.bandCount)
                .ignoresSafeArea()

            VStack {
                // header
                VStack(spacing: 4) {
                    Text(show.title)
                        .font(.system(size: 20, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Circle().fill(Theme.hot).frame(width: 7, height: 7)
                        Text(audio.loading ? "lädt Song …" : "LIVE · Lichter auf atlas · Sound am iPhone")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                .padding(.top, 8)

                Spacer()

                // fog + stop controls
                HStack(spacing: 20) {
                    fogButton
                    stopButton
                }
                .padding(.bottom, 30)
            }
            .padding(.horizontal, 20)
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .task {
            if let url = model.client.audioURL(show.name) {
                await audio.play(url: url)
            }
            try? await model.client.startShow(show.name)
        }
        .onDisappear {
            audio.stop()
            Task { try? await model.client.stopShow() }
        }
    }

    private var fogButton: some View {
        VStack(spacing: 6) {
            Image(systemName: "smoke.fill")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(fogging ? .white : Theme.accent)
                .frame(width: 96, height: 96)
                .background(
                    Circle().fill(fogging ? Theme.accent : Color.white.opacity(0.06))
                )
                .overlay(Circle().stroke(Theme.accent.opacity(0.5), lineWidth: 2))
                .scaleEffect(fogging ? 1.08 : 1)
                .animation(.smooth(duration: 0.15), value: fogging)
            Text(fogging ? "NEBEL" : "halten für Nebel")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !fogging {
                        fogging = true
                        Task { try? await model.client.fog(ms: 20_000) }
                    }
                }
                .onEnded { _ in
                    fogging = false
                    Task { try? await model.client.fogStop() }
                }
        )
    }

    private var stopButton: some View {
        VStack(spacing: 6) {
            Image(systemName: "stop.fill")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 96, height: 96)
                .background(Circle().fill(Theme.hot.opacity(0.85)))
            Text("Stop")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
        }
        .onTapGesture {
            audio.stop()
            Task { try? await model.client.stopShow() }
            dismiss()
        }
    }
}
