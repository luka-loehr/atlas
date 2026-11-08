import AppKit

extension PhotoGridView: NSDraggingSource {
    // MARK: Mouse

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// How long a press must last to select instead of open.
    private static let holdToSelect: TimeInterval = 0.3

    /// A click opens the photo; holding it for 300 ms selects it (or takes
    /// it out of the selection); moving the pointer drags it (with the rest
    /// of the selection, if it is selected) out to the Finder or onto an
    /// album. ⌘-click adds or removes, ⇧-click extends, as everywhere on the
    /// Mac. From below the photos, a drag draws a selection rectangle.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let start = convert(event.locationInWindow, from: nil)
        let hit = index(at: start)
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        guard let hit else {
            // the background: a selection rectangle, or nothing
            let base = mods.contains(.command) || mods.contains(.shift) ? selected : []
            if base.isEmpty { setSelected([]) }
            while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
                if next.type == .leftMouseUp { break }
                let point = convert(next.locationInWindow, from: nil)
                guard hypot(point.x - start.x, point.y - start.y) > 4 else { continue }
                rubberBand(from: start, to: point, base: base)
                autoscroll(with: next)
            }
            band?.removeFromSuperlayer()
            band = nil
            return
        }

        cursor = hit
        if mods.contains(.command) {
            var s = selected
            if s.contains(hit) { s.remove(hit) } else { s.insert(hit) }
            setSelected(s)
            anchor = hit
            trackDrag(from: hit, start: start, event: event)
            return
        }
        if mods.contains(.shift) {
            let from = anchor ?? hit
            setSelected(selected.union(min(from, hit)...max(from, hit)))
            anchor = from
            trackDrag(from: hit, start: start, event: event)
            return
        }

        // plain press: open, select or drag, decided by what comes first
        let deadline = Date(timeIntervalSinceNow: Self.holdToSelect)
        visible[hit]?.pressed = true
        defer { visible[hit]?.pressed = false }
        while true {
            guard let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: deadline,
                                                 inMode: .eventTracking, dequeue: true) else {
                // held: select (or deselect), then a drag may still follow
                var s = selected
                if s.contains(hit) { s.remove(hit) } else { s.insert(hit) }
                setSelected(s)
                anchor = hit
                visible[hit]?.pressed = false
                trackDrag(from: hit, start: start, event: event)
                return
            }
            if next.type == .leftMouseUp {
                open(hit)
                return
            }
            let point = convert(next.locationInWindow, from: nil)
            if hypot(point.x - start.x, point.y - start.y) > 4 {
                beginDrag(with: event, from: hit)
                return
            }
        }
    }

    /// After a press that selected: a drag drags, a release ends it.
    private func trackDrag(from hit: Int, start: CGPoint, event: NSEvent) {
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { return }
            let point = convert(next.locationInWindow, from: nil)
            if hypot(point.x - start.x, point.y - start.y) > 4 {
                beginDrag(with: event, from: hit)
                return
            }
        }
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

    /// Drags the selection when the photo under the pointer is part of it,
    /// else just that photo.
    private func beginDrag(with event: NSEvent, from hit: Int) {
        let order = selected.contains(hit) ? selected.sorted() : [hit]
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
