import SwiftUI
import UIKit

/// The main photo grid, built on UICollectionView.
///
/// A SwiftUI grid re-evaluates view bodies, modifiers and gestures for every
/// row that scrolls in; with 25,000 photos that was the scroll jank. Here a
/// cell is a recycled UIView: configuring it is a dictionary lookup plus, on
/// a miss, a request to `MediaCache`, whose disk read and decode run off
/// the main thread. Looks and behaves like before: oldest first, opens at
/// the newest end, pinch steps through 1/3/5/9 columns, tap opens the viewer
/// with the zoom transition, long press shows the system context menu with
/// a large preview, selection mode with the same check marks.
struct PhotoGrid: UIViewControllerRepresentable {
    var library: Library
    var assets: [Asset]
    /// Changes whenever `assets` does; cheaper to compare than the array.
    var revision: Int
    var selecting: Bool
    var selected: Set<String>
    var proxy: PhotoGridProxy
    /// The dark shade under the Library title over the photos.
    var titleShade = true
    /// Long press shows `menu` (off in the photo picker).
    var contextMenus = true
    /// The asset under the top edge, nil when the grid rests at its newest
    /// end. Called when the month (or nil-ness) changes, not every frame.
    var onTop: (Int?) -> Void
    /// First and last asset on screen; called when either changes its day.
    var onRange: (Int, Int) -> Void = { _, _ in }
    /// The user is scrolling (finger down or the grid still gliding).
    var onScrolling: (Bool) -> Void = { _ in }
    /// Tap in selection mode.
    var onToggle: (Asset) -> Void
    var menu: (Asset) -> UIMenu
    var onRefresh: () async -> Void

    func makeUIViewController(context: Context) -> PhotoGridController {
        let c = PhotoGridController()
        proxy.controller = c
        c.apply(self)
        return c
    }

    func updateUIViewController(_ c: PhotoGridController, context: Context) {
        proxy.controller = c
        c.apply(self)
    }
}

/// Commands from SwiftUI into the grid (the scrubber).
@MainActor
final class PhotoGridProxy {
    weak var controller: PhotoGridController?
    /// Scroll so asset `position` is at the top.
    func jump(to position: Int) { controller?.jump(to: position) }
}

// MARK: - Controller

