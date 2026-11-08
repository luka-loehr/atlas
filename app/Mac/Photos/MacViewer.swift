import SwiftUI
import AppKit
import AVKit

/// One photo or video at the size of the window, over the grid it was
/// opened from (Photos on the Mac does the same).
///
/// ← and → (or a two-finger swipe, or the arrows at the edges) step through
/// the photos; Esc or Back returns to the grid, on the photo last shown.
/// Photos zoom like in Preview: pinch, double-click, two-finger double-tap,
/// scroll to pan. Videos play in the system player, with its controls,
/// Picture in Picture and full screen.
struct MacViewer: View {
    var library: Library
    let assets: [Asset]
    @Binding var current: String?
    var onClose: () -> Void
    var onFavorite: () -> Void

    @FocusState private var focused: Bool
    @Environment(MacWindowState.self) private var window
    @State private var hovering = false
    /// A video page's player, for the space bar to play and pause.
    @State private var playing: AVPlayer?
    @State private var lastIndex = 0
    /// The page on screen. The viewer's own: a step redraws the viewer
    /// only. `current` (the browser's, for its title and toolbar) follows
    /// at once after a single step; while steps come faster than 150 ms
    /// apart, it skips the pages in between and catches up 120 ms after
    /// the last, so holding an arrow never queues work for the window.
    @State private var shown: String?
    @State private var shownIndex: Int?
    @State private var lastStep = Date.distantPast
    @State private var catchUp: Task<Void, Never>?

    private var index: Int? { shownIndex }

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
            if let index, let asset = assets[safe: index] {
                Group {
                    if asset.isVideo {
                        MacVideoPage(library: library, asset: asset, onClick: toggleChrome, shared: $playing)
                    } else {
                        MacPhotoPage(library: library, asset: asset, onSwipe: step, onClick: toggleChrome)
                    }
                }
                // the next photo replaces this one at once, no fade
                .id(asset.id)
                .transition(.identity)
                edgeButtons(index)
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { show(current); focused = true; focusCache() }
        // opened on another photo, or a deleted photo left: follow the browser
        .onChange(of: current) { if current != shown && catchUp == nil { show(current); focusCache() } }
        .onChange(of: assets.count) { show(shown) }
        .onChange(of: shown) { focusCache() }
        .onKeyPress(.escape) { sync(); onClose(); return .handled }
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onKeyPress(.rightArrow) { step(1); return .handled }
        // space plays and pauses a video, and closes a photo (as before)
        .onKeyPress(.space) {
            if let player = playing, assets[safe: index ?? -1]?.isVideo == true {
                player.timeControlStatus == .paused ? player.resume() : player.pause()
            } else {
                sync()
                onClose()
            }
            return .handled
        }
        .onKeyPress(characters: ["."], phases: .down) { _ in sync(); onFavorite(); return .handled }
        .onHover { hovering = $0 }
        .accessibilityAction(named: "Next Photo") { step(1) }
        .accessibilityAction(named: "Previous Photo") { step(-1) }
    }

    /// Previous and next at the edges, while the pointer is over the photo.
    private func edgeButtons(_ index: Int) -> some View {
        HStack {
            edgeButton("chevron.backward", "Previous Photo", enabled: index > 0) { step(-1) }
            Spacer()
            edgeButton("chevron.forward", "Next Photo", enabled: index < assets.count - 1) { step(1) }
        }
        .padding(.horizontal, 16)
        .opacity(hovering && window.viewerChrome ? 1 : 0)
        .allowsHitTesting(window.viewerChrome)
    }

    private func edgeButton(_ symbol: String, _ label: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 36, height: 36)
                // the whole glass circle clicks, not only the chevron's pixels
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .opacity(enabled ? 1 : 0)
        .disabled(!enabled)
        .accessibilityLabel(label)
        .help(label)
    }

    private func step(_ delta: Int) {
        guard let index else { return }
        let next = index + delta
        guard let asset = assets[safe: next] else { NSSound.beep(); return }
        shown = asset.id
        shownIndex = next
        let now = Date()
        let rapid = now.timeIntervalSince(lastStep) < 0.15
        lastStep = now
        catchUp?.cancel()
        if rapid {
            catchUp = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                sync()
            }
        } else {
            sync()
        }
    }

    /// A click on the photo or video: every control around it hides, or
    /// comes back.
    private func toggleChrome() {
        // at once, no fade: as the iPhone's chrome
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { window.viewerChrome.toggle() }
    }

    /// The browser's photo becomes the one on screen.
    private func sync() {
        catchUp?.cancel()
        catchUp = nil
        if current != shown { current = shown }
    }

    private func show(_ id: String?) {
        shown = id
        shownIndex = id.flatMap { id in assets.firstIndex { $0.id == id } }
    }

    /// The pages around this one, downloaded and decoded ahead.
    private func focusCache() {
        guard let index else { return }
        MediaCache.shared.viewerFocus(assets, index: index, forward: index >= lastIndex)
        lastIndex = index
    }
}

