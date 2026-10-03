import SwiftUI
import UIKit
import AVFoundation

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
    /// Set when the viewer is presented from UIKit (the photo grid), which
    /// dismisses it itself; else the SwiftUI presentation is dismissed.
    var onClose: (() -> Void)? = nil
    /// The photo now shown, for the zoom transition back into the grid.
    var onPage: ((Asset) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }
    @State private var pages: [Asset] = []
    @State private var index: Int = 0
    @State private var chrome = true
    @State private var infoAsset: Asset?
    @State private var shareBundle: ShareBundle?
    @State private var confirmTrash = false
    @State private var favorites: [String: Bool] = [:]   // optimistic overrides
    @State private var busy = false
    // measured height of the bottom chrome stack (filmstrip + action bar) —
    // video controls anchor EXACTLY above it, overlap is structurally impossible
    @State private var chromeBottomHeight: CGFloat = 150

    var body: some View {
        ZStack {
            (chrome ? Color(uiColor: .systemBackground) : .black)
                .ignoresSafeArea()

            if !pages.isEmpty {
                PhotoPager(index: $index, count: pages.count) { i in
                    ViewerPage(library: library, asset: pages[i], chrome: chrome,
                               bottomInset: chromeBottomHeight + 20) {
                        // NO withAnimation: chrome pops in/out instantly, both ways
                        chrome.toggle()
                    }
                }
                .ignoresSafeArea()
            }

            if chrome, let asset = pages[safe: index] {
                chromeOverlay(asset)
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
        .onChange(of: index) { _, new in
            prefetchNeighbors(of: new)
            if let a = pages[safe: new] { onPage?(a) }
        }
        .sheet(item: $infoAsset) { a in
            InfoSheet(library: library, asset: a)
                .presentationDetents([.medium, .large])
        }
        .sheet(item: $shareBundle) { b in
            ShareSheet(items: b.urls).presentationDetents([.medium, .large])
        }
    }

    // MARK: - Chrome (Google-Photos layout)

    @ViewBuilder
    private func chromeOverlay(_ asset: Asset) -> some View {
        VStack(spacing: 0) {
            topBar(asset)
            Spacer()
            VStack(spacing: 19) {
                Filmstrip(assets: pages, index: $index, client: library.client)
                bottomBar(asset)
            }
            .padding(.bottom, -6)
            .onGeometryChange(for: CGFloat.self, of: {
                // distance from the stack's TOP edge to the PHYSICAL screen
                // bottom — pages ignore safe areas, so measure in global space
                UIScreen.main.bounds.height - $0.frame(in: .global).minY
            }) { chromeBottomHeight = $0 }
        }
    }

    private func topBar(_ asset: Asset) -> some View {
        HStack(alignment: .center) {
            CircleButton(icon: "chevron.backward", label: "Back") { close() }
            Spacer(minLength: 8)
            VStack(spacing: 0) {
                Text(places[asset.id] ?? relativeDay(asset.takenAt))
                    .font(.headline)
                if let t = asset.takenAt {
                    Text(places[asset.id] != nil
                         ? "\(relativeDay(t))  \(t.formatted(date: .omitted, time: .shortened))"
                         : t.formatted(date: .omitted, time: .shortened))
                        .font(.footnote)
                }
            }
            .foregroundStyle(.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .accessibilityElement(children: .combine)
            .padding(.horizontal, 24)
            .frame(minWidth: 158, minHeight: 44)
            .glassEffect(.regular, in: .capsule)      // iOS 26 Liquid Glass
            Spacer(minLength: 8)
            .task(id: asset.id) { await loadPlace(asset) }
            Menu {
                Button {
                    mutateAndRemove { try await library.client.archive([$0], true) }
                } label: { Label("Archive", systemImage: "archivebox") }
                Button {
                    mutateAndRemove { try await library.client.lock([$0], true) }
                } label: { Label("Lock", systemImage: "lock") }
                Button { infoAsset = asset } label: {
                    Label("Details", systemImage: "info.circle")
                }
            } label: {
                CircleButton(icon: "ellipsis", label: "More") {}.allowsHitTesting(false)
            }
            .accessibilityLabel("More")
        }
        .padding(.horizontal, 16)
    }

    private func bottomBar(_ asset: Asset) -> some View {
        HStack {
            CircleButton(icon: "square.and.arrow.up", label: "Share", nudge: -1.5, size: 48) { shareCurrent() }
            Spacer()
            // 44-pt hit areas; spacing and padding shrink by the same amount,
            // so the glyphs sit exactly where they did with the bare icons
            HStack(spacing: 10) {
                Button { toggleFavorite(asset) } label: {
                    barIcon(isFav(asset) ? "heart.fill" : "heart")
                        .foregroundStyle(isFav(asset) ? .red : .primary)
                }
                .accessibilityLabel(isFav(asset) ? "Unfavorite" : "Favorite")
                Button { infoAsset = asset } label: {
                    barIcon("info.circle").foregroundStyle(.primary)
                }
                .accessibilityLabel("Details")
                Button {
                    mutateAndRemove { try await library.client.archive([$0], true) }
                } label: {
                    barIcon("archivebox").foregroundStyle(.primary)
                }
                .accessibilityLabel("Archive")
            }
            .padding(.horizontal, 3)
            .frame(height: 48)
            .glassEffect(.regular, in: .capsule)      // iOS 26 Liquid Glass
            Spacer()
            CircleButton(icon: "trash", label: "Delete", size: 48) { confirmTrash = true }
                .confirmationDialog("Delete Photo?", isPresented: $confirmTrash,
                                    titleVisibility: .visible) {
                    Button("Delete", role: .destructive) { trashCurrent() }
                }
        }
        .padding(.horizontal, 28)
    }

    private func barIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 22))
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
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
            if let (tmp, resp) = try? await URLSession.shared.download(for: AtlasAuth.request(src, timeoutInterval: 600)) {
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
                close()
            } else {
                var next = pages
                next.remove(at: index)
                let newIndex = min(index, next.count - 1)
                pages = next
                index = newIndex
            }
        }
    }

    /// Where the photo was taken, as the title of the top pill (like Photos).
    @State private var places: [String: String] = [:]

    private func loadPlace(_ a: Asset) async {
        guard places[a.id] == nil,
              let info = try? await library.client.assetInfo(a.id), let place = info.place else { return }
        // the locality, like Photos ("Karlsruhe"), not the state after it
        places[a.id] = place.components(separatedBy: ", ").first ?? place
    }

    private func relativeDay(_ d: Date?) -> String {
        guard let d else { return "—" }
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        if let days = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: Date())).day,
           days < 7 {
            f.dateFormat = "EEEE"
        } else {
            f.dateFormat = cal.isDate(d, equalTo: Date(), toGranularity: .year) ? "d MMMM" : "d MMMM yyyy"
        }
        return f.string(from: d)
    }

    private static let dayThisYear: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US"); f.dateFormat = "d MMM"; return f
    }()
    private static let dayOtherYear: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US"); f.dateFormat = "d MMM yyyy"; return f
    }()

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
/// `nudge` shifts the glyph vertically for optical centering: symbols like
/// square.and.arrow.up carry their visual mass (the box) below the bounding-box
/// center, so geometric centering makes them sit visibly low in the circle.
struct CircleButton: View {
    let icon: String
    /// VoiceOver name of the icon-only button.
    let label: String
    var nudge: CGFloat = 0
    var size: CGFloat = 44
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(.primary)
                .offset(y: nudge)
                .frame(width: size, height: size)
                .glassEffect(.regular, in: .circle)   // iOS 26 Liquid Glass
        }
        .accessibilityLabel(label)
    }
}