final class PhotoGridController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate,
                                 UIGestureRecognizerDelegate {
    private static let zoomLevels = [1, 3, 5, 9]
    private static let columnsKey = "photos.gridColumns"

    private let layout = PhotoGridLayout()
    private var collectionView: UICollectionView!
    private let refresh = UIRefreshControl()

    private var config: PhotoGrid?
    private var assets: [Asset] = []
    private var revision = -1
    private var selecting = false
    private var selected: Set<String> = []

    /// True while the grid rests at its newest end; it stays there when the
    /// library or the insets change.
    private var pinnedToBottom = true
    private var needsBottom = true
    private var lastTop: Int?? = .none
    private var lastTopMonth: String?
    private var pinchBase: CGFloat = 1
    private var prefetchTickets: [String: MediaCache.Ticket] = [:]
    /// The first seconds of the videos on screen, fetched when the grid rests.
    private var headTickets: [String: MediaFetch.Ticket] = [:]
    /// The photo the viewer shows now: where its zoom transition returns to.
    private var viewerAssetID: String?

    private var columns: Int {
        get {
            let n = UserDefaults.standard.integer(forKey: Self.columnsKey)
            return Self.zoomLevels.contains(n) ? n : 5
        }
        set { UserDefaults.standard.set(newValue, forKey: Self.columnsKey) }
    }

    /// Decode size of a cell, in pixels.
    private var pixels: Int { Int((layout.side * (view.window?.screen.scale ?? traitCollection.displayScale)).rounded(.up)) }

    override func viewDidLoad() {
        super.viewDidLoad()
        layout.columns = columns
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .systemBackground
        collectionView.showsVerticalScrollIndicator = false
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.alwaysBounceVertical = true
        // iOS scrolls the "top" into view when the selected tab is tapped
        // again (and on a status-bar tap). The top of this grid is the oldest
        // photo, so that jumped to the undated pictures; Photos goes to the
        // newest instead, which `scrollToNewest` does
        collectionView.scrollsToTop = false
        NotificationCenter.default.addObserver(self, selector: #selector(scrollToNewest),
                                               name: .atlasScrollToNewest, object: nil)
        collectionView.contentInsetAdjustmentBehavior = .always
        collectionView.register(PhotoCell.self, forCellWithReuseIdentifier: PhotoCell.reuseID)
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isPrefetchingEnabled = true
        refresh.addTarget(self, action: #selector(pulled), for: .valueChanged)
        collectionView.refreshControl = refresh
        view.addSubview(collectionView)
        // Photos keeps its large title over the photos instead of folding it
        // into the bar: the bar tracks this empty scroll view, not the grid,
        // and a soft shade under the title keeps it readable
        titleAnchor.isUserInteractionEnabled = false
        view.addSubview(titleAnchor)
        shade.colors = [UIColor.black.withAlphaComponent(0.6).cgColor, UIColor.black.withAlphaComponent(0.35).cgColor,
                        UIColor.black.withAlphaComponent(0).cgColor]
        view.layer.addSublayer(shade)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        pinch.delegate = self
        pinch.cancelsTouchesInView = false
        collectionView.addGestureRecognizer(pinch)
        #if targetEnvironment(simulator)
        startBenchmarkIfAsked()
        #endif
    }

    #if targetEnvironment(simulator)
    // ATLAS_BENCH=<points per second> flings the grid upwards for 10 s after
    // launch and prints frame statistics (main-thread time per frame).
    private var benchLink: CADisplayLink?
    private var benchStart: CFTimeInterval = 0
    private var benchLast: CFTimeInterval = 0
    private var benchFrames: [Double] = []
    private var benchSpeed: CGFloat = 0

    private func startBenchmarkIfAsked() {
        // ATLAS_DEMO=open | open-close | select: drives the grid for screenshots
        if let demo = ProcessInfo.processInfo.environment["ATLAS_DEMO"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, self.assets.count > 10 else { return }
                switch demo {
                case "select":
                    for (n, cell) in self.collectionView.visibleCells.enumerated() {
                        (cell as? PhotoCell)?.setSelection(selecting: true, picked: n % 3 == 0, animated: true, entering: true)
                    }
                default:
                    let t0 = CACurrentMediaTime()
                    // ATLAS_OPEN=<asset id> opens that photo (screenshot comparisons)
                    let want = ProcessInfo.processInfo.environment["ATLAS_OPEN"]
                    self.open(self.assets.first { $0.id == want } ?? self.assets[self.assets.count - 3])
                    print(String(format: "ATLAS_BENCH open: present() returned after %.1f ms", (CACurrentMediaTime() - t0) * 1000))
                    DispatchQueue.main.async {
                        print(String(format: "ATLAS_BENCH open: first runloop turn after %.1f ms", (CACurrentMediaTime() - t0) * 1000))
                    }
                    self.transitionCoordinator?.animate(alongsideTransition: nil) { _ in
                        print(String(format: "ATLAS_BENCH open: transition finished after %.1f ms", (CACurrentMediaTime() - t0) * 1000))
                    }
                    if demo == "open-close" || demo == "open-twice" {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.dismiss(animated: true) }
                    }
                    if demo == "open-twice" {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 7) {
                            let t1 = CACurrentMediaTime()
                            self.open(self.assets[self.assets.count - 40])
                            DispatchQueue.main.async {
                                print(String(format: "ATLAS_BENCH open again: first runloop turn after %.1f ms", (CACurrentMediaTime() - t1) * 1000))
                            }
                        }
                    }
                }
            }
        }
        guard let v = ProcessInfo.processInfo.environment["ATLAS_BENCH"], let speed = Double(v) else { return }
        benchSpeed = CGFloat(speed)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self else { return }
            let link = CADisplayLink(target: self, selector: #selector(self.benchTick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 120, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            self.benchLink = link
        }
    }

    @objc private func benchTick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        if benchStart == 0 { benchStart = now; benchLast = now; return }
        benchFrames.append((now - benchLast) * 1000)
        let dt = CGFloat(now - benchLast)
        benchLast = now
        let y = max(collectionView.contentOffset.y - benchSpeed * dt, -collectionView.adjustedContentInset.top)
        collectionView.contentOffset.y = y
        if now - benchStart > 10 {
            link.invalidate()
            let sorted = benchFrames.sorted()
            let p = { (q: Double) in sorted[min(Int(Double(sorted.count) * q), sorted.count - 1)] }
            // the simulator's display runs at 60 Hz: a frame over 1.5 × 16.7 ms is a drop
            let budget = 25.0
            print(String(format: "ATLAS_BENCH speed=%.0f frames=%d mean=%.2fms p50=%.2f p95=%.2f p99=%.2f max=%.2f dropped=%d rows=%.0f",
                         Double(benchSpeed), sorted.count, sorted.reduce(0, +) / Double(sorted.count),
                         p(0.5), p(0.95), p(0.99), sorted.last ?? 0, sorted.filter { $0 > budget }.count,
                         Double(benchSpeed) * 10 / Double(layout.pitch)))
            print("ATLAS_BENCH cells=\(PhotoCell.shown) shownBlank=\(PhotoCell.blank)")
        }
    }
    #endif

    func apply(_ grid: PhotoGrid) {
        config = grid
        MediaCache.shared.client = grid.library.client
        guard isViewLoaded else { return }
        shade.isHidden = !grid.titleShade
        if grid.revision != revision {
            revision = grid.revision
            assets = grid.assets
            selecting = grid.selecting
            selected = grid.selected
            collectionView.reloadData()
            if pinnedToBottom { needsBottom = true; view.setNeedsLayout() }
            return
        }
        if grid.selecting != selecting || grid.selected != selected {
            let enter = grid.selecting != selecting
            selecting = grid.selecting
            selected = grid.selected
            for case let cell as PhotoCell in collectionView.visibleCells {
                guard let id = cell.assetID else { continue }
                cell.setSelection(selecting: selecting, picked: selected.contains(id), animated: true, entering: enter)
            }
        }
    }

    private let titleAnchor = UIScrollView(frame: .zero)
    private let shade = CAGradientLayer()

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        var vc: UIViewController? = self
        while let c = vc, !(c.parent is UINavigationController) {
            c.setContentScrollView(titleAnchor, for: .top)
            vc = c.parent
        }
        vc?.setContentScrollView(titleAnchor, for: .top)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shade.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: (view.window?.safeAreaInsets.top ?? 62) + 100)
        CATransaction.commit()
        if needsBottom, !assets.isEmpty, collectionView.bounds.height > 0,
           !collectionView.isTracking, !collectionView.isDecelerating {
            scrollToBottom()
            needsBottom = false
        }
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        // the status bar coming back after the viewer must not move the grid
        // under the photo flying home
        guard presentedViewController == nil, transitionCoordinator == nil else { return }
        if pinnedToBottom { needsBottom = true; view.setNeedsLayout() }
    }

    override func viewWillTransition(to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        let anchor = topIndex
        coordinator.animate(alongsideTransition: { _ in
            if self.pinnedToBottom { self.scrollToBottom() } else if let anchor { self.scroll(toItem: anchor) }
        })
    }

    @objc private func scrollToNewest() {
        guard isViewLoaded, !assets.isEmpty else { return }
        collectionView.layoutIfNeeded()
        let inset = collectionView.adjustedContentInset
        let y = max(layout.collectionViewContentSize.height + inset.bottom - collectionView.bounds.height, -inset.top)
        collectionView.setContentOffset(CGPoint(x: 0, y: y), animated: true)
        pinnedToBottom = true
    }

    private func scrollToBottom() {
        collectionView.layoutIfNeeded()
        let inset = collectionView.adjustedContentInset
        let y = max(layout.collectionViewContentSize.height + inset.bottom - collectionView.bounds.height, -inset.top)
        collectionView.setContentOffset(CGPoint(x: 0, y: y), animated: false)
        reportTop()
    }

    private func scroll(toItem item: Int) {
        let inset = collectionView.adjustedContentInset
        let row = item / max(layout.columns, 1)
        let maxY = max(layout.collectionViewContentSize.height + inset.bottom - collectionView.bounds.height, -inset.top)
        let y = min(max(CGFloat(row) * layout.pitch - inset.top, -inset.top), maxY)
        collectionView.setContentOffset(CGPoint(x: 0, y: y), animated: false)
        reportTop()
    }

    func jump(to position: Int) {
        guard isViewLoaded, !assets.isEmpty else { return }
        pinnedToBottom = false
        needsBottom = false
        // like before: never further down than where the newest photos fill
        // the lower part of the screen
        let inset = collectionView.adjustedContentInset
        let row = position / max(layout.columns, 1)
        let limit = max(layout.collectionViewContentSize.height - collectionView.bounds.height * 0.6, 0)
        let y = min(CGFloat(row) * layout.pitch, limit) - inset.top
        collectionView.setContentOffset(CGPoint(x: 0, y: y), animated: false)
        reportTop()
    }

    // MARK: Position reporting

    private var atBottom: Bool {
        let inset = collectionView.adjustedContentInset
        return collectionView.contentOffset.y + collectionView.bounds.height - inset.bottom
            >= layout.collectionViewContentSize.height - layout.pitch
    }

    /// The asset under the top edge of the screen (below the bars).
    private var topIndex: Int? {
        guard !assets.isEmpty else { return nil }
        let y = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        let row = Int((max(y, 0) / max(layout.pitch, 1)).rounded(.down))
        return min(row * layout.columns, assets.count - 1)
    }

    private var lastRangeDays: (Int, Int)?

    /// The days of the first and last photo on screen (for the title).
    private func reportRange() {
        guard let config, !assets.isEmpty, let top = topIndex else { return }
        let inset = collectionView.adjustedContentInset
        let y = collectionView.contentOffset.y + collectionView.bounds.height - inset.bottom
        let row = Int((max(y, 0) / max(layout.pitch, 1)).rounded(.down))
        let bottom = min(max((row + 1) * layout.columns - 1, top), assets.count - 1)
        func day(_ i: Int) -> Int { Int((assets[i].takenAt?.timeIntervalSince1970 ?? 0) / 86_400) }
        let days = (day(top), day(bottom))
        if let last = lastRangeDays, last == days { return }
        lastRangeDays = days
        config.onRange(top, bottom)
    }

    private func reportTop() {
        reportRange()
        guard let config, !assets.isEmpty else { return }
        let next: Int? = atBottom ? nil : topIndex
        let month = next.flatMap { config.library.month(at: $0)?.key }
        if case .some(let last) = lastTop, (last == nil) == (next == nil), month == lastTopMonth { return }
        lastTop = .some(next)
        lastTopMonth = month
        config.onTop(next)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        reportTop()
        updatePrefetch()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        pinnedToBottom = false
        needsBottom = false
        config?.onScrolling(true)
        MediaFetch.shared.setInteracting(true)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            pinnedToBottom = atBottom
            config?.onScrolling(false)
            scrollingEnded()
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        pinnedToBottom = atBottom
        config?.onScrolling(false)
        scrollingEnded()
    }

    private func scrollingEnded() {
        MediaFetch.shared.setInteracting(false)
        prefetchVideoHeads()
    }

    /// The grid came to rest: the first seconds of the videos on screen come
    /// onto the phone (Wi-Fi only), so a tap starts them at once. Videos that
    /// scrolled away are dropped from the queue.
    private func prefetchVideoHeads() {
        let client = MediaCache.shared.client
        var keep: [String: MediaFetch.Ticket] = [:]
        for ip in collectionView.indexPathsForVisibleItems where ip.item < assets.count {
            let asset = assets[ip.item]
            guard asset.isVideo, let url = client.streamURL(asset.id) else { continue }
            keep[asset.id] = headTickets[asset.id]
                ?? VideoCache.shared.prefetchHead(id: asset.id, remote: url, duration: asset.durationS,
                                                  priority: .near, expensive: false)
        }
        for (id, t) in headTickets where keep[id] == nil { t.cancel() }
        headTickets = keep
    }

    // MARK: Data source

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { assets.count }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: PhotoCell.reuseID, for: indexPath) as! PhotoCell
        let asset = assets[indexPath.item]
        cell.configure(asset, pixels: pixels, single: layout.columns == 1,
                       selecting: selecting, picked: selected.contains(asset.id))
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        (cell as? PhotoCell)?.stopLoading()
    }

    // UIKit's own prefetching looks less than a screen ahead; at fling speed
    // that is a few frames. The grid keeps its own window instead: about two
    // screens in the direction of travel and half a screen behind, updated
    // when a row boundary is crossed, and whatever falls out of it is
    // cancelled before it costs anything.
    private var prefetchRange: Range<Int> = 0..<0
    private var lastOffsetY: CGFloat = 0
    private var scrollingUp = true

    private func updatePrefetch() {
        guard !assets.isEmpty, layout.pitch > 1 else { return }
        let y = collectionView.contentOffset.y
        if abs(y - lastOffsetY) > 1 { scrollingUp = y < lastOffsetY }
        lastOffsetY = y
        let screenRows = Int((collectionView.bounds.height / layout.pitch).rounded(.up))
        let firstRow = Int((max(y + collectionView.adjustedContentInset.top, 0) / layout.pitch).rounded(.down))
        let lastRow = firstRow + screenRows
        let ahead = screenRows * 2, behind = screenRows / 2
        let lo = scrollingUp ? firstRow - ahead : firstRow - behind
        let hi = scrollingUp ? lastRow + behind : lastRow + ahead
        let cols = layout.columns
        let count = assets.count
        // every bound clamped into 0...count: while the column count changes
        // or the grid bounces past an end, the rows computed from the offset
        // can lie outside the library, and an inverted range traps
        func clamp(_ v: Int) -> Int { min(max(v, 0), count) }
        let lower = clamp(lo * cols)
        let range = lower..<max(clamp((hi + 1) * cols), lower)
        guard range != prefetchRange, !range.isEmpty else { return }
        prefetchRange = range
        let px = pixels
        var keep = Set<String>()
        // nearest first: the queue is FIFO within a priority
        let visLower = min(max(clamp(firstRow * cols), range.lowerBound), range.upperBound)
        let visible = visLower..<min(max(clamp((lastRow + 1) * cols), visLower), range.upperBound)
        let order: [Int] = scrollingUp
            ? Array(range.lowerBound..<max(visible.lowerBound, range.lowerBound)).reversed() + Array(min(visible.upperBound, range.upperBound)..<range.upperBound)
            : Array(min(visible.upperBound, range.upperBound)..<range.upperBound) + Array(range.lowerBound..<max(visible.lowerBound, range.lowerBound)).reversed()
        for i in order {
            let id = assets[i].id
            keep.insert(id)
            guard prefetchTickets[id] == nil, MediaCache.shared.gridImage(id: id, pixels: px) == nil else { continue }
            prefetchTickets[id] = MediaCache.shared.requestGrid(id: id, pixels: px, urgent: false) { [weak self] _ in
                self?.prefetchTickets[id] = nil
            }
        }
        for (id, t) in prefetchTickets where !keep.contains(id) {
            t.cancel()
            prefetchTickets[id] = nil
        }
    }

    // MARK: Tap → viewer

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        guard indexPath.item < assets.count, let config else { return }
        let asset = assets[indexPath.item]
        if selecting {
            config.onToggle(asset)
        } else {
            open(asset)
        }
    }

    private func open(_ asset: Asset) {
        guard let config, presentedViewController == nil else { return }
        viewerAssetID = asset.id
        let viewer = ViewerScreen(library: config.library, assets: assets, start: asset,
                                  onClose: { [weak self] in self?.dismiss(animated: true) },
                                  onPage: { [weak self] in self?.viewerAssetID = $0.id })
            // the viewer's chrome is monochrome, like Photos; the rest of the app is system blue
            .tint(.primary)
        let host = UIHostingController(rootView: viewer)
        host.modalPresentationStyle = .fullScreen
        host.modalPresentationCapturesStatusBarAppearance = true
        // swipe-down-to-close only for a clearly downward drag: a sideways
        // swipe to the next photo must never be read as "close", whatever
        // state the neighbouring page is in
        let options = UIViewController.Transition.ZoomOptions()
        options.interactiveDismissShouldBegin = { context in
            let v = context.velocity
            return context.willBegin && v.dy > 0 && v.dy > abs(v.dx) * 1.5
        }
        host.preferredTransition = .zoom(options: options) { [weak self] _ in self?.zoomSource() }
        present(host, animated: true)
    }

    /// The cell of the photo the viewer shows, scrolled into view if needed.
    private func zoomSource() -> UIView? {
        guard let id = viewerAssetID, let item = assets.firstIndex(where: { $0.id == id }) else { return nil }
        let ip = IndexPath(item: item, section: 0)
        if collectionView.cellForItem(at: ip) == nil {
            pinnedToBottom = false
            collectionView.scrollToItem(at: ip, at: .centeredVertically, animated: false)
            collectionView.layoutIfNeeded()
            reportTop()
        }
        return collectionView.cellForItem(at: ip)
    }

    // MARK: Context menu

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
                        point: CGPoint) -> UIContextMenuConfiguration? {
        guard let ip = indexPaths.first, ip.item < assets.count, let config, config.contextMenus else { return nil }
        let asset = assets[ip.item]
        let client = config.library.client
        return UIContextMenuConfiguration(identifier: asset.id as NSString, previewProvider: {
            let host = UIHostingController(rootView: ContextPreview(asset: asset, client: client))
            host.preferredContentSize = ContextPreview.size(for: asset)
            return host
        }, actionProvider: { _ in config.menu(asset) })
    }

    // MARK: Pull to refresh

    @objc private func pulled() {
        guard let config else { refresh.endRefreshing(); return }
        Task {
            await config.onRefresh()
            refresh.endRefreshing()
        }
    }

    // MARK: Pinch zoom (1/3/5/9 columns)

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    /// Steps are switched DURING the gesture (thresholds 1.25 / 0.8 relative
    /// to the last step), so one long pinch runs through several.
    @objc private func pinched(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began:
            pinchBase = 1
        case .changed:
            let ratio = g.scale / pinchBase
            if ratio > 1.25 {
                pinchBase = g.scale
                step(zoomIn: true)
            } else if ratio < 0.8 {
                pinchBase = g.scale
                step(zoomIn: false)
            }
        default:
            pinchBase = 1
        }
    }

    private func step(zoomIn: Bool) {
        let levels = Self.zoomLevels
        guard let i = levels.firstIndex(of: layout.columns) else { return }
        let next = zoomIn ? i - 1 : i + 1
        guard levels.indices.contains(next) else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        // keep the photo at the top of the screen in place across densities
        let anchor = topIndex
        columns = levels[next]
        layout.columns = levels[next]
        for t in prefetchTickets.values { t.cancel() }
        prefetchTickets = [:]
        prefetchRange = 0..<0
        collectionView.reloadData()
        collectionView.layoutIfNeeded()
        if pinnedToBottom { scrollToBottom() } else if let anchor { scroll(toItem: anchor) }
    }
}