// MARK: - Photo

/// A photo, in its first frame with the best image already on the Mac:
/// the preview the look-ahead decoded, else the thumbnail, else the grid's
/// tile. Nothing waits for a download: the sharp preview swaps in when it
/// is there, and the original only once the photo is zoomed in (fitted to
/// the window, the preview is as sharp as the screen).
private struct MacPhotoPage: View {
    var library: Library
    let asset: Asset
    var onSwipe: (Int) -> Void
    var onClick: () -> Void

    @State private var image: NSImage?
    @State private var zoomed = false

    init(library: Library, asset: Asset, onSwipe: @escaping (Int) -> Void, onClick: @escaping () -> Void) {
        self.library = library
        self.asset = asset
        self.onSwipe = onSwipe
        self.onClick = onClick
        let client = library.client
        _image = State(initialValue: client.thumbURL(asset.id, 2048).flatMap {
            MediaCache.shared.cached($0, maxPixel: MediaCache.viewerPixels(asset))
        })
    }

    var body: some View {
        ZStack {
            if let image {
                ZoomableImage(image: image, pixelSize: pixelSize, onSwipe: onSwipe, onZoomIn: { zoomed = true },
                              onClick: onClick)
            } else {
                InstantPoster(library: library, asset: asset)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onClick)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(asset.spokenDescription)
        .accessibilityAddTraits(.isImage)
        .task(id: asset.id) {
            guard image == nil, let preview = library.client.thumbURL(asset.id, 2048) else { return }
            if let img = await MediaCache.shared.loadFull(preview, maxPixel: MediaCache.viewerPixels(asset)),
               !Task.isCancelled {
                image = img
            }
        }
        .task(id: zoomed) {
            guard zoomed, let original = library.client.originalURL(asset.id) else { return }
            if let full = await MediaCache.shared.loadFull(original, maxPixel: 8192), !Task.isCancelled {
                image = full
            }
        }
    }

    /// The photo's own size, so 100 % shows its real pixels whichever image
    /// (preview or original) is on screen.
    private var pixelSize: CGSize {
        if let w = asset.width, let h = asset.height, w > 0, h > 0 { return CGSize(width: w, height: h) }
        return image.map { CGSize(width: $0.cgImage?.width ?? 1, height: $0.cgImage?.height ?? 1) } ?? CGSize(width: 4, height: 3)
    }
}

/// What stands in for a photo or a video until the real thing is there:
/// the 512 thumbnail when it is in memory, else the grid's own tile (on
/// the Mac for every photo), at the photo's shape. No spinner.
private struct InstantPoster: View {
    var library: Library
    let asset: Asset
    @State private var image: NSImage?

    init(library: Library, asset: Asset) {
        self.library = library
        self.asset = asset
        let tiles = GridTiles.shared
        let first = library.client.thumbURL(asset.id, 512).flatMap { MediaCache.shared.cached($0) }
            ?? (tiles.cachedSharp(asset.id) ?? tiles.mini(asset.id)).map { NSImage(cgImage: $0, size: .zero) }
        _image = State(initialValue: first)
    }

    var body: some View {
        Color.clear
            .aspectRatio(CGFloat(asset.width ?? 4) / CGFloat(max(asset.height ?? 3, 1)), contentMode: .fit)
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().interpolation(.medium).scaledToFill()
                }
            }
            .clipped()
            .task(id: asset.id) {
                guard let url = library.client.thumbURL(asset.id, 512) else { return }
                if MediaCache.shared.cached(url) != nil { return }
                if let img = await MediaCache.shared.load(url), !Task.isCancelled { image = img }
            }
    }
}

/// `NSScrollView` magnification around an image view: fit to the window by
/// default, up to 8 × its pixels, centred when smaller than the window.
private struct ZoomableImage: NSViewRepresentable {
    let image: NSImage
    let pixelSize: CGSize
    var onSwipe: (Int) -> Void
    var onZoomIn: () -> Void
    var onClick: () -> Void

    func makeNSView(context: Context) -> ZoomScrollView {
        let scroll = ZoomScrollView()
        scroll.onSwipe = onSwipe
        scroll.onZoomIn = onZoomIn
        scroll.onClick = onClick
        scroll.set(image: image, pixelSize: pixelSize)
        return scroll
    }

