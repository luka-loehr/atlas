import SwiftUI
import AppKit

/// The photo grid of the Mac app.
///
/// One view draws the whole grid with a recycled pool of Core Animation
/// layers, so scrolling a library of tens of thousands of photos costs what
/// moving a few dozen layers costs: no view per cell, no layer trees built,
/// no tracking areas, nothing decoded or color-matched on the main thread
/// (thumbnails come from the pinned store, decoded and converted to the
/// display's format on the decode queue). Only the rows on screen exist;
/// the rows a screen ahead are decoded in the background.
///
/// It behaves like the grids of Photos and the Finder: click selects,
/// ⌘-click and ⇧-click extend, dragging from below the photos draws a
/// selection rectangle, the arrow keys move the selection (⇧ extends it),
/// Return, Space or a double click opens, a right click opens the context
/// menu for what is selected, pinching zooms, ⌘A selects all. Photos drag
/// out as their originals (into the Finder, Mail, any app that takes files)
/// and onto an album in the sidebar.
struct MacPhotoGrid: NSViewRepresentable {
    let assets: [Asset]
    /// Changes whenever `assets` does; compared instead of the array.
    let revision: Int
    let cellSize: CGFloat
    @Binding var selection: Set<String>
    /// The library opens at its end, on the newest photos (like Photos).
    var startAtEnd = false
    /// A request to bring a photo into view (the one the viewer closed on).
    var reveal: String?
    var onOpen: (Asset) -> Void
    var menu: (Set<String>) -> NSMenu? = { _ in nil }
    var onTopIndex: (Int) -> Void = { _ in }
    var onFavoriteKey: () -> Void = {}
    var onZoom: (Int) -> Void = { _ in }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = true
        let grid = PhotoGridView()
        grid.host = self
        scroll.documentView = grid
        grid.attach(to: scroll)
        grid.cellSize = cellSize
        grid.load(assets, revision: revision, selection: selection, startAtEnd: startAtEnd)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let grid = scroll.documentView as? PhotoGridView else { return }
        grid.host = self
        if grid.revision != revision {
            grid.load(assets, revision: revision, selection: selection, startAtEnd: startAtEnd)
        }
        if grid.cellSize != cellSize { grid.resize(to: cellSize) }
        grid.sync(selection)
        if let reveal, reveal != grid.revealed {
            grid.revealed = reveal
            grid.reveal(reveal)
        }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: ()) {
        (scroll.documentView as? PhotoGridView)?.teardown()
    }
}

// MARK: - The grid view

/// A thumbnail request, cancellable like a tile operation.
private final class TicketCancel: Operation, @unchecked Sendable {
    private let ticket: MediaCache.Ticket
    init(_ ticket: MediaCache.Ticket) { self.ticket = ticket }
    override func cancel() {
        super.cancel()
        let ticket = ticket
        DispatchQueue.main.async { MainActor.assumeIsolated { ticket.cancel() } }
    }
}

final class PhotoGridView: NSView, NSDraggingSource, NSMenuItemValidation {
    var host: MacPhotoGrid!
    private(set) var revision = -1
    private(set) var assets: [Asset] = []
    private var indexByID: [String: Int] = [:]
    var revealed: String?

    var cellSize: CGFloat = 120
    private let spacing: CGFloat = 2

    // what is on screen
    private var visible: [Int: PhotoCellLayer] = [:]
    private var pool: [PhotoCellLayer] = []
    private var prefetches: [Int: Operation] = [:]
    private var lastTop = -1
    private var lastY: CGFloat = 0
    /// The photo in the middle of the window as last laid out: a resize
    /// keeps it in the middle (computed before the width changed, since
    /// after it the old scroll position means another photo).
    private var middle: Int?

    // selection
    private(set) var selected: Set<Int> = []
    private var anchor: Int?
    private var cursor: Int?
    private var band: CAShapeLayer?

