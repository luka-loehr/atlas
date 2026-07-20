import SwiftUI
import UIKit
import AVKit

/// Full-screen viewer, Google-Photos style.
///
/// Two modes, toggled by tapping the photo:
///   • CHROME    — system background; top bar (round back button, pill
///                 with relative date + time, ⋯ menu), bottom filmstrip of
///                 neighbors and the action bar (share ○ | ♥ ⓘ ⧉ pill | 🗑 ○).
///   • IMMERSIVE — pure black, nothing but the image.
///
/// Paging is a UIPageViewController (PhotoPager): one swipe = exactly one
/// photo, it can never rest between two pages. Swipe-down still dismisses via
/// the zoom transition.
struct ViewerScreen: View {
    var library: Library
    var assets: [Asset]
    var start: Asset

    @Environment(\.dismiss) private var dismiss
    @State private var pages: [Asset] = []
    @State private var index: Int = 0
    @State private var chrome = true
    @State private var infoAsset: Asset?
    @State private var shareBundle: ShareBundle?
    @State private var confirmTrash = false
    @State private var favorites: [String: Bool] = [:]   // optimistic overrides
    @State private var busy = false

    var body: some View {
        ZStack {
            (chrome ? Color(uiColor: .systemBackground) : .black)
                .ignoresSafeArea()

            if !pages.isEmpty {
                PhotoPager(index: $index, count: pages.count) { i in
                    ViewerPage(library: library, asset: pages[i], chrome: chrome) {
                        withAnimation(.easeInOut(duration: 0.22)) { chrome.toggle() }
                    }
                }
                .ignoresSafeArea()
            }

            if chrome, let asset = pages[safe: index] {
                chromeOverlay(asset)
                    .transition(.opacity)
            }

            if busy {
                ProgressView().tint(chrome ? nil : Color.white).padding(18)
                    .glassEffect(.regular, in: .rect(cornerRadius: 14))
            }
        }
        .statusBarHidden(!chrome)
        .preferredColorScheme(chrome ? nil : .dark)
        .onAppear {
            pages = assets
            index = assets.firstIndex(of: start) ?? 0
            prefetchNeighbors(of: index)
        }
        .onChange(of: index) { _, new in prefetchNeighbors(of: new) }
        .sheet(item: $infoAsset) { a in
            InfoSheet(library: library, asset: a)
                .presentationDetents([.medium, .large])
        }
        .sheet(item: $shareBundle) { b in
            ShareSheet(items: b.urls).presentationDetents([.medium, .large])
        }
        .confirmationDialog("In den Papierkorb?", isPresented: $confirmTrash,
                            titleVisibility: .visible) {
            Button("In Papierkorb", role: .destructive) { trashCurrent() }
            Button("Abbrechen", role: .cancel) {}
        }
    }

    // MARK: - Chrome (Google-Photos layout)

    @ViewBuilder
    private func chromeOverlay(_ asset: Asset) -> some View {
        VStack(spacing: 0) {
            topBar(asset)
            Spacer()
            VStack(spacing: 14) {
                Filmstrip(assets: pages, index: $index, client: library.client)
                bottomBar(asset)
            }
            .padding(.bottom, 6)
        }
    }

