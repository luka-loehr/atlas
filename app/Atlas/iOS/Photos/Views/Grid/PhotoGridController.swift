import SwiftUI
import UIKit

final class PhotoGridController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate,
                                 UIGestureRecognizerDelegate {
    static let zoomLevels = [1, 3, 5, 9]
    /// The photos per row every grid opens with (Settings).
    static let defaultColumnsKey = "photos.gridColumnsDefault"
    /// What a pinch chose, for every grid until the app quits: the next
    /// launch opens at the default again.
    private static var pinched: Int?

    let layout = PhotoGridLayout()
    private(set) var collectionView: UICollectionView!
    private let refresh = UIRefreshControl()

    private var config: PhotoGrid?
    private(set) var assets: [Asset] = []
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
    /// Sharp tiles being decoded ahead of the cells.
    private var prefetchOps: [String: Operation] = [:]
    /// The first seconds of the videos on screen, fetched when the grid rests.
    private var headTickets: [String: MediaFetch.Ticket] = [:]
    /// The photo the viewer shows now: where its zoom transition returns to.
    private var viewerAssetID: String?
    #if targetEnvironment(simulator)
    private var benchmark: PhotoGridBenchmark?
    #endif

    private var columns: Int {
        get { Self.pinched ?? Self.defaultColumns }
        set { Self.pinched = newValue }
    }

    static var defaultColumns: Int {
        let n = UserDefaults.standard.integer(forKey: defaultColumnsKey)
        return zoomLevels.contains(n) ? n : 5
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
        benchmark = PhotoGridBenchmark.startIfAsked(self)
        #endif
    }

    func apply(_ grid: PhotoGrid) {
        config = grid
        MediaCache.shared.client = grid.library.client
        guard isViewLoaded else { return }
        // photos under the title: no blurred band behind the bar (the
        // shade keeps the title readable)
        collectionView.topEdgeEffect.isHidden = grid.titleShade
        shade.isHidden = !grid.titleShade
        if grid.revision != revision {
            revision = grid.revision
            // the same photos in the same places (a favorite flag changed):
            // the cells on screen are refreshed in place, nothing reloads
            let samePlaces = grid.assets.count == assets.count
                && zip(grid.assets, assets).allSatisfy { $0.id == $1.id }
            assets = grid.assets
            selecting = grid.selecting
            selected = grid.selected
            if samePlaces {
                collectionView.reconfigureItems(at: collectionView.indexPathsForVisibleItems)
                return
            }
            collectionView.reloadData()
            if pinnedToBottom {
                needsBottom = true
                view.setNeedsLayout()
            }
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

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // back from the viewer (however it was closed)
        if viewerAssetID != nil, presentedViewController == nil {
            viewerAssetID = nil
            config?.onViewerClosed()
        }
    }

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
        let tiles = GridTiles.shared
        for i in order {
            let id = assets[i].id
            keep.insert(id)
            guard prefetchTickets[id] == nil, prefetchOps[id] == nil, tiles.cachedSharp(id) == nil else { continue }
            if tiles.mini(id) != nil {
                // the tile into RAM ahead of the cell
                prefetchOps[id] = tiles.requestSharp(id, priority: .low) { [weak self] _ in
                    self?.prefetchOps[id] = nil
                }
                continue
            }
            guard MediaCache.shared.gridImage(id: id, pixels: px) == nil else { continue }
            prefetchTickets[id] = MediaCache.shared.requestGrid(id: id, pixels: px, urgent: false) { [weak self] _ in
                self?.prefetchTickets[id] = nil
            }
        }
        for (id, t) in prefetchTickets where !keep.contains(id) {
            t.cancel()
            prefetchTickets[id] = nil
        }
        for (id, op) in prefetchOps where !keep.contains(id) {
            op.cancel()
            prefetchOps[id] = nil
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

    func open(_ asset: Asset) {
        // an active search field is a presented search controller: the
        // viewer opens over it (anything else presented: not now)
        let presenter: UIViewController
        switch presentedViewController {
        case nil: presenter = self
        case let search as UISearchController where search.presentedViewController == nil: presenter = search
        default: return
        }
        guard let config else { return }
        viewerAssetID = asset.id
        // the viewer closes itself, whoever presented it (the grid, or the
        // search controller over it)
        let shown = WeakBox()
        let viewer = ViewerScreen(library: config.library, assets: assets, start: asset,
                                  onClose: { shown.controller?.dismiss(animated: true) },
                                  onPage: { [weak self] in self?.viewerAssetID = $0.id })
            // the viewer's chrome is monochrome, like Photos; the rest of the app is system blue
            .tint(.primary)
        let host = UIHostingController(rootView: viewer)
        shown.controller = host
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
        presenter.present(host, animated: true)
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
        for op in prefetchOps.values { op.cancel() }
        prefetchOps = [:]
        prefetchRange = 0..<0
        collectionView.reloadData()
        collectionView.layoutIfNeeded()
        if pinnedToBottom { scrollToBottom() } else if let anchor { scroll(toItem: anchor) }
    }
}

/// A weak reference a closure can capture before the object exists.
private final class WeakBox {
    weak var controller: UIViewController?
}
