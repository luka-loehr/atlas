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
    /// The viewer opened from the grid was closed (it may have archived,
    /// deleted or moved what the grid shows).
    var onViewerClosed: () -> Void = {}

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