    private var observers: [NSObjectProtocol] = []
    private var magnification: CGFloat = 0
    private var openedAtEnd = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.masksToBounds = false
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
        setAccessibilityLabel("Photos")
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}

    private var clip: NSClipView? { enclosingScrollView?.contentView }

    func attach(to scroll: NSScrollView) {
        let clip = scroll.contentView
        clip.postsBoundsChangedNotifications = true
        clip.postsFrameChangedNotifications = true
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tile() }
        })
        observers.append(center.addObserver(forName: NSView.frameDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // the window resized: the end stays the end, else the photo
                // in the middle stays in the middle
                let atEnd = self.host.startAtEnd && self.isAtEnd
                self.relayout(keeping: !atEnd)
                if atEnd { self.scrollToEnd() }
            }
        })
        // background downloads wait while the grid is being scrolled
        observers.append(center.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: scroll, queue: .main) { _ in
            MainActor.assumeIsolated { MediaFetch.shared.setInteracting(true) }
        })
        observers.append(center.addObserver(forName: NSScrollView.didEndLiveScrollNotification, object: scroll, queue: .main) { _ in
            MainActor.assumeIsolated { MediaFetch.shared.setInteracting(false) }
        })
    }

    func teardown() {
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        for cell in visible.values { cell.reset() }
        for t in prefetches.values { t.cancel() }
        prefetches = [:]
    }

    // MARK: Geometry

    private var width: CGFloat { clip?.bounds.width ?? bounds.width }
    var columns: Int { max(1, Int(((width + spacing) / (cellSize + spacing)).rounded())) }
    private var side: CGFloat {
        let n = CGFloat(columns)
        return floor((width - spacing * (n - 1)) / n * 2) / 2
    }
    private var rows: Int { (assets.count + columns - 1) / columns }
    private var contentHeight: CGFloat { max(0, CGFloat(rows) * (side + spacing) - spacing) }

    func frame(of index: Int) -> CGRect {
        let n = columns, s = side
        let row = index / n, col = index % n
        // the last column takes up the rounding, so the right edge is flush
        let x = CGFloat(col) * (s + spacing)
        let w = col == n - 1 ? width - x : s
        return CGRect(x: x, y: CGFloat(row) * (s + spacing), width: w, height: s)
    }

    func index(at point: CGPoint) -> Int? {
        guard !assets.isEmpty, point.y >= 0, point.x >= 0 else { return nil }
        let s = side + spacing
        let row = Int(point.y / s), col = min(Int(point.x / s), columns - 1)
        let i = row * columns + col
        guard i < assets.count, frame(of: i).contains(point) else { return nil }
        return i
    }

    private func indices(in rect: CGRect) -> Range<Int> {
        guard !assets.isEmpty else { return 0..<0 }
        let s = side + spacing
        let first = max(0, Int(floor(rect.minY / s))) * columns
        let last = min(assets.count, (Int(floor(rect.maxY / s)) + 1) * columns)
        return first < last ? first..<last : 0..<0
    }

    /// Pixels a thumbnail decodes at: the cell, at most the 512 the server
    /// makes, in steps of 32 so neighbouring zooms share decodes.
    private var pixels: Int {
        let scale = window?.backingScaleFactor ?? 2
        return min(512, Int((side * scale / 32).rounded(.up)) * 32)
    }

    // MARK: Data

    func load(_ new: [Asset], revision: Int, selection ids: Set<String>, startAtEnd: Bool) {
        let wasAtEnd = isAtEnd
        let first = assets.isEmpty
        assets = new
        self.revision = revision
        var map: [String: Int] = [:]
        map.reserveCapacity(new.count)
        for (i, a) in new.enumerated() { map[a.id] = i }
        indexByID = map
        selected = Set(ids.compactMap { map[$0] })
        // every cell shows anew: positions moved
        for (_, cell) in visible { recycle(cell) }
        visible = [:]
        for t in prefetches.values { t.cancel() }
        prefetches = [:]
        relayout(keeping: false)
        if startAtEnd, !new.isEmpty, !openedAtEnd || wasAtEnd || first {
            // the newest photos in view: at first, and after new ones
            // arrived while the end was in view
            openedAtEnd = true
            scrollToEnd()
        }
    }

    private var isAtEnd: Bool {
        guard let clip else { return true }
        return clip.bounds.maxY >= frame.height - cellSize
    }

    /// The frame follows the content; the photo in the middle stays put.
    private func relayout(keeping: Bool) {
        guard let clip else { return }
        let anchorIndex = keeping ? middle : nil
        let size = NSSize(width: clip.bounds.width, height: max(contentHeight, 0))
        if frame.size != size { setFrameSize(size) }
        if let anchorIndex {
            let f = frame(of: anchorIndex)
            scrollClip(to: f.midY - clip.bounds.height / 2)
        }
        for (i, cell) in visible { cell.frame = frame(of: i) }
        tile(force: true)
    }

    private func index(near point: CGPoint) -> Int? {
        guard !assets.isEmpty else { return nil }
        let s = side + spacing
        let row = max(0, Int(point.y / s)), col = min(max(0, Int(point.x / s)), columns - 1)
        return min(row * columns + col, assets.count - 1)
    }

    func resize(to size: CGFloat) {
        cellSize = size
        relayout(keeping: true)
        // the cells on screen decode at their new size
        let px = pixels
        for (i, cell) in visible { if let a = assets[safe: i] { cell.show(a, pixels: px, force: true) } }
    }

    func scrollToEnd() {
        guard let clip else { return }
        scrollClip(to: frame.height - clip.bounds.height)
    }

    private func scrollClip(to y: CGFloat) {
        guard let clip, let scroll = enclosingScrollView else { return }
        let top = -clip.contentInsets.top
        let maxY = max(top, frame.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: 0, y: min(max(y, top), maxY)))
        scroll.reflectScrolledClipView(clip)
    }

    func reveal(_ id: String) {
        guard let i = indexByID[id] else { return }
        scrollIntoView(i, center: true)
    }

    private func scrollIntoView(_ i: Int, center: Bool = false) {
        guard let clip else { return }
        let f = frame(of: i)
        var visibleRect = clip.bounds
        visibleRect.origin.y += clip.contentInsets.top
        visibleRect.size.height -= clip.contentInsets.top
        if visibleRect.contains(f) { return }
        if center {
            scrollClip(to: f.midY - clip.bounds.height / 2)
        } else if f.minY < visibleRect.minY {
            scrollClip(to: f.minY - clip.contentInsets.top - spacing)
        } else {
            scrollClip(to: f.maxY - clip.bounds.height + spacing)
        }
    }

    // MARK: Tiling

    /// The layers on screen follow the scroll position: what left is
    /// recycled, what came in is taken from the pool.
    func tile(force: Bool = false) {
        guard let clip else { return }
        let rect = clip.bounds
        let wanted = indices(in: rect)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, cell) in visible where !wanted.contains(i) {
            recycle(cell)
            visible[i] = nil
        }
        let px = pixels
        for i in wanted where visible[i] == nil {
            let cell = pool.popLast() ?? PhotoCellLayer()
            if cell.superlayer == nil { layer?.addSublayer(cell) }
            cell.isHidden = false
            cell.frame = frame(of: i)
            cell.contentsScale = window?.backingScaleFactor ?? 2
            cell.selected = selected.contains(i)
            cell.show(assets[i], pixels: px)
            visible[i] = cell
        }
        if force { for (i, cell) in visible { cell.selected = selected.contains(i) } }
        CATransaction.commit()

        prefetch(around: rect, pixels: px)
        middle = index(near: CGPoint(x: rect.midX, y: rect.midY))
        // the month in the subtitle
        let top = index(near: CGPoint(x: 1, y: rect.minY + clip.contentInsets.top + 1)) ?? 0
        if top != lastTop {
            lastTop = top
            host?.onTopIndex(top)
        }
    }

    private func recycle(_ cell: PhotoCellLayer) {
        cell.reset()
        cell.isHidden = true
        pool.append(cell)
    }

    /// Three screens of rows in the direction of travel (and one behind)
    /// are decoded ahead into RAM; what fell out of reach is cancelled.
    private func prefetch(around rect: CGRect, pixels px: Int) {
        let down = rect.minY >= lastY
        lastY = rect.minY
        let ahead = rect.height * 3, behind = rect.height
        let reach = CGRect(x: 0, y: rect.minY - (down ? behind : ahead), width: rect.width,
                           height: rect.height + ahead + behind)
        let wanted = indices(in: reach)
        for (i, op) in prefetches where !wanted.contains(i) {
            op.cancel()
            prefetches[i] = nil
        }
        let tiles = GridTiles.shared
        let big = px > GridTiles.sharpSide + 32
        for i in wanted where visible[i] == nil && prefetches[i] == nil {
            let id = assets[i].id
            if big {
                guard MediaCache.shared.gridImage(id: id, pixels: px) == nil else { continue }
                let ticket = MediaCache.shared.requestGrid(id: id, pixels: px, urgent: false) { [weak self] _ in
                    self?.prefetches[i] = nil
                }
                prefetches[i] = TicketCancel(ticket)
            } else {
                guard tiles.cachedSharp(id) == nil else { continue }
                prefetches[i] = tiles.requestSharp(id, priority: .low) { [weak self] _ in self?.prefetches[i] = nil }
            }
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        for cell in visible.values + pool { cell.contentsScale = window?.backingScaleFactor ?? 2 }
        resize(to: cellSize)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            for cell in visible.values + pool { cell.applyColors() }
        }
    }

    // MARK: Selection

    func sync(_ ids: Set<String>) {
        let wanted = Set(ids.compactMap { indexByID[$0] })
        guard wanted != selected else { return }
        setSelected(wanted, notify: false)
    }

    private func setSelected(_ new: Set<Int>, notify: Bool = true) {
        let changed = new.symmetricDifference(selected)
        selected = new
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for i in changed { visible[i]?.selected = new.contains(i) }
        CATransaction.commit()
        if new.count <= 1 { anchor = new.first }
        guard notify else { return }
        let ids = Set(new.compactMap { assets[safe: $0]?.id })
        let binding = host.$selection
        // never while SwiftUI is updating this view
        DispatchQueue.main.async { if binding.wrappedValue != ids { binding.wrappedValue = ids } }
        NSAccessibility.post(element: self, notification: .selectedChildrenChanged)
    }

    private var focusIndex: Int? {
        if let cursor, selected.contains(cursor) { return cursor }
        return selected.max()
    }

    private func move(to index: Int, extend: Bool) {
        guard !assets.isEmpty else { return }
        let target = max(0, min(index, assets.count - 1))
        if extend, let anchor {
            setSelected(Set(min(anchor, target)...max(anchor, target)))
            self.anchor = anchor
        } else {
            setSelected([target])
            anchor = target
        }
        cursor = target
        scrollIntoView(target)
    }

    override func selectAll(_ sender: Any?) {
        setSelected(Set(assets.indices))
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.action == #selector(selectAll(_:)) ? !assets.isEmpty : true
    }

    private func open(_ i: Int?) {
        guard let i, let asset = assets[safe: i] else { return }
        host.onOpen(asset)
    }

    // MARK: Mouse

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let start = convert(event.locationInWindow, from: nil)
        let hit = index(at: start)
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.clickCount == 2, let hit {
            setSelected([hit])
            open(hit)
            return
        }
        let base = selected
        var deferredSelect: Int?
        if let hit {
            if mods.contains(.command) {
                var s = selected
                if s.contains(hit) { s.remove(hit) } else { s.insert(hit) }
                setSelected(s)
                anchor = hit
            } else if mods.contains(.shift), let anchor {
                setSelected(selected.union(min(anchor, hit)...max(anchor, hit)))
                self.anchor = anchor
            } else if selected.contains(hit) {
                // a click on a selected photo selects only it, unless it
                // turns into a drag of the selection
                deferredSelect = hit
            } else {
                setSelected([hit])
                anchor = hit
            }
            cursor = hit
        } else if !mods.contains(.command) && !mods.contains(.shift) {
            setSelected([])
        }

        // track: a drag from a photo drags the photos, from elsewhere draws
        // a selection rectangle
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let point = convert(next.locationInWindow, from: nil)
            if next.type == .leftMouseUp {
                if let deferredSelect { setSelected([deferredSelect]); anchor = deferredSelect }
                break
            }
            guard hypot(point.x - start.x, point.y - start.y) > 4 else { continue }
            if hit != nil {
                beginDrag(with: event)
                return
            }
            rubberBand(from: start, to: point, base: mods.contains(.command) || mods.contains(.shift) ? base : [])
            autoscroll(with: next)
        }
        band?.removeFromSuperlayer()
        band = nil
    }

    private func rubberBand(from a: CGPoint, to b: CGPoint, base: Set<Int>) {
        let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        if band == nil {
            let l = CAShapeLayer()
            l.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
            l.strokeColor = NSColor.controlAccentColor.cgColor
            l.lineWidth = 1
            l.zPosition = 10
            layer?.addSublayer(l)
            band = l
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        band?.path = CGPath(rect: rect, transform: nil)
        CATransaction.commit()
        let inside = indices(in: rect).filter { frame(of: $0).intersects(rect) }
        setSelected(base.union(inside))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if let i = index(at: point), !selected.contains(i) {
            setSelected([i])
            anchor = i
        }
        let ids = Set(selected.compactMap { assets[safe: $0]?.id })
        guard !ids.isEmpty else { return nil }
        // SwiftUI learns of the selection before the menu acts on it
        host.selection = ids
        return host.menu(ids)
    }

    // MARK: Dragging out

    private func beginDrag(with event: NSEvent) {
        let order = selected.sorted()
        guard !order.isEmpty else { return }
        let client = MediaCache.shared.client
        let origin = convert(event.locationInWindow, from: nil)
        let items: [NSDraggingItem] = order.prefix(1000).enumerated().map { n, i in
            let item = NSDraggingItem(pasteboardWriter: AssetFilePromise(asset: assets[i], client: client))
            let f = frame(of: i)
            let shown = visible[i]
            // a stack under the pointer, as the Finder drags several files
            let size = CGSize(width: min(f.width, 120), height: min(f.height, 120))
            let rect = shown != nil && n < 1 ? f : CGRect(x: origin.x - size.width / 2 + CGFloat(min(n, 4)) * 4,
                                                          y: origin.y - size.height / 2 + CGFloat(min(n, 4)) * 4,
                                                          width: size.width, height: size.height)
            let image = shown?.image.map { NSImage(cgImage: $0, size: rect.size) }
            item.setDraggingFrame(rect, contents: n < 5 ? image : nil)
            return item
        }
        let session = beginDraggingSession(with: items, event: event, source: self)
        session.draggingFormation = .stack
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    // MARK: Keyboard and gestures

    override func keyDown(with event: NSEvent) {
        let shift = event.modifierFlags.contains(.shift)
        let current = focusIndex
        let n = columns
        switch event.keyCode {
        case 36, 76, 49:    // Return, Enter, Space
            open(focusIndex ?? selected.min())
        case 123:           // ←
            move(to: (current ?? 1) - 1, extend: shift)
        case 124:           // →
            move(to: (current ?? -1) + 1, extend: shift)
        case 125:           // ↓
            move(to: current.map { min($0 + n, assets.count - 1) } ?? 0, extend: shift)
        case 126:           // ↑
            move(to: current.map { max($0 - n, 0) } ?? assets.count - 1, extend: shift)
        case 115:           // Home
            scrollClip(to: -(clip?.contentInsets.top ?? 0))
        case 119:           // End
            scrollToEnd()
        case 116:           // Page Up
            scrollClip(to: (clip?.bounds.minY ?? 0) - (clip?.bounds.height ?? 0) * 0.9)
        case 121:           // Page Down
            scrollClip(to: (clip?.bounds.minY ?? 0) + (clip?.bounds.height ?? 0) * 0.9)
        case 53:            // Esc
            setSelected([])
        default:
            if event.charactersIgnoringModifiers == ".", event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                host.onFavoriteKey()
            } else {
                super.keyDown(with: event)
            }
        }
    }

    override func magnify(with event: NSEvent) {
        if event.phase == .began { magnification = 0 }
        magnification += event.magnification
        if magnification > 0.3 {
            magnification = 0
            host.onZoom(1)
        } else if magnification < -0.3 {
            magnification = 0
            host.onZoom(-1)
        }
    }

    // MARK: Accessibility

    /// The photos on screen, as VoiceOver's children of the list.
    override func accessibilityChildren() -> [Any]? {
        visible.keys.sorted().compactMap { i -> NSAccessibilityElement? in
            guard let asset = assets[safe: i] else { return nil }
            let element = NSAccessibilityElement()
            element.setAccessibilityRole(.image)
            element.setAccessibilityLabel(asset.spokenDescription)
            element.setAccessibilitySelected(selected.contains(i))
            element.setAccessibilityParent(self)
            element.setAccessibilityFrameInParentSpace(frame(of: i))
            return element
        }
    }

    override func accessibilitySelectedChildren() -> [Any]? {
        accessibilityChildren()?.filter { ($0 as? NSAccessibilityElement)?.isAccessibilitySelected() == true }
    }
}
