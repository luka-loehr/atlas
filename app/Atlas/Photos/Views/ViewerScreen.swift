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
    /// A photo left the viewer (archived, locked, deleted): the screen
    /// behind it drops it too.
    var onRemoved: ((String) -> Void)? = nil

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
    @State private var changeFailed = false
    // measured height of the bottom chrome stack (filmstrip + action bar) —
    // video controls anchor EXACTLY above it, overlap is structurally impossible
    @State private var chromeBottomHeight: CGFloat = 150
    /// The pager's position frame by frame, for the filmstrip and the tick.
    @State private var motion = PageMotion()

    var body: some View {
        ZStack {
            (chrome ? Color(uiColor: .systemBackground) : .black)
                .ignoresSafeArea()

            if !pages.isEmpty {
                PhotoPager(index: $index, count: pages.count, motion: motion) { i in
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
            // ready before the first video page needs it
            PlaybackAudio.activate()
            pages = assets
            index = assets.firstIndex(of: start) ?? 0
            ViewerNow.show(pages[safe: index]?.id)
            MediaCache.shared.viewerFocus(pages, index: index, forward: true)
            if let a = pages[safe: index] { ShareFiles.prepare(a, client: library.client) }
        }
        .onChange(of: index) { old, new in focus(new, forward: new >= old) }
        // the tick when a swipe crosses halfway comes from `motion`, with or
        // without the chrome; the filmstrip ticks for its own scrubbing
        .onDisappear {
            ViewerNow.show(nil)
            MediaCache.shared.viewerClosed()
        }
        .sheet(item: $infoAsset) { a in
            InfoSheet(library: library, asset: a)
                .presentationDetents([.medium, .large])
        }
        .sheet(item: $shareBundle) { b in
            ShareSheet(items: b.urls).presentationDetents([.medium, .large])
        }
        .changeFailedAlert($changeFailed)
    }

    /// The page at `i` is the one on screen now.
    private func focus(_ i: Int, forward: Bool) {
        MediaCache.shared.viewerFocus(pages, index: i, forward: forward)
        ViewerNow.show(pages[safe: i]?.id)
        if let a = pages[safe: i] {
            onPage?(a)
            ShareFiles.prepare(a, client: library.client)
        }
    }

    // MARK: - Chrome (Google-Photos layout)

    @ViewBuilder
    private func chromeOverlay(_ asset: Asset) -> some View {
        let screenHeight = ScreenSize.bounds.height
        VStack(spacing: 0) {
            topBar(asset)
            Spacer()
            VStack(spacing: 19) {
                FilmstripView(assets: pages, index: $index, motion: motion)
                    .frame(height: FilmstripView.height)
                bottomBar(asset)
            }
            .padding(.bottom, -6)
            .onGeometryChange(for: CGFloat.self, of: {
                // distance from the stack's TOP edge to the PHYSICAL screen
                // bottom — pages ignore safe areas, so measure in global space
                screenHeight - $0.frame(in: .global).minY
            }) { chromeBottomHeight = $0 }
        }
    }

    private func topBar(_ asset: Asset) -> some View {
        HStack(alignment: .center) {
            CircleButton(icon: "chevron.backward", label: "Back") { close() }
            Spacer(minLength: 8)
            let place = placeTitle(asset)
            VStack(spacing: 0) {
                Text(place ?? relativeDay(asset.takenAt))
                    .font(.headline)
                if let t = asset.takenAt {
                    Text(place != nil
                         ? "\(relativeDay(t))  \(t.formatted(date: .omitted, time: .shortened))"
                         : t.formatted(date: .omitted, time: .shortened))
                        .font(.footnote)
                }
            }
            // a new photo changes the words, never the pill: no fade, no morph
            .transaction { $0.animation = nil }
            .foregroundStyle(.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .accessibilityElement(children: .combine)
            .padding(.horizontal, 24)
            .frame(minWidth: 158, minHeight: 44)
            .glassEffect(.regular, in: .capsule)      // iOS 26 Liquid Glass
            Spacer(minLength: 8)
            .task(id: asset.id) { await loadPlaces(around: asset) }
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
        Task {
            do {
                try await library.client.favorite([a.id], new)
                library.setFavorite([a.id], new)
            } catch {
                favorites[a.id] = !new
                changeFailed = true
            }
        }
    }

    private func shareCurrent() {
        guard let a = pages[safe: index] else { return }
        Task {
            defer { busy = false }
            // the original the viewer fetched when the page appeared; the
            // spinner only when it is not on the phone yet
            let files = await ShareFiles.files(for: [a], client: library.client) { busy = true }
            if !files.isEmpty { shareBundle = ShareBundle(urls: files) }
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
            do { try await op(a.id) } catch { changeFailed = true; return }
            library.removeLocally([a.id])
            onRemoved?(a.id)
            // the page may have moved on while the server answered
            guard let at = pages.firstIndex(where: { $0.id == a.id }) else { return }
            if pages.count <= 1 {
                close()
            } else {
                var next = pages
                next.remove(at: at)
                let newIndex = min(at < index ? index - 1 : index, next.count - 1)
                pages = next
                if newIndex != index { index = newIndex }
                // same index, another photo: `onChange(of: index)` stays quiet
                focus(newIndex, forward: true)
            }
        }
    }

    /// Where each photo was taken, as the title of the top pill (like
    /// Photos). `noPlace` holds photos known to have none.
    @State private var places: [String: String] = [:]
    @State private var noPlace: Set<String> = []
    /// The place last shown: kept while the next photo's place is still on its
    /// way, so swiping between photos of one town never flickers.
    @State private var lastPlace: String?

    private func placeTitle(_ a: Asset) -> String? {
        if let p = places[a.id] { return p }
        if noPlace.contains(a.id) { return nil }
        return lastPlace
    }

    /// The photo's place, and its neighbours' ahead of the next swipe.
    private func loadPlaces(around a: Asset) async {
        if let p = places[a.id] { lastPlace = p } else if noPlace.contains(a.id) { lastPlace = nil }
        guard let i = pages.firstIndex(of: a) else { return }
        let ids = ([i] + (1...3).flatMap { [i + $0, i - $0] }).compactMap { pages[safe: $0]?.id }
            .filter { places[$0] == nil && !noPlace.contains($0) }
        let client = library.client
        await withTaskGroup(of: (String, String?, Bool).self) { group in
            for id in ids {
                group.addTask {
                    guard let info = try? await client.assetInfo(id) else { return (id, nil, false) }
                    // the locality, like Photos ("Karlsruhe"), not the state after it
                    return (id, info.place.map { $0.components(separatedBy: ", ").first ?? $0 }, true)
                }
            }
            for await (id, place, answered) in group {
                guard answered else { continue }
                if let place { places[id] = place } else { noPlace.insert(id) }
                if id == a.id { lastPlace = place }
            }
        }
    }

    private func relativeDay(_ d: Date?) -> String {
        guard let d else { return "—" }
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        let f: DateFormatter
        if let days = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: Date())).day,
           days < 7 {
            f = Self.weekday
        } else {
            f = cal.isDate(d, equalTo: Date(), toGranularity: .year) ? Self.dayThisYear : Self.dayOtherYear
        }
        return f.string(from: d)
    }

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US"); f.dateFormat = format; return f
    }
    private static let weekday = formatter("EEEE")
    private static let dayThisYear = formatter("d MMMM")
    private static let dayOtherYear = formatter("d MMMM yyyy")

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

/// The strip of neighbouring thumbnails, as in Photos: narrow slivers, the
/// current photo opened to a square with air on both sides. A UIKit
/// collection view with a layout that follows its scroll position
/// continuously, driven every frame either by the user's finger on the strip
/// (scrubbing, with a tick per photo) or by the pager above it (swiping).
struct FilmstripView: UIViewRepresentable {
    let assets: [Asset]
    @Binding var index: Int
    let motion: PageMotion

    static let cell: CGFloat = 20, height: CGFloat = 30, gap: CGFloat = 3, air: CGFloat = 11
    static var pitch: CGFloat { cell + gap }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let c = context.coordinator
        motion.strip = c
        c.reload(assets)
        return c.container
    }

    func updateUIView(_ view: UIView, context: Context) {
        let c = context.coordinator
        c.parent = self
        motion.strip = c
        if c.assets.count != assets.count || c.assets.first?.id != assets.first?.id { c.reload(assets) }
        c.settle(on: index)
    }

    @MainActor
    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegate {
        var parent: FilmstripView
        var assets: [Asset] = []
        let layout = StripLayout()
        let container = StripContainer()
        private(set) var collection: UICollectionView!
        private var lastScrubbed: Int?
        private let haptics = UISelectionFeedbackGenerator()
        private var programmatic = false

        init(_ parent: FilmstripView) {
            self.parent = parent
            super.init()
            collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
            collection.backgroundColor = .clear
            collection.showsHorizontalScrollIndicator = false
            collection.decelerationRate = .fast
            collection.contentInsetAdjustmentBehavior = .never
            collection.register(StripCell.self, forCellWithReuseIdentifier: "c")
            collection.dataSource = self
            collection.delegate = self
            container.collection = collection
            container.addSubview(collection)
            container.isAccessibilityElement = true
            container.accessibilityLabel = "Filmstrip"
            container.accessibilityTraits = .adjustable
            container.onAdjust = { [weak self] step in
                guard let self else { return }
                let next = min(max(self.parent.index + step, 0), self.assets.count - 1)
                if next != self.parent.index { self.parent.index = next }
            }
        }

        func reload(_ assets: [Asset]) {
            self.assets = assets
            collection.reloadData()
            container.accessibilityValue = "\(parent.index + 1) of \(assets.count)"
        }

        // MARK: Position

        /// The strip's content offset that puts `position` in the middle.
        private func offset(for position: CGFloat) -> CGFloat {
            position * FilmstripView.pitch - collection.contentInset.left
        }

        var centerPosition: CGFloat {
            (collection.contentOffset.x + collection.contentInset.left) / FilmstripView.pitch
        }

        /// The pager moved: follow it exactly, unless the user holds the strip.
        func follow(_ position: CGFloat) {
            guard !collection.isTracking, !collection.isDecelerating, collection.bounds.width > 0 else { return }
            programmatic = true
            collection.contentOffset.x = offset(for: position)
            programmatic = false
        }

        /// The viewer's index changed (landing, delete, external jump).
        func settle(on index: Int) {
            container.accessibilityValue = "\(index + 1) of \(assets.count)"
            guard !collection.isTracking, !collection.isDecelerating, collection.bounds.width > 0 else {
                container.pendingIndex = index
                return
            }
            if abs(centerPosition - CGFloat(index)) > 0.01 { follow(CGFloat(index)) }
        }

        func laidOut() {
            if let i = container.pendingIndex {
                container.pendingIndex = nil
                follow(CGFloat(i))
            }
        }

        // MARK: Scrubbing

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            haptics.prepare()
            lastScrubbed = parent.index
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard !programmatic, scrollView.isTracking || scrollView.isDecelerating, !assets.isEmpty else { return }
            let i = min(max(Int(centerPosition.rounded()), 0), assets.count - 1)
            guard i != lastScrubbed else { return }
            lastScrubbed = i
            haptics.selectionChanged()
            parent.motion.reset(to: i)
            parent.index = i
        }

        func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                       targetContentOffset target: UnsafeMutablePointer<CGPoint>) {
            // always come to rest with a photo exactly in the middle
            let pos = ((target.pointee.x + scrollView.contentInset.left) / FilmstripView.pitch).rounded()
            let clamped = min(max(pos, 0), CGFloat(max(assets.count - 1, 0)))
            target.pointee.x = offset(for: clamped)
        }

        func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            guard indexPath.item != parent.index else { return }
            haptics.selectionChanged()
            parent.motion.reset(to: indexPath.item)
            parent.index = indexPath.item
        }

        // MARK: Data

        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { assets.count }

        func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "c", for: indexPath) as! StripCell
            cell.show(assets[indexPath.item].id)
            return cell
        }
    }

    /// Holds the strip, fades its ends and keeps the first and last photo
    /// able to rest in the middle.
    final class StripContainer: UIView {
        weak var collection: UICollectionView?
        var pendingIndex: Int?
        var onAdjust: (Int) -> Void = { _ in }
        private let fade = CAGradientLayer()

        override init(frame: CGRect) {
            super.init(frame: frame)
            fade.startPoint = CGPoint(x: 0, y: 0.5)
            fade.endPoint = CGPoint(x: 1, y: 0.5)
            fade.colors = [UIColor.clear, .black, .black, .clear].map(\.cgColor)
            layer.mask = fade
        }
        required init?(coder: NSCoder) { fatalError() }

        override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: FilmstripView.height) }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard let collection else { return }
            let position = (collection.contentOffset.x + collection.contentInset.left) / FilmstripView.pitch
            collection.frame = bounds
            let inset = (bounds.width - FilmstripView.cell) / 2
            collection.contentInset = UIEdgeInsets(top: 0, left: inset, bottom: 0, right: inset)
            if collection.contentOffset.x != position * FilmstripView.pitch - inset, pendingIndex == nil {
                collection.contentOffset.x = position * FilmstripView.pitch - inset
            }
            // like Photos: the strip ends 15 pt from the edges and fades out there
            CATransaction.begin(); CATransaction.setDisableActions(true)
            fade.frame = bounds.insetBy(dx: 15, dy: 0)
            fade.locations = [0, 0.08, 0.92, 1]
            CATransaction.commit()
            (collection.delegate as? Coordinator)?.laidOut()
        }

        override func accessibilityIncrement() { onAdjust(1) }
        override func accessibilityDecrement() { onAdjust(-1) }
    }

    /// Every thumbnail's frame follows from the scroll position alone: far
    /// from the middle a 20 pt sliver, opening to the 30 pt square as it
    /// reaches it while the neighbours step aside.
    final class StripLayout: UICollectionViewLayout {
        private var count = 0
        override func prepare() {
            super.prepare()
            count = collectionView?.numberOfItems(inSection: 0) ?? 0
        }
        override var collectionViewContentSize: CGSize {
            CGSize(width: max(CGFloat(count) * FilmstripView.pitch - FilmstripView.gap, 0), height: FilmstripView.height)
        }
        override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool { true }

        private func center(_ cv: UICollectionView) -> CGFloat {
            (cv.contentOffset.x + cv.contentInset.left) / FilmstripView.pitch
        }

        private func attributes(_ i: Int, center c: CGFloat) -> UICollectionViewLayoutAttributes {
            let s = FilmstripView.self
            let a = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: i, section: 0))
            let dx = CGFloat(i) - c
            let near = min(abs(dx), 1)
            let width = s.cell + (s.height - s.cell) * (1 - near)
            let push = (s.air + (s.height - s.cell) / 2) * near * (dx < 0 ? -1 : 1)
            let mid = CGFloat(i) * s.pitch + s.cell / 2 + push
            a.frame = CGRect(x: mid - width / 2, y: 0, width: width, height: s.height)
            a.zIndex = -Int(abs(dx) * 10)
            return a
        }

        override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
            guard let cv = collectionView, count > 0 else { return [] }
            let c = center(cv)
            let first = max(Int(((rect.minX - 40) / FilmstripView.pitch).rounded(.down)), 0)
            let last = min(Int(((rect.maxX + 40) / FilmstripView.pitch).rounded(.up)), count - 1)
            guard first <= last else { return [] }
            return (first...last).map { attributes($0, center: c) }
        }

        override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
            guard let cv = collectionView, indexPath.item < count else { return nil }
            return attributes(indexPath.item, center: center(cv))
        }
    }

    /// A square thumbnail seen through the cell's (narrower) frame.
    final class StripCell: UICollectionViewCell {
        private let image = UIImageView()
        private var id: String?
        private var ticket: MediaCache.Ticket?

        override init(frame: CGRect) {
            super.init(frame: frame)
            contentView.clipsToBounds = true
            contentView.layer.cornerRadius = 3
            contentView.layer.cornerCurve = .continuous
            contentView.backgroundColor = .secondarySystemFill
            image.contentMode = .scaleAspectFill
            image.clipsToBounds = true
            contentView.addSubview(image)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func layoutSubviews() {
            super.layoutSubviews()
            // always the full square, centred: the cell's width decides how much shows
            let side = FilmstripView.height
            image.frame = CGRect(x: (contentView.bounds.width - side) / 2, y: 0, width: side, height: side)
        }

        func show(_ id: String) {
            guard id != self.id else { return }
            ticket?.cancel()
            self.id = id
            let pixels = Int(FilmstripView.height * 3)
            if let img = MediaCache.shared.gridImage(id: id, pixels: pixels) {
                image.image = img
                return
            }
            image.image = nil
            ticket = MediaCache.shared.requestGrid(id: id, pixels: pixels, urgent: true) { [weak self] img in
                guard let self, self.id == id else { return }
                self.ticket = nil
                self.image.image = img
            }
        }

        override func prepareForReuse() {
            super.prepareForReuse()
            ticket?.cancel()
            ticket = nil
            id = nil
            image.image = nil
        }
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
            VideoPlayer(id: asset.id, url: library.client.streamURL(asset.id),
                            poster: library.client.thumbURL(asset.id, 512),
                            chrome: chrome, bottomInset: bottomInset, onTap: onTap)
        } else {
            ZoomablePhoto(
                thumb: library.client.thumbURL(asset.id, 512),
                preview: library.client.thumbURL(asset.id, 2048),
                full: library.client.originalURL(asset.id),
                previewPixels: MediaCache.viewerPixels(asset),
                onTap: onTap
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(asset.spokenDescription)
            .accessibilityAddTraits(.isImage)
        }
    }
}

