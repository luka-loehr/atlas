import UIKit

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
