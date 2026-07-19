import SwiftUI
import AVFoundation

/// Automatic latency calibration: atlas flashes the room white on a click
/// track the phone plays; the camera timestamps the flashes, the audio engine
/// timestamps the clicks (incl. output latency) — the median offset becomes
/// the calibrated audio_latency_ms for ALL shows ("smart shows").
struct CalibrationView: View {
    var model: ShowModel

    @State private var cal = CalibrationModel()
    @State private var audio = ShowAudio()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background
                VStack(spacing: 16) {
                    CameraPreview(session: cal.camera.session)
                        .frame(height: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .overlay(alignment: .topTrailing) {
                            Circle()
                                .fill(cal.flashSeen ? .white : Theme.hot.opacity(0.5))
                                .frame(width: 14, height: 14)
                                .padding(10)
                                .animation(.easeOut(duration: 0.2), value: cal.flashSeen)
                        }

                    switch cal.stage {
                    case .idle:
                        instructionCard
                    case .running:
                        runningCard
                    case .done(let ms, let samples):
                        resultCard(ms: ms, samples: samples)
                    case .failed(let why):
                        failedCard(why)
                    }
                    Spacer()
                }
                .padding(16)
            }
            .navigationTitle("Latenz-Kalibrierung")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { close() } label: { Image(systemName: "xmark") }
                }
            }
        }
        .preferredColorScheme(.dark)
        .task { await cal.camera.start() }
        .onDisappear { close(dismissing: false) }
    }

    private var instructionCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("So funktioniert's", systemImage: "camera.metering.center.weighted")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                Text("Richte die Kamera auf deine Lampen (Regal genügt). atlas blitzt 10× weiß, dein iPhone spielt dazu Klicks — genau wie bei einer echten Show. Die Kamera misst den Versatz; danach sitzt jede Show automatisch perfekt auf deinem Audio-Setup (AirPods, Speaker, egal).")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.6))
                Button {
                    Task { await run() }
                } label: {
                    Label("Kalibrierung starten", systemImage: "wand.and.rays")
                        .font(.system(size: 15, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.glassProminent)
                .tint(Theme.accent)
            }
        }
    }

    private var runningCard: some View {
        GlassCard {
            VStack(spacing: 10) {
                ProgressView(value: min(audio.currentTime, audio.duration),
                             total: max(audio.duration, 1))
                    .tint(Theme.accent)
                Text("Blitze erkannt: \(cal.flashCount) / 10")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .monoDigits()
                Text("nicht bewegen — läuft \(Int(max(0, audio.duration - audio.currentTime)))s")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    private func resultCard(ms: Double, samples: Int) -> some View {
        GlassCard {
            VStack(spacing: 12) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(Theme.good)
                Text(String(format: "%.0f ms", ms))
                    .font(.system(size: 40, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .monoDigits()
                Text("Audio-Latenz · Median aus \(samples) Blitzen")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
                Button {
                    Task {
                        try? await model.client.saveCalibration(ms: ms)
                        dismiss()
                    }
                } label: {
                    Text("Speichern — gilt für alle Shows")
                        .font(.system(size: 15, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.glassProminent)
                .tint(Theme.good)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func failedCard(_ why: String) -> some View {
        GlassCard {
            VStack(spacing: 10) {
                Label("Nicht genug Blitze erkannt", systemImage: "xmark.octagon.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.hot)
                Text(why)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.55))
                Button("Nochmal") { Task { await run() } }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.accent)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func run() async {
        cal.reset()
        // lights: the calibration show on atlas; audio: the click track here
        async let lights: () = { try? await model.client.startShow("calibration") }()
        guard let url = model.client.audioURL("calibration") else { return }
        cal.stage = .running
        await audio.play(url: url)
        await lights
        if let err = audio.error {
            cal.stage = .failed("Audio: \(err)")
            return
        }
        guard let zero = audio.songZeroHostSeconds() else {
            cal.stage = .failed("Audio-Anker fehlgeschlagen")
            return
        }
        cal.songZeroHost = zero
        // wait until the click track finished, then evaluate
        while !audio.finished && audio.error == nil {
            try? await Task.sleep(for: .milliseconds(300))
        }
        cal.evaluate()
    }

    private func close(dismissing: Bool = true) {
        audio.stop()
        cal.camera.stop()
        let client = model.client
        Task.detached { try? await client.stopShow() }
        if dismissing { dismiss() }
    }
}

// MARK: - measurement model

@MainActor
@Observable
final class CalibrationModel {
    enum Stage: Equatable {
        case idle, running
        case done(ms: Double, samples: Int)
        case failed(String)
    }

    static let clickTimes: [Double] = (0..<10).map { 1.0 + 2.0 * Double($0) }

    var stage: Stage = .idle
    var flashCount = 0
    var flashSeen = false
    var songZeroHost: Double = 0

    let camera = FlashCamera()

    func reset() {
        flashCount = 0
        camera.clearSamples()
        stage = .idle
    }

    /// Detect flash spikes in the luminance timeline, match them to the
    /// known click times, take the median offset.
    func evaluate() {
        let samples = camera.samples
        guard samples.count > 30 else {
            stage = .failed("Kamera lieferte zu wenig Bilder")
            return
        }
        // rising-edge spikes over a rolling baseline
        var spikes: [Double] = []
        var baseline = samples.prefix(15).map(\.lum).reduce(0, +) / 15
        var last = -1.0
        for s in samples {
            if s.lum > baseline + 24, s.t - last > 0.4 {
                spikes.append(s.t)
                last = s.t
            } else {
                baseline = baseline * 0.95 + s.lum * 0.05
            }
        }
        var deltas: [Double] = []
        for c in Self.clickTimes {
            let clickHost = songZeroHost + c
            if let hit = spikes.first(where: { $0 > clickHost - 0.25 && $0 < clickHost + 1.2 }) {
                deltas.append((hit - clickHost) * 1000)
            }
        }
        flashCount = deltas.count
        guard deltas.count >= 4 else {
            stage = .failed("Nur \(deltas.count)/10 Blitze zuordenbar — Kamera näher an die Lampen richten")
            return
        }
        let sorted = deltas.sorted()
        let median = sorted[sorted.count / 2]
        // negative = light BEFORE sound is the expected case; latency is how
        // long the lights must wait for the audio -> flip the sign
        let latency = max(0, -median)
        stage = .done(ms: latency, samples: deltas.count)
    }
}

// MARK: - camera

/// Continuously samples the camera's average luminance with host timestamps.
final class FlashCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    struct Sample { let t: Double; let lum: Double }

    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "cal.camera")
    private let lock = NSLock()
    private var _samples: [Sample] = []
    var samples: [Sample] { lock.lock(); defer { lock.unlock() }; return _samples }
    func clearSamples() { lock.lock(); _samples.removeAll(); lock.unlock() }

    var configured = false

    func start() async {
        guard await AVCaptureDevice.requestAccess(for: .video) else { return }
        queue.async { [self] in
            if !configured {
                configure()
                configured = true
            }
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    private func configure() {
        session.beginConfiguration()
        session.sessionPreset = .vga640x480
        guard let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: dev) else {
            session.commitConfiguration()
            return
        }
        session.addInput(input)
        // lock exposure so the flash registers as a clean spike
        try? dev.lockForConfiguration()
        if dev.isExposureModeSupported(.locked) { dev.exposureMode = .locked }
        dev.unlockForConfiguration()
        let out = AVCaptureVideoDataOutput()
        out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String:
                             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        out.alwaysDiscardsLateVideoFrames = true
        out.setSampleBufferDelegate(self, queue: queue)
        session.addOutput(out)
        session.commitConfiguration()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let px = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        CVPixelBufferLockBaseAddress(px, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(px, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(px, 0) else { return }
        let w = CVPixelBufferGetWidthOfPlane(px, 0)
        let h = CVPixelBufferGetHeightOfPlane(px, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(px, 0)
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        var sum = 0
        var count = 0
        var y = 0
        while y < h {
            var x = 0
            while x < w {
                sum += Int(ptr[y * stride + x])
                count += 1
                x += 12
            }
            y += 12
        }
        let lum = Double(sum) / Double(max(count, 1))
        lock.lock()
        _samples.append(Sample(t: CACurrentMediaTime(), lum: lum))
        lock.unlock()
    }
}

/// Live camera preview.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewUIView {
        let v = PreviewUIView()
        v.videoPreviewLayer.session = session
        v.videoPreviewLayer.videoGravity = .resizeAspectFill
        return v
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {}

    final class PreviewUIView: UIView {
        override static var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