// MARK: - Layout

/// Square cells, 5 px apart (measured on Photos), edge to edge; every position is arithmetic, so
/// a layout pass costs the same for 25,000 photos as for 25.
final class PhotoGridLayout: UICollectionViewLayout {
    static let spacing: CGFloat = 5 / 3

    var columns = 5 { didSet { if columns != oldValue { invalidateLayout() } } }
    private(set) var side: CGFloat = 1
    private var count = 0
    private var width: CGFloat = 0
    private var originX: CGFloat = 0

    var pitch: CGFloat { side + Self.spacing }
    private var rows: Int { (count + columns - 1) / max(columns, 1) }

    override func prepare() {
        super.prepare()
        guard let cv = collectionView else { return }
        count = cv.numberOfSections > 0 ? cv.numberOfItems(inSection: 0) : 0
        // landscape: stay inside the horizontal safe area, like before
        originX = cv.safeAreaInsets.left
        width = max(cv.bounds.width - cv.safeAreaInsets.left - cv.safeAreaInsets.right, 1)
        side = max((width - Self.spacing * CGFloat(columns - 1)) / CGFloat(columns), 1)
    }

    override var collectionViewContentSize: CGSize {
        CGSize(width: collectionView?.bounds.width ?? 0, height: max(CGFloat(rows) * pitch - Self.spacing, 0))
    }