    func updateNSView(_ scroll: ZoomScrollView, context: Context) {
        scroll.onSwipe = onSwipe
        scroll.onZoomIn = onZoomIn
        scroll.onClick = onClick
        scroll.set(image: image, pixelSize: pixelSize)
    }
}

final class ZoomScrollView: NSScrollView {
    private let imageView = NSImageView()
    private var pixelSize: CGSize = .zero
    private var atFit = true
    var onSwipe: (Int) -> Void = { _ in }
    /// Zoomed in past the window's size: time for the original.
    var onZoomIn: () -> Void = {}
    /// A single click (not the first of a double click, which zooms).
    var onClick: () -> Void = {}
    private var downAt: NSPoint = .zero
    private var swipeX: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        contentView = CenteringClipView()
        // the viewer's frame is the photo's room: no room of its own for
        // the toolbar it floats under, so the photo is fitted and centred
        // in exactly what the viewer covers
        automaticallyAdjustsContentInsets = false
        contentInsets = NSEdgeInsetsZero
        drawsBackground = false
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        allowsMagnification = true
        imageView.imageScaling = .scaleAxesIndependently
        imageView.imageAlignment = .alignCenter
        imageView.animates = false
        documentView = imageView
        NotificationCenter.default.addObserver(self, selector: #selector(zoomEnded),
                                               name: NSScrollView.didEndLiveMagnifyNotification, object: self)
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(image: NSImage, pixelSize: CGSize) {
        if imageView.image !== image { imageView.image = image }
        guard self.pixelSize != pixelSize else { return }
        self.pixelSize = pixelSize
        // points = pixels / backing scale, so magnification 1 is 100 %
        let scale = window?.backingScaleFactor ?? 2
        imageView.frame = NSRect(origin: .zero, size: CGSize(width: pixelSize.width / scale, height: pixelSize.height / scale))
        atFit = true
        fit()
    }

    private var fitMagnification: CGFloat {
        let visible = contentView.frame.size, doc = imageView.frame.size
        guard doc.width > 0, doc.height > 0, visible.width > 0, visible.height > 0 else { return 1 }
        return min(visible.width / doc.width, visible.height / doc.height)
    }

    private func fit() {
        let f = fitMagnification
        minMagnification = min(f, 1)
        maxMagnification = max(8, f)
        magnification = f
    }

    override func layout() {
        super.layout()
        if atFit { fit() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let size = pixelSize
        pixelSize = .zero
        if size != .zero, let image = imageView.image { set(image: image, pixelSize: size) }
    }

    @objc private func zoomEnded() {
        atFit = magnification <= fitMagnification * 1.01
        if !atFit { onZoomIn() }
    }

    /// Double-click: 100 % where clicked, or back to the window's size.
    override func mouseDown(with event: NSEvent) {
        downAt = event.locationInWindow
        if event.clickCount == 2 {
            onClick()   // undo the first click's toggle: a double click zooms
            let point = imageView.convert(event.locationInWindow, from: nil)
            let fitted = fitMagnification
            if atFit || magnification <= fitted * 1.01 {
                atFit = false
                onZoomIn()
                animator().setMagnification(max(1, fitted * 2), centeredAt: point)
            } else {
                atFit = true
                NSAnimationContext.runAnimationGroup { _ in animator().magnification = fitted }
            }
            return
        }
        super.mouseDown(with: event)
    }

    /// A click that did not drag shows or hides the controls at once; the
    /// second click of a double click (which zooms) undoes it again.
    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        let p = event.locationInWindow
        guard hypot(p.x - downAt.x, p.y - downAt.y) < 4 else { return }
        if event.clickCount == 1 { onClick() }
    }

    /// A horizontal two-finger swipe at the window's size goes to the next
    /// or previous photo; zoomed in, it pans.
    override func scrollWheel(with event: NSEvent) {
        let fitted = magnification <= fitMagnification * 1.01
        guard fitted, event.hasPreciseScrollingDeltas, abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) || swipeX != 0 else {
            super.scrollWheel(with: event)
            return
        }
        if event.phase == .began { swipeX = 0 }
        swipeX += event.scrollingDeltaX
        if event.phase == .ended || event.phase == .cancelled || event.momentumPhase == .began {
            if abs(swipeX) > 60 { onSwipe(swipeX < 0 ? 1 : -1) }
            swipeX = 0
        }
    }
}

