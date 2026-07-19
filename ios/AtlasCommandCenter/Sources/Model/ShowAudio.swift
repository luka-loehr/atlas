import Foundation
import AVFoundation
import Accelerate
import Observation

/// Thread-safe hand-off of the current frequency bands from the audio render
/// thread to the SceneKit render loop.
final class BandBuffer: @unchecked Sendable {
    private var vals: [Float]
    private var lvl: Float = 0
    private let lock = NSLock()
    init(count: Int) { vals = [Float](repeating: 0, count: count) }
    func set(_ v: [Float], level: Float) {
        lock.lock(); vals = v; lvl = level; lock.unlock()
    }
    func bands() -> [Float] { lock.lock(); defer { lock.unlock() }; return vals }
    func level() -> Float { lock.lock(); defer { lock.unlock() }; return lvl }
}

/// Plays a show's audio ON THE PHONE and exposes live FFT bands for the
/// 3D visualizer. The lights run in sync on atlas.
@MainActor
@Observable
final class ShowAudio {
    nonisolated static let bandCount = 12

    let buffer = BandBuffer(count: bandCount)
    var isPlaying = false
    var loading = false
    var finished = false
    var error: String?
    var duration: TimeInterval = 0
    var currentTime: TimeInterval = 0

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let fft = FFTAnalyzer(size: 1024)
    private var attached = false
    private var progressTask: Task<Void, Never>?

    /// Download the show's audio, then play it while feeding the visualizer.
    func play(url: URL) async {
        stop()
        loading = true
        finished = false
        error = nil
        do {
            let (tmp, _) = try await URLSession.shared.download(from: url)
            let local = FileManager.default.temporaryDirectory
                .appendingPathComponent("atlas-show.\(url.pathExtension.isEmpty ? "mp3" : url.pathExtension)")
            try? FileManager.default.removeItem(at: local)
            try FileManager.default.moveItem(at: tmp, to: local)
            try start(file: local)
            loading = false
            isPlaying = true
        } catch {
            loading = false
            self.error = "Audio konnte nicht geladen werden"
        }
    }

    private func start(file url: URL) throws {
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try AVAudioSession.sharedInstance().setActive(true)

        let f = try AVAudioFile(forReading: url)
        duration = Double(f.length) / f.processingFormat.sampleRate
        currentTime = 0
        if !attached {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: f.processingFormat)
            attached = true
        }
        let mixer = engine.mainMixerNode
        mixer.removeTap(onBus: 0)
        mixer.installTap(onBus: 0, bufferSize: 1024, format: mixer.outputFormat(forBus: 0)) { [weak self] buf, _ in
            self?.analyze(buf)
        }
        engine.prepare()
        try engine.start()
        player.scheduleFile(f, at: nil) { [weak self] in
            Task { @MainActor in self?.finish() }
        }
        player.play()
        startProgress()
    }

    /// Host-clock time (CACurrentMediaTime frame) at which song position 0
    /// actually leaves the speaker — includes the output latency (AirPods!).
    /// Only valid while playing.
    func songZeroHostSeconds() -> Double? {
        guard let nt = player.lastRenderTime, nt.isHostTimeValid,
              let pt = player.playerTime(forNodeTime: nt) else { return nil }
        let nowHost = AVAudioTime.seconds(forHostTime: nt.hostTime)
        let songNow = Double(pt.sampleTime) / pt.sampleRate
        let outLat = AVAudioSession.sharedInstance().outputLatency
        return nowHost - songNow + outLat
    }

    private func startProgress() {
        progressTask?.cancel()
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.isPlaying || self.loading else { break }
                if let nt = self.player.lastRenderTime,
                   let pt = self.player.playerTime(forNodeTime: nt) {
                    self.currentTime = min(Double(pt.sampleTime) / pt.sampleRate, self.duration)
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func finish() {
        isPlaying = false
        finished = true
        currentTime = duration
        progressTask?.cancel()
        buffer.set([Float](repeating: 0, count: Self.bandCount), level: 0)
    }

    func stop() {
        progressTask?.cancel()
        if player.isPlaying { player.stop() }
        engine.mainMixerNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        isPlaying = false
        buffer.set([Float](repeating: 0, count: Self.bandCount), level: 0)
    }

    /// Runs on the audio render thread — keep it allocation-light.
    private nonisolated func analyze(_ buf: AVAudioPCMBuffer) {
        guard let ch = buf.floatChannelData?[0] else { return }
        let n = Int(buf.frameLength)
        let mags = fft.magnitudes(ch, count: n)
        guard !mags.isEmpty else { return }

        // log-spaced bands over the spectrum
        let count = Self.bandCount
        var bands = [Float](repeating: 0, count: count)
        let bins = mags.count
        for i in 0..<count {
            let lo = Int(powf(Float(bins), Float(i) / Float(count)))
            let hi = max(lo + 1, Int(powf(Float(bins), Float(i + 1) / Float(count))))
            var sum: Float = 0
            var c = 0
            var j = lo
            while j < min(hi, bins) { sum += mags[j]; c += 1; j += 1 }
            let avg = c > 0 ? sum / Float(c) : 0
            // compress + normalize into a lively 0…1
            bands[i] = min(1, sqrtf(avg) * 2.2)
        }
        let level = min(1, bands.reduce(0, +) / Float(count) * 1.6)
        buffer.set(bands, level: level)
    }
}

/// Minimal real-FFT magnitude helper on top of Accelerate.
final class FFTAnalyzer: @unchecked Sendable {
    private let size: Int
    private let half: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private var window: [Float]

    init(size: Int = 1024) {
        self.size = size
        self.half = size / 2
        self.log2n = vDSP_Length(log2(Float(size)))
        self.setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        self.window = [Float](repeating: 0, count: size)
        vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_NORM))
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// Magnitudes for the first `size` samples of `samples` (0 if fewer).
    func magnitudes(_ samples: UnsafePointer<Float>, count: Int) -> [Float] {
        var windowed = [Float](repeating: 0, count: size)
        let usable = min(count, size)
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(usable))

        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var mags = [Float](repeating: 0, count: half)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
                        vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(half))
            }
        }
        var scaled = [Float](repeating: 0, count: half)
        var scale: Float = 1.0 / Float(size)
        vDSP_vsmul(mags, 1, &scale, &scaled, 1, vDSP_Length(half))
        return scaled
    }
}
