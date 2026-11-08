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
    /// The first and last photo on screen.
    var onVisible: (Int, Int) -> Void = { _, _ in }
    var onFavoriteKey: () -> Void = {}
    var onZoom: (Int) -> Void = { _ in }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        // the photos start at the window's top, under the floating toolbar
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
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