    private func topBar(_ asset: Asset) -> some View {
        HStack(alignment: .center) {
            CircleButton(icon: "chevron.backward") { dismiss() }
            Spacer()
            VStack(spacing: 1) {
                Text(relativeDay(asset.takenAt))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                if let t = asset.takenAt {
                    Text(t.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 7)
            .glassEffect(.regular, in: .capsule)      // iOS 26 Liquid Glass
            Spacer()
            Menu {
                Button {
                    mutateAndRemove { try await library.client.archive([$0], true) }
                } label: { Label("Archivieren", systemImage: "archivebox") }
                Button {
                    mutateAndRemove { try await library.client.lock([$0], true) }
                } label: { Label("In gesperrten Ordner", systemImage: "lock") }
                Button { infoAsset = asset } label: {
                    Label("Details", systemImage: "info.circle")
                }
            } label: {
                CircleButton(icon: "ellipsis") {}.allowsHitTesting(false)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
    }

    private func bottomBar(_ asset: Asset) -> some View {
        HStack {
            CircleButton(icon: "square.and.arrow.up") { shareCurrent() }
            Spacer()
            HStack(spacing: 34) {
                Button { toggleFavorite(asset) } label: {
                    Image(systemName: isFav(asset) ? "heart.fill" : "heart")
                        .font(.system(size: 20))
                        .foregroundStyle(isFav(asset) ? .red : .primary)
                }
                Button { infoAsset = asset } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 20)).foregroundStyle(.primary)
                }
                Button {
                    mutateAndRemove { try await library.client.archive([$0], true) }
                } label: {
                    Image(systemName: "archivebox")
                        .font(.system(size: 20)).foregroundStyle(.primary)
                }
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 15)
            .glassEffect(.regular, in: .capsule)      // iOS 26 Liquid Glass
            Spacer()
            CircleButton(icon: "trash") { confirmTrash = true }
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Actions

    private func isFav(_ a: Asset) -> Bool { favorites[a.id] ?? a.isFavorite }

    private func toggleFavorite(_ a: Asset) {
        let new = !isFav(a)
        favorites[a.id] = new                       // optimistic
        Task { try? await library.client.favorite([a.id], new) }
    }

    private func shareCurrent() {
        guard let a = pages[safe: index],
              let src = library.client.originalURL(a.id) else { return }
        busy = true
        Task {
            defer { busy = false }
            if let (tmp, resp) = try? await URLSession.shared.download(from: src) {
                let ext = (resp.suggestedFilename as NSString?)?.pathExtension
                let dest = FileManager.default.temporaryDirectory
                    .appendingPathComponent("\(a.id).\(ext?.isEmpty == false ? ext! : "jpg")")
                try? FileManager.default.removeItem(at: dest)
                if (try? FileManager.default.moveItem(at: tmp, to: dest)) != nil {
                    shareBundle = ShareBundle(urls: [dest])
                }
            }
        }
    }

    private func trashCurrent() {
        mutateAndRemove { try await library.client.trash([$0]) }
    }

    /// Run a single-asset mutation, drop the asset from the pager + grid, and
    /// advance to the next photo (dismiss when it was the last one).
    private func mutateAndRemove(_ op: @escaping (String) async throws -> Void) {
        guard let a = pages[safe: index] else { return }
        busy = true
        Task {
            defer { busy = false }
            do { try await op(a.id) } catch { return }
            library.removeLocally([a.id])
            await library.loadStats()
            if pages.count <= 1 {
                dismiss()
            } else {
                var next = pages
                next.remove(at: index)
                let newIndex = min(index, next.count - 1)
                pages = next
                index = newIndex
            }
        }
    }

    private func relativeDay(_ d: Date?) -> String {
        guard let d else { return "—" }
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Heute" }
        if cal.isDateInYesterday(d) { return "Gestern" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = cal.isDate(d, equalTo: Date(), toGranularity: .year)
            ? "d. MMM" : "d. MMM yyyy"
        return f.string(from: d)
    }

    /// Warms the 2048 previews of the neighboring pages (±1..3, nearest first)
    /// so the next swipe shows a sharp image instantly.
    private func prefetchNeighbors(of i: Int) {
        var urls: [URL] = []
        for offset in 1...3 {
            for j in [i + offset, i - offset] {
                guard let a = pages[safe: j], !a.isVideo,
                      let u = library.client.thumbURL(a.id, 2048) else { continue }
                urls.append(u)
            }
        }
        ThumbLoader.shared.prefetch(urls)
    }
}

/// Round floating button (system-background circle, primary icon) — Google-Photos chrome.
struct CircleButton: View {
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .glassEffect(.regular, in: .circle)   // iOS 26 Liquid Glass
        }
    }
}

/// Horizontal strip of neighbor thumbnails; tap jumps, current is highlighted.
/// Centered snap-scrubber, camera-lens style: a FIXED ring sits in the middle
/// and never moves — the thumbs scroll underneath it, snap thumb-by-thumb and
/// grow as they pass under the ring (geometry-driven, not index-driven, so
/// nothing ever jumps sideways). Every detent click gives haptic feedback.
private struct Filmstrip: View {
    let assets: [Asset]
    @Binding var index: Int
    let client: PhotoClient
    @State private var pos: Int?

    private let cell: CGFloat = 50
    private let gap: CGFloat = 4

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: gap) {
                ForEach(Array(assets.enumerated()), id: \.offset) { i, a in
                    Thumb(url: client.thumbURL(a.id, 512))
                        .frame(width: cell, height: cell)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        // grow smoothly while passing under the fixed ring —
                        // pure geometry, follows the finger with zero lag
                        .visualEffect { content, proxy in
                            let mid = proxy.frame(in: .scrollView(axis: .horizontal)).midX
                            let center = UIScreen.main.bounds.width / 2
                            let d = abs(mid - center)
                            let scale = 1 + 0.22 * max(0, 1 - d / 70)
                            return content.scaleEffect(scale)
                        }
                        .id(i)
                        .onTapGesture { index = i }
                }
            }
            .scrollTargetLayout()
            .frame(height: 70)
        }
        // margins so the first/last thumb can also rest dead-center
        .contentMargins(.horizontal,
                        (UIScreen.main.bounds.width - cell) / 2,
                        for: .scrollContent)
        .scrollPosition(id: $pos, anchor: .center)
        .scrollTargetBehavior(.viewAligned)   // snaps thumb-by-thumb
        // THE ring: fixed dead-center, thumbs move — it never does
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(.primary.opacity(0.9), lineWidth: 2)
                .frame(width: cell + 10, height: cell + 10)
                .allowsHitTesting(false)
        }
        .frame(height: 70)
        // mechanical lens-click on every detent (scrub AND page swipe)
        .sensoryFeedback(.selection, trigger: index)
        .onAppear { pos = index }
        .onChange(of: index) { _, i in
            if pos != i { withAnimation(.snappy) { pos = i } }
        }
        .onChange(of: pos) { _, p in
            if let p, p != index { index = p }   // user scrubbed the strip
        }
    }
}

