import SwiftUI
import UIKit
import AVFoundation

/// Which photo the viewer shows. The pager keeps its neighbours alive (and
/// builds the next one while a swipe is still under way), so a video only
/// plays while it is the one on screen.
@MainActor
enum ViewerNow {
    private(set) static var id: String?
    static let changed = Notification.Name("atlas.viewerNow")
    static func show(_ id: String?) {
        guard id != self.id else { return }
        self.id = id
        NotificationCenter.default.post(name: changed, object: nil)
    }
}

/// Custom video surface — NO native AVKit controls. A tap anywhere toggles the
/// viewer chrome exactly like on photos; play/pause + scrubber are our own
/// Liquid-Glass controls and appear/disappear WITH the chrome (so share/trash,
/// the filmstrip and the video controls always hide together).
struct ViewerVideo: View {
    let id: String
    let url: URL?
    var poster: URL?
    var chrome: Bool
    var bottomInset: CGFloat = 150
    var onTap: () -> Void

    @State private var player: AVPlayer?
    @State private var timeObs: Any?
    @State private var endObs: Any?
    @State private var statusObs: NSKeyValueObservation?
    @State private var playing = false
    @State private var current: Double = 0
    @State private var duration: Double = 0
    @State private var scrubbing = false

    @State private var muted = false

