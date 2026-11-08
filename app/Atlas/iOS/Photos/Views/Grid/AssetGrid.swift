import SwiftUI
import UIKit

/// A list of photos in the library's own grid (search results, a person, an
/// album, Favorites ...): pinch through 1/3/5/9 columns, the local tiles,
/// the zoom transition, a tap opens exactly the photo under the finger, and
/// selection with check marks. Ordered like the library: oldest at the top
/// (undated first), opened at the newest end at the bottom.
struct AssetGrid: View {
    var library: Library
    var assets: [Asset]
    var selection: Selection?
    var onRefresh: () async -> Void = {}
    var onViewerClosed: () -> Void = {}
    /// The photos run up under the navigation bar, with the Library's shade
    /// behind the title (a screen of its own; not under the search chips).
    var underBar = false
    @State private var proxy = PhotoGridProxy()

    /// Changes when the list does (ids in order).
    private var revision: Int {
        var h = Hasher()
        h.combine(assets.count)
        for a in assets { h.combine(a.id); h.combine(a.favorite) }
        return h.finalize()
    }

    /// Oldest first; undated before everything, as in the timeline.
    private var ordered: [Asset] {
        assets.enumerated().sorted { a, b in
            switch (a.element.takenAt, b.element.takenAt) {
            case let (x?, y?) where x != y: x < y
            case (nil, _?): true
            case (_?, nil): false
            default: a.offset < b.offset
            }
        }.map(\.element)
    }

    var body: some View {
        PhotoGrid(library: library, assets: ordered, revision: revision,
                  selecting: selection?.active ?? false, selected: selection?.ids ?? [], proxy: proxy,
                  titleShade: underBar, contextMenus: false,
                  onTop: { _ in },
                  onToggle: { asset in withAnimation(.snappy(duration: 0.26)) { selection?.toggle(asset.id) } },
                  menu: { _ in UIMenu(children: []) },
                  onRefresh: onRefresh,
                  onViewerClosed: onViewerClosed)
            .ignoresSafeArea(edges: underBar ? .all : .bottom)
    }
}