private struct ViewerPage: View {
    var library: Library
    var asset: Asset
    var chrome: Bool
    var onTap: () -> Void

    var body: some View {
        if asset.isVideo {
            VideoPlayerView(url: library.client.streamURL(asset.id),
                            chrome: chrome, onTap: onTap)
        } else {
            ZoomablePhoto(
                preview: library.client.thumbURL(asset.id, 2048),
                full: library.client.originalURL(asset.id),
                onTap: onTap
            )
        }
    }
}

/// Loads the 2048 preview instantly (cached from the grid), swaps in the
/// downsampled original, then hosts it in a UIScrollView for zoom. At zoom 1
/// the scroll view doesn't consume drags, so the pager (horizontal) and the
/// zoom-transition dismiss (down) keep working — exactly like Apple Photos.
private struct ZoomablePhoto: View {
    let preview: URL?
    let full: URL?
    var onTap: () -> Void = {}
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                ZoomableScrollView(image: { image }, onSingleTap: onTap)
            } else {
                Thumb(url: preview)
                    .aspectRatio(contentMode: .fit)
                    .contentShape(Rectangle())
                    .onTapGesture { onTap() }
            }
        }
        .task(id: full) {
            // instant: the 2048 preview (decoded off-main, quick)
            if image == nil, let p = preview, let img = await ThumbLoader.shared.load(p) {
                if image == nil { image = img }
            }
            // then the original, downsampled + decoded off-main so the swipe
            // between photos never stalls on a full-resolution main-thread decode
            if let f = full, let img = await ThumbLoader.shared.loadFull(f, maxPixel: 2800) {
                image = img
            }
        }
    }
}