/// Shows the 2048 preview at once (the viewer's look-ahead decoded it before
/// the swipe; else the grid's thumbnail first), swaps in the downsampled
/// original, then hosts it in a UIScrollView for zoom. At zoom 1
/// the scroll view doesn't consume drags, so the pager (horizontal) and the
/// zoom-transition dismiss (down) keep working — exactly like Apple Photos.
private struct ZoomablePhoto: View {
    let thumb: URL?      // 512, cached from the grid → instant, offline-safe
    let preview: URL?    // 2048
    let full: URL?       // original
    /// The size the preview is decoded at, the same as the look-ahead's.
    var previewPixels: CGFloat
    var onTap: () -> Void = {}
    @State private var image: UIImage?

    init(thumb: URL?, preview: URL?, full: URL?, previewPixels: CGFloat, onTap: @escaping () -> Void = {}) {
        self.thumb = thumb
        self.preview = preview
        self.full = full
        self.previewPixels = previewPixels
        self.onTap = onTap
        // a decoded preview (or the thumbnail) is there in the very first
        // frame of the page, also while it slides in
        let cache = MediaCache.shared
        _image = State(initialValue: preview.flatMap { cache.cached($0, maxPixel: previewPixels) }
                       ?? thumb.flatMap { cache.cached($0) })
    }

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
                if let c = MediaCache.shared.cached(t) { image = c }
                else if let img = await MediaCache.shared.load(t), image == nil { image = img }
            }
            // 2) sharpen to the 2048 preview
            if let p = preview {
                if let c = MediaCache.shared.cached(p, maxPixel: previewPixels) {
                    if image !== c { image = c }
                } else if let img = await MediaCache.shared.load(p, maxPixel: previewPixels) {
                    image = img
                }
            }
            // full quality ONLY when the user actually settles on this photo:
            // while scrubbing through the strip each page lives < 600ms, its
            // task gets cancelled here and no original is ever downloaded
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            if let f = full, let img = await MediaCache.shared.loadFull(f, maxPixel: 2800) {
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
        // at zoom 1 the photo's own pan stays out of the way: the pager (left,
        // right) and swipe-to-close (down) get every drag at once
        scroll.panGestureRecognizer.isEnabled = false
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        // the chrome toggling re-renders every page; only a new image is news
        if context.coordinator.imageView.image !== image { context.coordinator.imageView.image = image }
        context.coordinator.onSingleTap = onSingleTap
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        let imageView = UIImageView()
        var onSingleTap: () -> Void = {}

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            // panning around only makes sense while zoomed in
            scrollView.panGestureRecognizer.isEnabled = scrollView.zoomScale > 1.01
        }

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

private struct VideoPlayer: View {
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
        .onReceive(NotificationCenter.default.publisher(for: ViewerNow.changed)) { _ in
            guard let player else { return }
            if ViewerNow.id == id {
                // swiped back to it: carry on like Photos does
                if !playing, duration <= 0 || current < duration - 0.05 { player.play(); playing = true }
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
            player.play()
        }
        playing.toggle()
    }

    @MainActor
    private func setup() async {
        guard player == nil, let url else { return }
        // play sound even with the ringer/Focus on silent (like Photos/YouTube);
        // activating the audio session can block for most of a second, so it
        // never happens on the main thread, and only once
        PlaybackAudio.activate()
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
}