    private func attributes(_ item: Int) -> UICollectionViewLayoutAttributes {
        let a = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: item, section: 0))
        let row = item / columns, col = item % columns
        a.frame = CGRect(x: originX + CGFloat(col) * pitch, y: CGFloat(row) * pitch, width: side, height: side)
        return a
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        guard count > 0 else { return [] }
        let first = max(Int((rect.minY / pitch).rounded(.down)), 0)
        let last = min(Int((rect.maxY / pitch).rounded(.up)), rows - 1)
        guard first <= last else { return [] }
        var out: [UICollectionViewLayoutAttributes] = []
        out.reserveCapacity((last - first + 1) * columns)
        for item in (first * columns)..<min((last + 1) * columns, count) { out.append(attributes(item)) }
        return out
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        indexPath.item < count ? attributes(indexPath.item) : nil
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        guard let cv = collectionView else { return false }
        return newBounds.width != cv.bounds.width
    }
}

// MARK: - Cell

final class PhotoCell: UICollectionViewCell {
    static let reuseID = "PhotoCell"
    #if targetEnvironment(simulator)
    static var shown = 0, blank = 0
    #endif

    private let imageView = UIImageView()
    private let dim = UIView()
    /// Videos show their length, bottom right, like Photos.
    private let duration = UILabel()
    private let checkBadge = UIImageView()