/// UIScrollView-backed pinch/pan/double-tap zoom for one image.
/// Single tap (only fires when the double-tap fails) toggles the chrome.
private struct ZoomableScrollView: UIViewRepresentable {
    let image: UIImage
    var onSingleTap: () -> Void = {}
    init(image: () -> UIImage, onSingleTap: @escaping () -> Void = {}) {
        self.image = image()
        self.onSingleTap = onSingleTap
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.delegate = context.coordinator
        scroll.maximumZoomScale = 5
        scroll.minimumZoomScale = 1
        scroll.bounces = false                     // don't eat drags at zoom 1
        scroll.alwaysBounceVertical = false
        scroll.alwaysBounceHorizontal = false
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.backgroundColor = .clear
        scroll.contentInsetAdjustmentBehavior = .never

        let iv = context.coordinator.imageView
        iv.image = image
        iv.contentMode = .scaleAspectFit
        iv.frame = scroll.bounds
        iv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scroll.addSubview(iv)

        let dt = UITapGestureRecognizer(target: context.coordinator,
                                        action: #selector(Coordinator.doubleTap(_:)))
        dt.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(dt)

        let st = UITapGestureRecognizer(target: context.coordinator,
                                        action: #selector(Coordinator.singleTap(_:)))
        st.numberOfTapsRequired = 1
        st.require(toFail: dt)
        scroll.addGestureRecognizer(st)

        context.coordinator.onSingleTap = onSingleTap
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        context.coordinator.imageView.image = image
        context.coordinator.onSingleTap = onSingleTap
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        let imageView = UIImageView()
        var onSingleTap: () -> Void = {}

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        @objc func singleTap(_ g: UITapGestureRecognizer) { onSingleTap() }

        @objc func doubleTap(_ g: UITapGestureRecognizer) {
            guard let scroll = g.view as? UIScrollView else { return }
            if scroll.zoomScale > 1 {
                scroll.setZoomScale(1, animated: true)
            } else {
                let pt = g.location(in: imageView)
                let size = scroll.bounds.size
                let rect = CGRect(x: pt.x - size.width / 6, y: pt.y - size.height / 6,
                                  width: size.width / 3, height: size.height / 3)
                scroll.zoom(to: rect, animated: true)
            }
        }
    }
}

/// Custom video surface — NO native AVKit controls. A tap anywhere toggles the
/// viewer chrome exactly like on photos; play/pause + scrubber are our own
/// Liquid-Glass controls and appear/disappear WITH the chrome (so share/trash,
/// the filmstrip and the video controls always hide together).
private struct VideoPlayerView: View {
    let url: URL?
    var chrome: Bool
    var onTap: () -> Void

    @State private var player: AVPlayer?
    @State private var playing = false
    @State private var current: Double = 0
    @State private var duration: Double = 0
    @State private var scrubbing = false

    var body: some View {
        ZStack {
            if let player {
                PlayerLayerView(player: player)
                    .ignoresSafeArea()
            } else {
                ProgressView()
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .overlay {                                   // center play/pause
            if chrome, player != nil {
                Button { togglePlay() } label: {
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(.primary)
                        .frame(width: 64, height: 64)
                        .glassEffect(.regular, in: .circle)
                }
                .transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) {               // scrubber above filmstrip block
            if chrome, player != nil, duration > 0 {
                HStack(spacing: 10) {
                    Text(fmt(current))
                        .font(.system(size: 11, weight: .medium)).monospacedDigit()
                        .foregroundStyle(.secondary)
                    Slider(
                        value: Binding(get: { current },
                                       set: { current = $0 }),
                        in: 0...max(duration, 0.1)
                    ) { editing in
                        scrubbing = editing
                        if !editing {
                            player?.seek(to: CMTime(seconds: current, preferredTimescale: 600),
                                         toleranceBefore: .zero, toleranceAfter: .zero)
                        }
                    }
                    Text(fmt(duration))
                        .font(.system(size: 11, weight: .medium)).monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: .capsule)
                .padding(.horizontal, 22)
                .padding(.bottom, 160)   // clears filmstrip + action bar
                .transition(.opacity)
            }
        }
        .task { await setup() }
        .onDisappear { player?.pause(); playing = false }
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
            player.play()
        }
        playing.toggle()
    }

    @MainActor
    private func setup() async {
        guard player == nil, let url else { return }
        // play sound even with the ringer/Focus on silent (like Photos/YouTube)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        let p = AVPlayer(url: url)
        p.isMuted = false
        player = p
        p.play()
        playing = true

        p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
                                  queue: .main) { t in
            MainActor.assumeIsolated {
                if !scrubbing { current = t.seconds }
                if duration <= 0, let d = p.currentItem?.duration.seconds,
                   d.isFinite, d > 0 { duration = d }
            }
        }
        NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: p.currentItem, queue: .main) { _ in
            MainActor.assumeIsolated { playing = false }
        }
    }

    private func fmt(_ t: Double) -> String {
        guard t.isFinite else { return "0:00" }
        let s = Int(t.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Bare AVPlayerLayer host (aspect-fit, no controls).
private struct PlayerLayerView: UIViewRepresentable {
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

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