/// Horizontal strip of neighbor thumbnails; tap jumps, current is highlighted.
/// Centered snap-scrubber, camera-lens style: no ring — the SELECTED thumb is
/// simply the bigger one, always dead-center. Thumbs scale/fade geometrically
/// as they pass the center (zero index-lag), fast flicks keep their momentum
/// across many thumbs before snapping, and every detent ticks haptically.
private struct Filmstrip: View {
    let assets: [Asset]
    @Binding var index: Int
    let client: PhotoClient
    @State private var pos: Int?
    /// The part of the timeline the strip holds. A lazy stack over all
    /// 25,000 photos blocked the main thread for over half a second when the
    /// viewer opened (it has to place the current photo 25,000 cells in);
    /// a window around the current photo is instant, and it moves along
    /// when the strip gets near one of its ends.
    @State private var window: Range<Int> = 0..<0
    /// The thumb under the middle of the strip, fractional while it moves.
    @State private var centerPos: CGFloat = 0
    private static let reach = 400

    private let cell: CGFloat = 20
    private let height: CGFloat = 30
    private let gap: CGFloat = 3
    /// Air on either side of the current photo.
    private let air: CGFloat = 11

    private func recenter(_ i: Int) {
        let lo = max(i - Self.reach, 0), hi = min(i + Self.reach, assets.count)
        if window.isEmpty || i < window.lowerBound + 40 && window.lowerBound > 0
            || i > window.upperBound - 40 && window.upperBound < assets.count
            || window.upperBound > assets.count {
            window = lo..<hi
        }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: gap) {
                ForEach(window.clamped(to: 0..<assets.count), id: \.self) { i in
                    // every thumb is a square photo seen through a window: 20 pt
                    // wide far from the middle, opening to the full 30 pt
                    // square as it reaches it, while its neighbours step aside.
                    // Driven by the live scroll position, so it follows the
                    // finger and the momentum continuously
                    let dx = CGFloat(i) - centerPos
                    let near = min(abs(dx), 1)
                    let open = cell + (height - cell) * (1 - near)
                    let push = (air + (height - cell) / 2) * near
                    Thumb(url: client.thumbURL(assets[i].id, 512))
                        .frame(width: height, height: height)
                        .frame(width: open, height: height)
                        .clipShape(.rect(cornerRadius: 3, style: .continuous))
                        .frame(width: cell, height: height)
                        .offset(x: dx < 0 ? -push : push)
                        // center wins the overlap — z falls off with distance
                        // so every thumb overlaps its farther neighbor on BOTH sides
                        .zIndex(-Double(abs(dx)))
                        .id(i)
                        .onTapGesture { index = i }
                }
            }
            .scrollTargetLayout()
            .frame(height: height)
        }
        // margins so the first/last thumb can also rest dead-center
        .contentMargins(.horizontal,
                        (UIScreen.main.bounds.width - cell) / 2,
                        for: .scrollContent)
        .scrollPosition(id: $pos, anchor: .center)
        // .never = a fast flick keeps its momentum across MANY thumbs (the
        // "flywheel" feel of a mechanical lens ring) and still snaps at rest;
        // a slow controlled drag clicks thumb by thumb
        .scrollTargetBehavior(.viewAligned(limitBehavior: .alwaysByFew))
        .frame(height: height)
        // which thumb sits under the middle, as a fraction, every frame
        .onScrollGeometryChange(for: CGFloat.self, of: { [cell, gap] g in
            // the content margins put thumb k under the middle at
            // contentOffset.x == k * pitch - leading inset
            (g.contentOffset.x + g.contentInsets.leading + g.containerSize.width / 2 - cell / 2) / (cell + gap)
        }) { _, p in
            centerPos = p + CGFloat(window.lowerBound)
        }
        // like Photos: the strip ends 15 pt from the edges and fades out there
        .mask {
            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.08),
                                   .init(color: .black, location: 0.92), .init(color: .clear, location: 1)],
                           startPoint: .leading, endPoint: .trailing)
                .padding(.horizontal, 15)
        }
        // VoiceOver: one adjustable element (swipe up/down = next/previous)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Filmstrip")
        .accessibilityValue("\(index + 1) of \(assets.count)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: if index + 1 < assets.count { index += 1 }
            case .decrement: if index > 0 { index -= 1 }
            @unknown default: break
            }
        }
        // mechanical lens-click on every detent (scrub AND page swipe)
        .sensoryFeedback(.selection, trigger: index)
        .onAppear { recenter(index); pos = index; centerPos = CGFloat(index) }
        .onChange(of: index) { _, i in
            recenter(i)
            if pos != i { withAnimation(.snappy) { pos = i } }
        }
        .onChange(of: pos) { _, p in
            if let p, p != index { index = p }   // user scrubbed the strip
        }
        .onChange(of: assets.count) { recenter(index) }
    }
}

