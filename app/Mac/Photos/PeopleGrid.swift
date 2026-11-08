import SwiftUI
import AppKit

/// The People page's faces as an NSCollectionView: recycled items, a round
/// layer for the face and two labels. SwiftUI's LazyVGrid placed and
/// hit-tested every face anew while scrolling (40 % of a core); this grid
/// scrolls like the photo grid. A click opens the person; the context menu
/// renames or hides them.
struct PeopleGrid: NSViewRepresentable {
    let library: Library
    let humans: [Person]
    let pets: [Person]
    let size: CGFloat
    var onOpen: (Person) -> Void
    var onRename: (Person) -> Void
    var onHide: (Person) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let layout = NSCollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 24
        layout.minimumLineSpacing = 24
        layout.sectionInset = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        let grid = PeopleCollectionView()
        grid.collectionViewLayout = layout
        grid.backgroundColors = [.clear]
        grid.isSelectable = true
        grid.register(PersonItem.self, forItemWithIdentifier: PersonItem.id)
        grid.register(PetsHeader.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
                      withIdentifier: PetsHeader.id)
        grid.dataSource = context.coordinator
        grid.delegate = context.coordinator
        let scroll = NSScrollView()
        scroll.documentView = grid
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = true
        context.coordinator.grid = grid
        update(context.coordinator, grid)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let grid = scroll.documentView as? PeopleCollectionView else { return }
        update(context.coordinator, grid)
    }

    private func update(_ c: Coordinator, _ grid: PeopleCollectionView) {
        c.host = self
        grid.menuFor = { [weak c] i in c?.menu(for: i) }
        let sections = [humans, pets].filter { !$0.isEmpty }
        let changed = sections.map { $0.map(\.id) } != c.sections.map { $0.map(\.id) }
            || sections.flatMap { $0 }.map(\.name) != c.sections.flatMap { $0 }.map(\.name)
        c.hasPets = !pets.isEmpty
        if changed {
            c.sections = sections
            grid.reloadData()
        }
        if let layout = grid.collectionViewLayout as? NSCollectionViewFlowLayout,
           layout.itemSize.width != size {
            layout.itemSize = NSSize(width: size, height: size + 40)
            layout.invalidateLayout()
        }
    }

    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout {
        var host: PeopleGrid!
        var sections: [[Person]] = []
        var hasPets = false
        weak var grid: NSCollectionView?

        func numberOfSections(in collectionView: NSCollectionView) -> Int { sections.count }

        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
            sections[section].count
        }

        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let item = collectionView.makeItem(withIdentifier: PersonItem.id, for: indexPath) as! PersonItem
            item.show(sections[indexPath.section][indexPath.item], library: host.library, side: host.size)
            return item
        }

        func collectionView(_ collectionView: NSCollectionView, viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
                            at indexPath: IndexPath) -> NSView {
            collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: PetsHeader.id, for: indexPath)
        }

        func collectionView(_ collectionView: NSCollectionView, layout: NSCollectionViewLayout,
                            referenceSizeForHeaderInSection section: Int) -> NSSize {
            // the pets come second, under their own heading
            hasPets && section == sections.count - 1 && sections.count > 1 ? NSSize(width: 0, height: 36) : .zero
        }

        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
            collectionView.deselectItems(at: indexPaths)
            guard let p = indexPaths.first else { return }
            host.onOpen(sections[p.section][p.item])
        }

        func menu(for indexPath: IndexPath) -> NSMenu? {
            let person = sections[indexPath.section][indexPath.item]
            let menu = NSMenu()
            menu.addItem(ClosureMenuItem("Rename…") { [weak self] in self?.host.onRename(person) })
            menu.addItem(ClosureMenuItem("Hide") { [weak self] in self?.host.onHide(person) })
            return menu
        }
    }
}

/// The grid with a context menu for the face under the pointer.
final class PeopleCollectionView: NSCollectionView {
    var menuFor: ((IndexPath) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let path = indexPathForItem(at: point) else { return nil }
        return menuFor?(path)
    }
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void

    init(_ title: String, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { run() }
}

/// One face: a round image layer, the name and the number of photos, all
/// layers of one view (text fields as subviews cost a redraw and new
/// tracking areas each time an item scrolled into view).
final class PersonItem: NSCollectionViewItem {
    static let id = NSUserInterfaceItemIdentifier("person")
    private var cell: PersonCellView { view as! PersonCellView }
    private var shown: Int64?
    private var loading: Task<Void, Never>?

    override func loadView() { view = PersonCellView() }

    func show(_ person: Person, library: Library, side: CGFloat) {
        cell.set(name: person.displayName, named: person.name != nil, count: person.photos.formatted())
        view.setAccessibilityLabel(person.displayName)
        view.setAccessibilityValue("\(person.photos) photos")
        guard shown != person.coverFace || cell.face.contents == nil else { return }
        shown = person.coverFace
        loading?.cancel()
        cell.face.contents = nil
        guard let id = person.coverFace, let url = library.client.faceCropURL(id) else { return }
        if let image = MediaCache.shared.cached(url) {
            cell.face.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            return
        }
        loading = Task { @MainActor [weak self] in
            let image = await MediaCache.shared.load(url)
            guard !Task.isCancelled, let self, self.shown == id else { return }
            self.cell.face.contents = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loading?.cancel()
    }
}

final class PersonCellView: NSView {
    let face = CALayer()
    private let name = CATextLayer()
    private let count = CATextLayer()
    private var named = true

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityRole(.button)
        face.masksToBounds = true
        face.contentsGravity = .resizeAspectFill
        let still: [String: CAAction] = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "string": NSNull(),
                                          "foregroundColor": NSNull(), "backgroundColor": NSNull()]
        face.actions = still
        for (l, size) in [(name, CGFloat(12)), (count, CGFloat(10))] {
            l.font = NSFont.systemFont(ofSize: size)
            l.fontSize = size
            l.alignmentMode = .center
            l.truncationMode = .end
            l.actions = still
        }
        count.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        for l in [face, name, count] { layer?.addSublayer(l) }
        recolor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    func set(name text: String, named: Bool, count: String) {
        self.named = named
        name.string = text
        self.count.string = count
        recolor()
    }

    override func layout() {
        super.layout()
        let side = bounds.width
        let scale = window?.backingScaleFactor ?? 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        face.frame = CGRect(x: 0, y: 0, width: side, height: side)
        face.cornerRadius = side / 2
        name.frame = CGRect(x: 0, y: side + 6, width: side, height: 16)
        count.frame = CGRect(x: 0, y: side + 22, width: side, height: 13)
        for l in [face, name, count] { l.contentsScale = scale }
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        recolor()
    }

    private func recolor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            face.backgroundColor = NSColor.quaternaryLabelColor.cgColor
            name.foregroundColor = (named ? NSColor.labelColor : NSColor.secondaryLabelColor).cgColor
            count.foregroundColor = NSColor.secondaryLabelColor.cgColor
        }
    }
}

/// The "Pets" heading above the pets.
final class PetsHeader: NSView, NSCollectionViewElement {
    static let id = NSUserInterfaceItemIdentifier("pets")
    private let label = NSTextField(labelWithString: "Pets")

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 20, weight: .bold)
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        label.frame = CGRect(x: 24, y: 4, width: bounds.width - 48, height: 26)
    }
}
