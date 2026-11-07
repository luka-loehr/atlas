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
    @State private var hovering = false
    @State private var lastIndex = 0

    private var index: Int? { current.flatMap { id in assets.firstIndex { $0.id == id } } }

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
            if let index, let asset = assets[safe: index] {
                Group {
                    if asset.isVideo {
                        MacVideoPage(library: library, asset: asset)
                    } else {
                        MacPhotoPage(library: library, asset: asset, onSwipe: step)
                    }
                }
                .id(asset.id)
                .transition(.opacity)
                edgeButtons(index)
            }
        }
        .animation(.easeInOut(duration: 0.12), value: current)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true; focusCache() }
        .onChange(of: current) { focusCache() }
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onKeyPress(.rightArrow) { step(1); return .handled }
        .onKeyPress(.space) { onClose(); return .handled }
        .onKeyPress(characters: ["."], phases: .down) { _ in onFavorite(); return .handled }
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
        .opacity(hovering ? 1 : 0)
        .animation(.easeOut(duration: 0.2), value: hovering)
    }

    private func edgeButton(_ symbol: String, _ label: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 36, height: 36)
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
        current = asset.id
    }

    /// The pages around this one, downloaded and decoded ahead.
    private func focusCache() {
        guard let index else { return }
        MediaCache.shared.viewerFocus(assets, index: index, forward: index >= lastIndex)
        lastIndex = index
    }
}

// MARK: - Photo

/// A photo: the 2048 preview at once (usually decoded ahead), then the
/// original once the photo stays on screen, for zooming in.
private struct MacPhotoPage: View {
    var library: Library
    let asset: Asset
    var onSwipe: (Int) -> Void

    @State private var image: NSImage?
    @State private var sharp = false

    var body: some View {
        ZStack {
            if let image {
                ZoomableImage(image: image, pixelSize: pixelSize, onSwipe: onSwipe)
            } else {
                // the grid's thumbnail, scaled up, while the preview comes
                Thumb(url: library.client.thumbURL(asset.id, 512))
                    .aspectRatio(CGFloat(asset.width ?? 4) / CGFloat(max(asset.height ?? 3, 1)), contentMode: .fit)
                    .padding(1)
                ProgressView().controlSize(.small)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(asset.spokenDescription)
        .accessibilityAddTraits(.isImage)
        .task(id: asset.id) {
            let client = library.client
            if let preview = client.thumbURL(asset.id, 2048) {
                image = await MediaCache.shared.loadFull(preview, maxPixel: MediaCache.viewerPixels(asset))
            }
            // dwell first: arrowing through the library downloads no originals
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, let original = client.originalURL(asset.id) else { return }
            if let full = await MediaCache.shared.loadFull(original, maxPixel: 8192), !Task.isCancelled {
                image = full
                sharp = true
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

/// `NSScrollView` magnification around an image view: fit to the window by
/// default, up to 8 × its pixels, centred when smaller than the window.
private struct ZoomableImage: NSViewRepresentable {
    let image: NSImage
    let pixelSize: CGSize
    var onSwipe: (Int) -> Void

    func makeNSView(context: Context) -> ZoomScrollView {
        let scroll = ZoomScrollView()
        scroll.onSwipe = onSwipe
        scroll.set(image: image, pixelSize: pixelSize)
        return scroll
    }

    func updateNSView(_ scroll: ZoomScrollView, context: Context) {
        scroll.onSwipe = onSwipe
        scroll.set(image: image, pixelSize: pixelSize)
    }
}

final class ZoomScrollView: NSScrollView {
    private let imageView = NSImageView()
    private var pixelSize: CGSize = .zero
    private var atFit = true
    var onSwipe: (Int) -> Void = { _ in }
    private var swipeX: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        contentView = CenteringClipView()
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
    }

    /// Double-click: 100 % where clicked, or back to the window's size.
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            let point = imageView.convert(event.locationInWindow, from: nil)
            let fitted = fitMagnification
            if atFit || magnification <= fitted * 1.01 {
                atFit = false
                animator().setMagnification(max(1, fitted * 2), centeredAt: point)
            } else {
                atFit = true
                NSAnimationContext.runAnimationGroup { _ in animator().magnification = fitted }
            }
            return
        }
        super.mouseDown(with: event)
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

/// A video in the system player, streaming through the cache (what was
/// watched or prefetched plays at once and offline).
private struct MacVideoPage: View {
    var library: Library
    let asset: Asset
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            if let player {
                PlayerView(player: player)
            } else {
                Thumb(url: library.client.thumbURL(asset.id, 512))
                    .aspectRatio(CGFloat(asset.width ?? 16) / CGFloat(max(asset.height ?? 9, 1)), contentMode: .fit)
                ProgressView().controlSize(.small)
            }
        }
        .task(id: asset.id) {
            guard let remote = library.client.streamURL(asset.id) else { return }
            let item = AVPlayerItem(asset: VideoCache.shared.asset(id: asset.id, remote: remote))
            let player = AVPlayer(playerItem: item)
            self.player = player
            player.play()
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }
}

private struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        view.allowsPictureInPicturePlayback = true
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}