    var body: some View {
        ZStack {
            // the poster (cached from the grid) under the player: it shows
            // through until the first frame is there, never an empty black box
            Thumb(url: poster)
                .aspectRatio(contentMode: .fit)
            if let player {
                PlayerLayerView(player: player)
                    .ignoresSafeArea()
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        // Apple-style compact control pill: [play/pause | thin progress | mute]
        // — sits above the filmstrip block, capped width so landscape stays sane
        .overlay(alignment: .bottom) {
            if chrome, player != nil {
                controlBar
                    .frame(maxWidth: 560)
                    .padding(.horizontal, 29)
                    .padding(.bottom, bottomInset)
            }
        }
        .task { await setup() }
        .onReceive(NotificationCenter.default.publisher(for: ViewerNow.changed)) { _ in
            guard let player else { return }
            if ViewerNow.id == id {
                // swiped back to it: carry on like Photos does
                if !playing, duration <= 0 || current < duration - 0.05 {
                    PlaybackAudio.activate()
                    player.play()
                    playing = true
                }
            } else if playing {
                player.pause()
                playing = false
            }
        }
        .onDisappear { teardown() }
    }

    /// Photos-style control bar: one slim glass capsule with play/pause, a
    /// thin progress track and the speaker, right above the filmstrip.
    private var controlBar: some View {
        HStack(spacing: 12) {
            Button { togglePlay() } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.primary)
                    .frame(width: 18, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playing ? "Pause" : "Play")
            progressBar
            Button {
                muted.toggle()
                player?.isMuted = muted
            } label: {
                Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.3.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 26, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(muted ? "Unmute" : "Mute")
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
        .glassEffect(.regular, in: .capsule)      // iOS 26 Liquid Glass
    }

    /// Thin track, filled to the playback position; drag anywhere on it to seek.
    private var progressBar: some View {
        GeometryReader { geo in
            let f = duration > 0 ? min(max(current / duration, 0), 1) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.5))
                Capsule().fill(.primary).frame(width: geo.size.width * f)
            }
            .frame(height: scrubbing ? 10 : 7)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        scrubbing = true
                        current = Double(min(max(v.location.x / max(geo.size.width, 1), 0), 1)) * duration
                        player?.seek(to: CMTime(seconds: current, preferredTimescale: 600),
                                     toleranceBefore: .zero, toleranceAfter: .zero)
                    }
                    .onEnded { _ in scrubbing = false }
            )
            .animation(.snappy(duration: 0.2), value: scrubbing)
        }
        .frame(height: 44)
        .accessibilityElement()
        .accessibilityLabel("Playback Position")
        .accessibilityValue("\(Int(current)) of \(Int(duration)) seconds")
        .accessibilityAdjustableAction { dir in
            current = min(max(current + (dir == .increment ? 5 : -5), 0), duration)
            player?.seek(to: CMTime(seconds: current, preferredTimescale: 600))
        }
    }

    private func togglePlay() {
        guard let player else { return }
        if playing {
            player.pause()
        } else {
            if duration > 0, current >= duration - 0.05 {   // replay from start
                player.seek(to: .zero)
                current = 0
            }
            PlaybackAudio.activate()
            player.play()
        }
        playing.toggle()
    }

    @MainActor
    private func setup() async {
        guard player == nil, let url else { return }
        // through the media cache: its first seconds are usually on the
        // phone already (the viewer fetches them ahead), the rest streams
        let item = AVPlayerItem(asset: VideoCache.shared.asset(id: id, remote: url))
        let p = AVPlayer(playerItem: item)
        p.isMuted = false
        player = p
        // should the cached path fail, the player streams straight from the
        // server as it always did
        statusObs = item.observe(\.status) { [weak p] item, _ in
            guard item.status == .failed else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let p, p.currentItem === item else { return }
                    MediaCache.log.error("video \(id, privacy: .public) via cache failed: \(item.error?.localizedDescription ?? "", privacy: .public); streaming directly")
                    // AVURLAsset options carry the optional bearer token to the stream endpoint
                    p.replaceCurrentItem(with: AVPlayerItem(asset: AVURLAsset(url: url, options: AtlasAuth.avAssetOptions)))
                    if ViewerNow.id == id { p.play() }
                }
            }
        }
        // a page built ahead of a swipe waits until it is on screen
        if ViewerNow.id == id {
            // sound even with the ringer on silent (like Photos); only now,
            // when it plays: a video built ahead of a swipe leaves music alone
            PlaybackAudio.activate()
            p.play()
            playing = true
        }

        timeObs = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
                                            queue: .main) { [weak p] t in
            MainActor.assumeIsolated {
                guard let p else { return }
                if !scrubbing { current = t.seconds }
                if duration <= 0, let d = p.currentItem?.duration.seconds,
                   d.isFinite, d > 0 { duration = d }
            }
        }
        endObs = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: nil, queue: .main) { [weak p] note in
            MainActor.assumeIsolated {
                if let p, (note.object as? AVPlayerItem) === p.currentItem { playing = false }
            }
        }
    }

    /// Full teardown so every swiped-past video releases its AVPlayer +
    /// observers + decode buffers instead of leaking across the session.
    private func teardown() {
        if let t = timeObs { player?.removeTimeObserver(t); timeObs = nil }
        if let e = endObs { NotificationCenter.default.removeObserver(e); endObs = nil }
        statusObs?.invalidate()
        statusObs = nil
        player?.pause()
        player = nil
        playing = false
    }
}

/// Bare AVPlayerLayer host (aspect-fit, no controls).
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    final class V: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> V {
        let v = V()
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspect
        return v
    }

    func updateUIView(_ v: V, context: Context) {
        if v.playerLayer.player !== player { v.playerLayer.player = player }
    }
}

/// The audio session for video playback, set up once, off the main thread.
/// `setActive(true)` talks to the audio server and can block the caller for
/// hundreds of milliseconds; on the main thread that froze the swipe onto a
/// video (iOS reported a ~1 s hang).
enum PlaybackAudio {
    private static let queue = DispatchQueue(label: "atlas.audio", qos: .userInitiated)

    /// Cheap when the session is already active; the system may deactivate
    /// it while the app is in the background, so it is simply asked again.
    static func activate() {
        queue.async {
            let session = AVAudioSession.sharedInstance()
            if session.category != .playback { try? session.setCategory(.playback, mode: .moviePlayback) }
            try? session.setActive(true)
        }
    }

    /// Gives the audio back: other apps' audio (music the video interrupted)
    /// is told it may resume.
    static func deactivate() {
        queue.async {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}
