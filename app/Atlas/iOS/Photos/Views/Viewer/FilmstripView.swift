import SwiftUI
import UIKit

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
