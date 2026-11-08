import SwiftUI
import QuartzCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Text whose changed characters roll in, for values that change twice a
/// second (load, network, power). Each character is a CATextLayer; a
/// changed one slides out while its successor slides in, as Core Animation
/// animations in the render server, so the app does nothing between
/// changes. SwiftUI's `.numericText` transition redrew every glyph through
/// a blur on the CPU each frame (half a core on the server page), and even
/// a SwiftUI offset transition laid the whole window out at 120 Hz.
struct RollingText: View {
    let text: String
    var rising = true
    var size: CGFloat = 13
    var weight: Weight = .regular
    var secondary = false

    enum Weight { case regular, medium, semibold }

    init(_ text: String, rising: Bool = true, size: CGFloat = 13, weight: Weight = .regular, secondary: Bool = false) {
        self.text = text
        self.rising = rising
        self.size = size
        self.weight = weight
        self.secondary = secondary
    }

    var body: some View {
        RollingTextHost(text: text, rising: rising, font: Self.font(size, weight), secondary: secondary)
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(text))
    }

    static func font(_ size: CGFloat, _ weight: Weight) -> PlatformFont {
        let w: PlatformFont.Weight = switch weight {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        }
        return PlatformFont.monospacedDigitSystemFont(ofSize: size, weight: w)
    }
}

#if os(macOS)
typealias PlatformFont = NSFont
#else
typealias PlatformFont = UIFont
#endif

/// One CATextLayer per character, laid out by the string's own advances.
final class RollingTextView: PlatformView {
    private(set) var text = ""
    var font: PlatformFont = RollingText.font(13, .regular) {
        didSet { if font != oldValue { rebuild() } }
    }
    var secondary = false {
        didSet { if secondary != oldValue { recolor() } }
    }
    private var slots: [CATextLayer] = []
    private var scale: CGFloat = 2

    override init(frame: CGRect) {
        super.init(frame: frame)
        #if os(macOS)
        wantsLayer = true
        layer?.masksToBounds = false
        #else
        isUserInteractionEnabled = false
        backgroundColor = .clear
        layer.masksToBounds = false
        #endif
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var root: CALayer {
        #if os(macOS)
        layer!
        #else
        layer
        #endif
    }

    /// The size the text needs.
    var textSize: CGSize {
        let w = width(of: text)
        return CGSize(width: ceil(w), height: ceil(font.ascender - font.descender))
    }

    func set(_ new: String, rising: Bool) {
        guard new != text else { return }
        let old = Array(text), next = Array(new)
        text = new
        let shift: CGFloat = (font.pointSize * 0.55).rounded()
        let animate = window != nil && !old.isEmpty
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var kept: [CATextLayer] = []
        for (i, c) in next.enumerated() {
            let x = width(of: String(next[..<i]))
            if i < old.count, old[i] == c, i < slots.count {
                let l = slots[i]
                l.frame.origin.x = x
                kept.append(l)
                continue
            }
            let l = makeLayer(c, x: x)
            root.addSublayer(l)
            kept.append(l)
            if animate { roll(l, from: rising ? shift : -shift, to: 0, fadeIn: true) }
            if i < slots.count { retire(slots[i], to: rising ? -shift : shift, animate: animate) }
        }
        for l in slots.dropFirst(next.count) { retire(l, to: rising ? -shift : shift, animate: animate) }
        slots = kept
        CATransaction.commit()
        invalidateSize()
    }

    private func makeLayer(_ c: Character, x: CGFloat) -> CATextLayer {
        let l = CATextLayer()
        l.string = String(c)
        l.font = font
        l.fontSize = font.pointSize
        l.contentsScale = scale
        l.foregroundColor = color
        l.alignmentMode = .left
        let h = ceil(font.ascender - font.descender)
        l.frame = CGRect(x: x, y: 0, width: ceil(width(of: String(c))) + 1, height: h)
        l.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull(), "opacity": NSNull()]
        return l
    }

    private func roll(_ l: CALayer, from: CGFloat, to: CGFloat, fadeIn: Bool) {
        let move = CABasicAnimation(keyPath: "transform.translation.y")
        move.fromValue = flipped(from)
        move.toValue = flipped(to)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = fadeIn ? 0 : 1
        fade.toValue = fadeIn ? 1 : 0
        let group = CAAnimationGroup()
        group.animations = [move, fade]
        group.duration = 0.35
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
        l.add(group, forKey: "roll")
    }

    private func retire(_ l: CALayer, to: CGFloat, animate: Bool) {
        guard animate else { l.removeFromSuperlayer(); return }
        l.opacity = 0
        l.transform = CATransform3DMakeTranslation(0, flipped(to), 0)
        CATransaction.setCompletionBlock { [weak l] in l?.removeFromSuperlayer() }
        roll(l, from: 0, to: to, fadeIn: false)
    }

    /// Up is negative y on the iPhone's layers and positive on the Mac's.
    private func flipped(_ y: CGFloat) -> CGFloat {
        #if os(macOS)
        -y
        #else
        y
        #endif
    }

    private func width(of s: String) -> CGFloat {
        guard !s.isEmpty else { return 0 }
        return (s as NSString).size(withAttributes: [.font: font]).width
    }

    private func rebuild() {
        let t = text
        text = ""
        for l in slots { l.removeFromSuperlayer() }
        slots = []
        set(t, rising: true)
    }

    private var color: CGColor {
        #if os(macOS)
        var c: CGColor = NSColor.labelColor.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            c = (secondary ? NSColor.secondaryLabelColor : NSColor.labelColor).cgColor
        }
        return c
        #else
        (secondary ? UIColor.secondaryLabel : UIColor.label).resolvedColor(with: traitCollection).cgColor
        #endif
    }

    private func recolor() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in slots { l.foregroundColor = color }
        CATransaction.commit()
    }

    private func invalidateSize() {
        #if os(macOS)
        invalidateIntrinsicContentSize()
        #else
        invalidateIntrinsicContentSize()
        #endif
    }

    override var intrinsicContentSize: CGSize { textSize }

    #if os(macOS)
    override var isFlipped: Bool { true }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        recolor()
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        scale = window?.backingScaleFactor ?? 2
        for l in slots { l.contentsScale = scale }
    }
    #else
    override func didMoveToWindow() {
        super.didMoveToWindow()
        scale = window?.screen.scale ?? 3
        for l in slots { l.contentsScale = scale }
    }
    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        recolor()
    }
    #endif
}

#if os(macOS)
private struct RollingTextHost: NSViewRepresentable {
    let text: String
    let rising: Bool
    let font: PlatformFont
    let secondary: Bool

    func makeNSView(context: Context) -> RollingTextView { RollingTextView(frame: .zero) }

    func updateNSView(_ view: RollingTextView, context: Context) {
        view.font = font
        view.secondary = secondary
        view.set(text, rising: rising)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: RollingTextView, context: Context) -> CGSize? {
        nsView.textSize
    }
}
#else
private struct RollingTextHost: UIViewRepresentable {
    let text: String
    let rising: Bool
    let font: PlatformFont
    let secondary: Bool

    func makeUIView(context: Context) -> RollingTextView { RollingTextView(frame: .zero) }

    func updateUIView(_ view: RollingTextView, context: Context) {
        view.font = font
        view.secondary = secondary
        view.set(text, rising: rising)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: RollingTextView, context: Context) -> CGSize? {
        uiView.textSize
    }
}
#endif