private struct ViewerPage: View {
    var library: Library
    var asset: Asset
    var chrome: Bool
    var bottomInset: CGFloat = 150
    var onTap: () -> Void

    var body: some View {
        if asset.isVideo {
            VideoPlayer(url: library.client.streamURL(asset.id),
                            poster: library.client.thumbURL(asset.id, 512),
                            chrome: chrome, bottomInset: bottomInset, onTap: onTap)
        } else {
            ZoomablePhoto(
                thumb: library.client.thumbURL(asset.id, 512),
                preview: library.client.thumbURL(asset.id, 2048),
                full: library.client.originalURL(asset.id),
                onTap: onTap
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(asset.spokenDescription)
            .accessibilityAddTraits(.isImage)
        }
    }
}

/// Loads the 2048 preview instantly (cached from the grid), swaps in the
/// downsampled original, then hosts it in a UIScrollView for zoom. At zoom 1
/// the scroll view doesn't consume drags, so the pager (horizontal) and the
/// zoom-transition dismiss (down) keep working — exactly like Apple Photos.
private struct ZoomablePhoto: View {
    let thumb: URL?      // 512, cached from the grid → instant, offline-safe
    let preview: URL?    // 2048
    let full: URL?       // original
    var onTap: () -> Void = {}
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                ZoomableScrollView(image: { image }, onSingleTap: onTap)
            } else {
                Thumb(url: thumb)
                    .aspectRatio(contentMode: .fit)
                    .contentShape(Rectangle())
                    .onTapGesture { onTap() }
            }
        }
        .task(id: full) {
            // 1) the grid's 512 thumb is already cached → show the photo (blurry)
            //    INSTANTLY instead of a grey wait, even on bad internet / offline
            if image == nil, let t = thumb {
                if let c = ThumbLoader.shared.cached(t) { image = c }
                else if let img = await ThumbLoader.shared.load(t), image == nil { image = img }
            }
            // 2) sharpen to the 2048 preview
            if let p = preview, let img = await ThumbLoader.shared.load(p) { image = img }
            // full quality ONLY when the user actually settles on this photo:
            // while scrubbing through the strip each page lives < 600ms, its
            // task gets cancelled here and no original is ever downloaded
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
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
private struct VideoPlayer: View {
    let url: URL?
    var poster: URL?
    var chrome: Bool
    var bottomInset: CGFloat = 150
    var onTap: () -> Void

    @State private var player: AVPlayer?
    @State private var timeObs: Any?
    @State private var endObs: Any?
    @State private var playing = false
    @State private var current: Double = 0
    @State private var duration: Double = 0
    @State private var scrubbing = false

    @State private var muted = false

    var body: some View {
        ZStack {
            if let player {
                PlayerLayerView(player: player)
                    .ignoresSafeArea()
            } else {
                // no empty black box while the stream prepares: show the poster
                // thumbnail (cached from the grid) with a spinner over it
                Thumb(url: poster)
                    .aspectRatio(contentMode: .fit)
                ProgressView()
                    .tint(.white)
                    .controlSize(.large)
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
        // AVURLAsset options carry the optional bearer token to the stream endpoint
        let p = AVPlayer(playerItem: AVPlayerItem(asset: AVURLAsset(url: url, options: AtlasAuth.avAssetOptions)))
        p.isMuted = false
        player = p
        p.play()
        playing = true

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
            object: p.currentItem, queue: .main) { _ in
            MainActor.assumeIsolated { playing = false }
        }
    }

    /// Full teardown so every swiped-past video releases its AVPlayer +
    /// observers + decode buffers instead of leaking across the session.
    private func teardown() {
        if let t = timeObs { player?.removeTimeObserver(t); timeObs = nil }
        if let e = endObs { NotificationCenter.default.removeObserver(e); endObs = nil }
        player?.pause()
        player = nil
        playing = false
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
