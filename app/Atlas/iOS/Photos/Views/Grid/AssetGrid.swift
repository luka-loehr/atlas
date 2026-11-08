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
    @State private var order = AssetOrder()

    var body: some View {
        let (ordered, revision) = order.resolve(assets)
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

/// The grid's order of a list and its revision, made again only when the
/// list changes. The body runs on every tap while selecting; sorting and
/// hashing thousands of photos each time cost a frame. A plain object, so
/// reading it in `body` never invalidates the view.
@MainActor
private final class AssetOrder {
    private var input: [Asset]?
    private var ordered: [Asset] = []
    private var revision = 0

    /// An unchanged list is the same array most of the time, which `==`
    /// answers without looking at the elements.
    func resolve(_ assets: [Asset]) -> ([Asset], Int) {
        if let input, input == assets { return (ordered, revision) }
        input = assets
        ordered = Self.ordered(assets)
        revision = Self.revision(assets)
        return (ordered, revision)
    }

    /// Changes when the list does (ids in order).
    private static func revision(_ assets: [Asset]) -> Int {
        var h = Hasher()
        h.combine(assets.count)
        for a in assets { h.combine(a.id); h.combine(a.favorite) }
        return h.finalize()
    }

    /// Oldest first; undated before everything, as in the timeline.
    private static func ordered(_ assets: [Asset]) -> [Asset] {
        assets.enumerated().sorted { a, b in
            switch (a.element.takenAt, b.element.takenAt) {
            case let (x?, y?) where x != y: x < y
            case (nil, _?): true
            case (_?, nil): false
            default: a.offset < b.offset
            }
        }.map(\.element)
    }
}