/// Keeps the document in the middle when it is smaller than the view.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposed: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposed)
        guard let doc = documentView else { return rect }
        if rect.width > doc.frame.width { rect.origin.x = (doc.frame.width - rect.width) / 2 }
        if rect.height > doc.frame.height { rect.origin.y = (doc.frame.height - rect.height) / 2 }
        return rect
    }
}

// MARK: - Video

/// A video, streaming through the cache (what was watched or prefetched
/// plays at once and offline), on a player layer of its own with the
/// viewer's bar (`VideoBar`). Its thumbnail stands in until the first frame
/// can show, so a step never lands on black.
private struct MacVideoPage: View {
    var library: Library
    let asset: Asset
    var onClick: () -> Void
    /// The viewer's handle on the player on screen, for the space bar.
    @Binding var shared: AVPlayer?
    @Environment(MacWindowState.self) private var window
    @State private var player: AVPlayer?
    @State private var surface = VideoSurface()
    @State private var ready = false

    var body: some View {
        ZStack {
            if let player {
                VideoSurfaceView(surface: surface)
                    // a click shows or hides the controls; only space and the
                    // bar's button play and pause
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onClick)
            }
            if !ready {
                InstantPoster(library: library, asset: asset)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        // the bar over everything, the thumbnail that stands in included
        .overlay(alignment: .bottom) {
            if let player, window.viewerChrome {
                VideoBar(player: player, surface: surface)
                    .frame(maxWidth: 620)
                    .padding(.horizontal, 70)
                    .padding(.bottom, 24)
            }
        }
        .animation(.easeOut(duration: 0.15), value: ready)
        .task(id: asset.id) {
            guard let remote = library.client.streamURL(asset.id) else { return }
            let item = AVPlayerItem(asset: VideoCache.shared.asset(id: asset.id, remote: remote))
            let player = AVPlayer(playerItem: item)
            surface.attach(player)
            self.player = player
            shared = player
            player.play()
            // the thumbnail leaves once the video moves (or failed, or after
            // 2 s at the latest): never over a playing video
            let start = Date()
            while !Task.isCancelled, !ready {
                if item.status == .failed || player.currentTime().seconds > 0.01
                    || Date().timeIntervalSince(start) > 2 { ready = true; break }
                try? await Task.sleep(for: .milliseconds(40))
            }
        }
        .onDisappear {
            surface.stopPictureInPicture()
            player?.pause()
            // the next video's page may have taken the handle already
            if shared === player { shared = nil }
            player = nil
        }
    }
}

/// The view the video is drawn in: an `AVPlayerLayer`, which Picture in
/// Picture needs (AVKit's player view keeps its layer to itself).
final class VideoSurface: NSView {
    let playerLayer = AVPlayerLayer()
    private var pip: AVPictureInPictureController?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspect
        playerLayer.actions = ["bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(playerLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func attach(_ player: AVPlayer) {
        playerLayer.player = player
        if pip == nil, AVPictureInPictureController.isPictureInPictureSupported() {
            pip = AVPictureInPictureController(playerLayer: playerLayer)
        }
    }

    var canPictureInPicture: Bool { pip != nil }
    var inPictureInPicture: Bool { pip?.isPictureInPictureActive ?? false }

    func togglePictureInPicture() {
        guard let pip else { return }
        pip.isPictureInPictureActive ? pip.stopPictureInPicture() : pip.startPictureInPicture()
    }

    func stopPictureInPicture() {
        if pip?.isPictureInPictureActive == true { pip?.stopPictureInPicture() }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}

private struct VideoSurfaceView: NSViewRepresentable {
    let surface: VideoSurface
    func makeNSView(context: Context) -> VideoSurface { surface }
    func updateNSView(_ view: VideoSurface, context: Context) {}
}

/// The video's controls, a glass panel in two rows at the bottom: the
/// progress between the time played and the time left (click or drag to
/// go anywhere), then mute; back 10 s, play and pause, ahead 10 s; and
/// Picture in Picture and full screen.
struct VideoBar: View {
    /// Whether a video starts over at its end (the server page's setting).
    static let loopKey = "video.loop"
    let player: AVPlayer
    let surface: VideoSurface
    @Environment(MacWindowState.self) private var window
    @State private var playing = true
    @State private var current: Double = 0
    @State private var duration: Double = 0
    @State private var muted = false
    @State private var scrubbing: Double?
    @State private var hoveringTrack = false
    @State private var observer: Any?
    @State private var columnsBeforeFullScreen: NavigationSplitViewVisibility?
    @AppStorage(VideoBar.loopKey) private var loop = false
    @State private var statusWatch: NSKeyValueObservation?

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Text(Self.time(scrubbing ?? current))
                    .frame(width: 44, alignment: .leading)
                track
                Text("−" + Self.time(max(duration - (scrubbing ?? current), 0)))
                    .frame(width: 50, alignment: .trailing)
            }
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)