    private(set) var assetID: String?
    private var isVideo = false
    private var pixels = 0
    private var ticket: MediaCache.Ticket?
    private var sharpTask: Task<Void, Never>?
    private var selecting = false
    private var picked = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.clipsToBounds = true
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.backgroundColor = .secondarySystemFill
        imageView.frame = contentView.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(imageView)

        dim.backgroundColor = UIColor.black.withAlphaComponent(0.18)
        dim.layer.cornerRadius = 9
        dim.layer.cornerCurve = .continuous
        dim.frame = contentView.bounds
        dim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        dim.alpha = 0
        contentView.addSubview(dim)

        duration.font = .systemFont(ofSize: 13, weight: .semibold)
        duration.textColor = .white
        duration.layer.shadowColor = UIColor.black.cgColor
        duration.layer.shadowOpacity = 0.35
        duration.layer.shadowRadius = 2
        duration.layer.shadowOffset = .zero
        duration.isHidden = true
        contentView.addSubview(duration)
        checkBadge.alpha = 0
        contentView.addSubview(checkBadge)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let b = contentView.bounds
        let d = duration.intrinsicContentSize
        duration.frame = CGRect(x: b.maxX - 6 - d.width, y: b.maxY - 4 - d.height, width: d.width, height: d.height)
        // the check sits 3 pt in from the corner; the image carries its shadow margin
        let s = checkBadge.image?.size ?? .zero
        checkBadge.bounds = CGRect(origin: .zero, size: s)
        checkBadge.center = CGPoint(x: b.maxX - 3 - (s.width - PhotoCell.shadowPad * 2) / 2,
                                    y: b.maxY - 3 - (s.height - PhotoCell.shadowPad * 2) / 2)
    }

    func configure(_ asset: Asset, pixels: Int, single: Bool, selecting: Bool, picked: Bool) {
        let same = asset.id == assetID && pixels == self.pixels
        isVideo = asset.isVideo
        if let secs = asset.durationS, asset.isVideo {
            let t = Int(secs.rounded())
            duration.text = t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
                                      : String(format: "%d:%02d", t / 60, t % 60)
        } else {
            duration.text = nil
        }
        setSelection(selecting: selecting, picked: picked, animated: false, entering: false)
        guard !same || imageView.image == nil else { return }
        stopLoading()
        assetID = asset.id
        self.pixels = pixels
        let id = asset.id
        #if targetEnvironment(simulator)
        Self.shown += 1
        #endif
        if let img = MediaCache.shared.gridImage(id: id, pixels: pixels) {
            imageView.image = img
        } else {
            #if targetEnvironment(simulator)
            Self.blank += 1
            #endif
            imageView.image = nil
            ticket = MediaCache.shared.requestGrid(id: id, pixels: pixels, urgent: true) { [weak self] img in
                guard let self, self.assetID == id else { return }
                self.ticket = nil
                self.imageView.image = img
            }
        }
        if single, !asset.isVideo, let url = MediaCache.shared.client.thumbURL(id, 2048) {
            // one photo per row: the 2048 preview, sharp at full width
            let px = CGFloat(pixels)
            sharpTask = Task { [weak self] in
                guard let img = await MediaCache.shared.load(url, maxPixel: px * 1.5),
                      let self, self.assetID == id, !Task.isCancelled else { return }
                self.imageView.image = img
            }
        }
    }

    func stopLoading() {
        ticket?.cancel()
        ticket = nil
        sharpTask?.cancel()
        sharpTask = nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        stopLoading()
    }

    func setSelection(selecting: Bool, picked: Bool, animated: Bool, entering: Bool) {
        let changed = selecting != self.selecting || picked != self.picked
        self.selecting = selecting
        self.picked = picked
        let apply = {
            // Photos: the picture stays as it is; a picked one gets the blue check,
            // an unpicked one nothing
            self.duration.isHidden = !self.isVideo || picked
            self.checkBadge.image = PhotoCell.checkOn
            self.checkBadge.alpha = selecting && picked ? 1 : 0
            self.checkBadge.transform = selecting && picked ? .identity : CGAffineTransform(scaleX: 0.5, y: 0.5)
            self.setNeedsLayout()
        }
        if animated && changed {
            UIView.animate(springDuration: entering ? 0.35 : 0.26, bounce: 0.05, options: [.allowUserInteraction, .beginFromCurrentState]) {
                apply()
                self.layoutIfNeeded()
            }
        } else {
            apply()
        }
    }

    // MARK: Badges, drawn once with their shadow baked in (a live layer
    // shadow on every cell would be an offscreen pass per frame)

    fileprivate static let shadowPad: CGFloat = 4

    /// White check on a blue disc with a white rim, as in Photos.
    static let checkOn: UIImage = {
        let d: CGFloat = 20, pad = shadowPad
        return UIGraphicsImageRenderer(size: CGSize(width: d + pad * 2, height: d + pad * 2)).image { ctx in
            let c = ctx.cgContext
            c.setShadow(offset: .zero, blur: 3, color: UIColor.black.withAlphaComponent(0.25).cgColor)
            UIColor.white.setFill()
            c.fillEllipse(in: CGRect(x: pad, y: pad, width: d, height: d))
            c.setShadow(offset: .zero, blur: 0, color: nil)
            UIColor.systemBlue.setFill()
            c.fillEllipse(in: CGRect(x: pad + 1.5, y: pad + 1.5, width: d - 3, height: d - 3))
            let cfg = UIImage.SymbolConfiguration(pointSize: 10, weight: .bold)
            if let check = UIImage(systemName: "checkmark", withConfiguration: cfg)?
                .withTintColor(.white, renderingMode: .alwaysOriginal) {
                check.draw(at: CGPoint(x: pad + (d - check.size.width) / 2, y: pad + (d - check.size.height) / 2))
            }
        }
    }()
}

extension Notification.Name {
    /// Re-tap on the Library tab: show the newest photos.
    static let atlasScrollToNewest = Notification.Name("atlas.scrollToNewest")
}
