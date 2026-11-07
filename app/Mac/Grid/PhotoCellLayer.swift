import AppKit

/// One cell of the grid, layers only: the thumbnail filling the square, the
/// length of a video and a heart on favorites, and the selection as Photos
/// draws it, a ring in the system accent color with a checkmark. The
/// badges are SF Symbols rendered once and shared by every cell.
@MainActor
final class PhotoCellLayer: CALayer {
    private let imageLayer = CALayer()
    private let shade = CAGradientLayer()
    private let dim = CALayer()
    private let ring = CALayer()
    private let durationLayer = CATextLayer()
    private let heartLayer = CALayer()
    private let checkLayer = CALayer()

    private var ticket: MediaCache.Ticket?
    private(set) var assetID: String?
    private var pixels = 0
    private var video: String?
    private var favorite = false

    var selected = false { didSet { if selected != oldValue { update() } } }
    var image: CGImage? { imageLayer.contents.map { $0 as! CGImage } }

    override init() {
        super.init()
        masksToBounds = true
        let still: [String: CAAction] = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(),
                                         "hidden": NSNull(), "string": NSNull(), "frame": NSNull()]
        actions = still
        for l in [imageLayer, shade, dim, ring, durationLayer, heartLayer, checkLayer] as [CALayer] {
            l.actions = still
            addSublayer(l)
        }
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.masksToBounds = true

        // a soft shade behind the duration and the heart, so they read on
        // white snow and on black night alike
        shade.colors = [NSColor.clear.cgColor, NSColor.black.withAlphaComponent(0.45).cgColor]
        shade.startPoint = CGPoint(x: 0.5, y: 0)
        shade.endPoint = CGPoint(x: 0.5, y: 1)
        shade.isHidden = true
        dim.backgroundColor = NSColor.black.withAlphaComponent(0.18).cgColor
        dim.isHidden = true
        ring.borderWidth = 3
        ring.isHidden = true

        durationLayer.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        durationLayer.fontSize = 11
        durationLayer.foregroundColor = NSColor.white.cgColor
        durationLayer.alignmentMode = .right
        durationLayer.isHidden = true

        heartLayer.contentsGravity = .resizeAspect
        heartLayer.isHidden = true
        checkLayer.contentsGravity = .resizeAspect
        checkLayer.isHidden = true
        applyColors()
    }

    nonisolated override init(layer: Any) { super.init(layer: layer) }
    nonisolated required init?(coder: NSCoder) { fatalError() }

    override var contentsScale: CGFloat {
        didSet {
            guard contentsScale != oldValue else { return }
            for l in [imageLayer, durationLayer, heartLayer, checkLayer] { l.contentsScale = contentsScale }
            heartLayer.contents = Badges.heart(scale: contentsScale)
            applyColors()
        }
    }

    func applyColors() {
        backgroundColor = NSColor.quaternarySystemFill.cgColor
        ring.borderColor = NSColor.controlAccentColor.cgColor
        checkLayer.contents = Badges.check(scale: contentsScale, accent: .controlAccentColor)
    }

    /// Shows `asset`: from RAM at once when it is there, else decoded from
    /// the store (or fetched) and faded in.
    func show(_ asset: Asset, pixels: Int, force: Bool = false) {
        let same = assetID == asset.id && self.pixels == pixels && imageLayer.contents != nil
        assetID = asset.id
        self.pixels = pixels
        video = asset.isVideo ? Self.duration(asset.durationS) : nil
        favorite = asset.isFavorite
        durationLayer.string = video
        update()
        guard !same || force else { return }
        ticket?.cancel()
        ticket = nil
        if let ready = MediaCache.shared.gridImage(id: asset.id, pixels: pixels) {
            imageLayer.contents = ready.cgImage
            return
        }
        if !same { imageLayer.contents = nil }
        let id = asset.id
        ticket = MediaCache.shared.requestGrid(id: id, pixels: pixels, urgent: true) { [weak self] image in
            guard let self, self.assetID == id else { return }
            self.ticket = nil
            let fade = CATransition()
            fade.duration = 0.15
            fade.type = .fade
            self.imageLayer.add(fade, forKey: "fade")
            self.imageLayer.contents = image?.cgImage
        }
    }

    /// Back into the pool.
    func reset() {
        ticket?.cancel()
        ticket = nil
        assetID = nil
        imageLayer.contents = nil
        selected = false
    }

    override func layoutSublayers() {
        super.layoutSublayers()
        let b = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = b
        dim.frame = b
        ring.frame = b
        // the grid view is flipped, and so are its layers: y counts down
        shade.frame = CGRect(x: 0, y: b.height - 28, width: b.width, height: 28)
        durationLayer.frame = CGRect(x: 4, y: b.height - 18, width: b.width - 10, height: 14)
        heartLayer.frame = CGRect(x: 6, y: b.height - 17, width: 13, height: 12)
        checkLayer.frame = CGRect(x: b.width - 24, y: 5, width: 19, height: 19)
        CATransaction.commit()
        update()
    }

    private func update() {
        let small = bounds.width < 70
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        durationLayer.isHidden = video == nil || small
        heartLayer.isHidden = !favorite || small
        shade.isHidden = durationLayer.isHidden && heartLayer.isHidden
        ring.isHidden = !selected
        dim.isHidden = !selected
        checkLayer.isHidden = !selected || small
        CATransaction.commit()
    }

    private static func duration(_ seconds: Double?) -> String {
        let s = Int((seconds ?? 0).rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// The cell badges, rendered from SF Symbols once per scale (and accent
/// color) and shared by every cell.
@MainActor
private enum Badges {
    private static var hearts: [CGFloat: CGImage] = [:]
    private static var checks: [String: CGImage] = [:]

    static func heart(scale: CGFloat) -> CGImage? {
        if let image = hearts[scale] { return image }
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            .applying(.init(paletteColors: [.white]))
        let image = render("heart.fill", config, scale: scale)
        hearts[scale] = image
        return image
    }

    static func check(scale: CGFloat, accent: NSColor) -> CGImage? {
        let key = "\(scale)-\(accent.usingColorSpace(.sRGB)?.description ?? "accent")"
        if let image = checks[key] { return image }
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
            .applying(.init(paletteColors: [.white, accent]))
        let image = render("checkmark.circle.fill", config, scale: scale)
        checks[key] = image
        return image
    }

    private static func render(_ name: String, _ config: NSImage.SymbolConfiguration, scale: CGFloat) -> CGImage? {
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return nil }
        let size = symbol.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        symbol.draw(in: CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }
}