            ZStack {
                HStack(spacing: 4) {
                    control(muted ? "speaker.slash.fill" : "speaker.wave.2.fill", muted ? "Unmute" : "Mute") {
                        muted.toggle()
                        player.isMuted = muted
                    }
                    Spacer()
                    if surface.canPictureInPicture {
                        control("pip.enter", "Picture in Picture") { surface.togglePictureInPicture() }
                    }
                    control(isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                            isFullScreen ? "Exit Full Screen" : "Full Screen") { toggleFullScreen() }
                }
                HStack(spacing: 22) {
                    control("gobackward.10", "Back 10 Seconds") { skip(-10) }
                    Button {
                        playing ? player.pause() : player.resume()
                    } label: {
                        Image(systemName: playing ? "pause.fill" : "play.fill")
                            .font(.system(size: 24, weight: .semibold))
                            .frame(width: 40, height: 36)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help(playing ? "Pause" : "Play")
                    .accessibilityLabel(playing ? "Pause" : "Play")
                    control("goforward.10", "Ahead 10 Seconds") { skip(10) }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .onAppear(perform: observe)
        .onDisappear {
            if let observer { player.removeTimeObserver(observer) }
            observer = nil
            statusWatch = nil
        }
        // at the end: start over (the setting), or stop with the play button
        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification,
                                                        object: player.currentItem)) { _ in
            if loop {
                player.seek(to: .zero)
                player.play()
            } else {
                player.pause()
                playing = false
            }
        }
    }

    private func control(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 34, height: 32)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    /// The progress: thicker under the pointer, a click or a drag anywhere
    /// on it goes there.
    private var track: some View {
        GeometryReader { geo in
            let shown = scrubbing ?? current
            let fraction = duration > 0 ? min(max(shown / duration, 0), 1) : 0
            let thick: CGFloat = hoveringTrack || scrubbing != nil ? 7 : 5
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.16))
                Capsule().fill(.primary.opacity(0.9)).frame(width: max(geo.size.width * fraction, thick))
            }
            .frame(height: thick)
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
            .onHover { hoveringTrack = $0 }
            .animation(.easeOut(duration: 0.12), value: thick)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    guard duration > 0 else { return }
                    let t = min(max(g.location.x / geo.size.width, 0), 1) * duration
                    scrubbing = t
                    player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                }
                .onEnded { _ in
                    if let t = scrubbing { current = t }
                    scrubbing = nil
                })
        }
        .frame(height: 16)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Self.time(current)) of \(Self.time(duration))")
    }

    private func skip(_ seconds: Double) {
        let t = min(max(current + seconds, 0), duration > 0 ? duration : .greatestFiniteMagnitude)
        current = t
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600))
    }

    private var isFullScreen: Bool { surface.window?.styleMask.contains(.fullScreen) ?? false }

    /// The window in full screen with the sidebar folded away, the video
    /// filling the screen; back as it was on the way out.
    private func toggleFullScreen() {
        guard let w = surface.window else { return }
        if isFullScreen {
            if let saved = columnsBeforeFullScreen { window.columns = saved }
            columnsBeforeFullScreen = nil
        } else {
            columnsBeforeFullScreen = window.columns
            window.columns = .detailOnly
        }
        w.toggleFullScreen(nil)
    }

    /// Four times a second (and when it starts or stops): the time, the
    /// length and whether it plays.
    private func observe() {
        guard observer == nil else { return }
        muted = player.isMuted
        statusWatch = player.observe(\.timeControlStatus, options: [.initial, .new]) { p, _ in
            let now = p.timeControlStatus != .paused
            DispatchQueue.main.async { if now != playing { playing = now } }
        }
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { t in
            MainActor.assumeIsolated {
                if scrubbing == nil { current = t.seconds.isFinite ? t.seconds : 0 }
                if let d = player.currentItem?.duration.seconds, d.isFinite, d != duration { duration = d }
                let now = player.timeControlStatus != .paused
                if now != playing { playing = now }
            }
        }
    }

    private static func time(_ s: Double) -> String {
        let t = Int(max(s, 0).rounded(.down))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
                         : String(format: "%d:%02d", t / 60, t % 60)
    }
}

extension AVPlayer {
    /// Plays on, or from the start when it stood at the end.
    func resume() {
        if let item = currentItem, item.duration.isNumeric,
           currentTime().seconds >= item.duration.seconds - 0.05 {
            seek(to: .zero)
        }
        play()
    }
}
