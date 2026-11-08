import SwiftUI
import QuartzCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A live load curve (0–100) over a sliding 60 s window. Drawn by two
/// CAShapeLayers (area and line) that a display link moves every frame:
/// SwiftUI is not involved per frame. A SwiftUI TimelineView did the same
/// with a Canvas, and made the whole window's hosting view lay out and
/// redraw 30 times a second (before that, a Swift Charts chart rebuilt mark
/// by mark). The series changes with each sample (twice a second); between
/// samples the head glides toward the newest value.
struct LiveSparkline: View {
    /// (time, value 0–100), oldest first.
    let series: [LiveSparkline.Point]
    let color: Color

    struct Point: Equatable {
        var date: Date
        var value: Double
    }

    var body: some View {
        SparklineHost(series: series, color: color)
            .accessibilityHidden(true)
    }
}

extension Machine {
    /// The last 160 samples of one measure, for a sparkline: mapped once
    /// per sample.
    func series(_ keyPath: KeyPath<MetricSample, Double>) -> [LiveSparkline.Point] {
        samples.suffix(160).map { LiveSparkline.Point(date: $0.date, value: $0[keyPath: keyPath]) }
    }
}

// MARK: - The layer view

/// Two shape layers and a display link at up to 30 frames a second, paused
/// while the view is not in a visible window.
final class SparklineView: PlatformView {
    var series: [(Date, Double)] = []
    var color: CGColor = CGColor(gray: 0.5, alpha: 1) {
        didSet {
            line.strokeColor = color
            area.fillColor = color.copy(alpha: 0.16)
        }
    }

    private let area = CAShapeLayer()
    private let line = CAShapeLayer()
    private var link: CADisplayLink?

    override init(frame: CGRect) {
        super.init(frame: frame)
        #if os(macOS)
        wantsLayer = true
        let root = layer!
        #else
        isUserInteractionEnabled = false
        backgroundColor = .clear
        let root = layer
        #endif
        line.fillColor = nil
        line.lineWidth = 1.5
        line.lineCap = .round
        line.lineJoin = .round
        for l in [area, line] {
            l.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull()]
            root.addSublayer(l)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    #if os(macOS)
    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        restart()
    }

    override func layout() {
        super.layout()
        place()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        area.contentsScale = scale
        line.contentsScale = scale
    }

    private func restart() {
        link?.invalidate()
        link = nil
        guard window != nil else { return }
        let l = displayLink(target: self, selector: #selector(tick))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
        l.add(to: .main, forMode: .common)
        link = l
        // nothing to draw while the window is hidden or covered
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(occlusion),
                                               name: NSWindow.didChangeOcclusionStateNotification, object: window)
        occlusion()
    }

    @objc private func occlusion() {
        link?.isPaused = !(window?.occlusionState.contains(.visible) ?? false)
    }
    #else
    override func didMoveToWindow() {
        super.didMoveToWindow()
        link?.invalidate()
        link = nil
        guard window != nil else { return }
        let l = CADisplayLink(target: self, selector: #selector(tick))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
        l.add(to: .main, forMode: .common)
        link = l
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        place()
    }
    #endif

    deinit {
        link?.invalidate()
    }

    private func place() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        area.frame = bounds
        line.frame = bounds
        CATransaction.commit()
        draw(at: Date())
    }

    @objc private func tick() { draw(at: Date()) }

    /// The curve as it stands at `now`: the window slides, the head glides.
    func draw(at now: Date) {
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let head = now.addingTimeInterval(-LiveChart.renderDelay)
        let start = head.addingTimeInterval(-LiveChart.window)
        let points = LiveChart.points(series, frame: now, window: LiveChart.window)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard points.count > 1 else {
            line.path = nil
            area.path = nil
            return
        }
        let xy = points.map { p in
            CGPoint(x: CGFloat(p.0.timeIntervalSince(start) / LiveChart.window) * size.width,
                    y: size.height - CGFloat(min(max(p.1, 0), 100) / 100) * (size.height - 1.5) - 0.75)
        }
        let curve = LiveChart.smooth(xy)
        line.path = curve
        let fill = curve.mutableCopy()!
        fill.addLine(to: CGPoint(x: xy[xy.count - 1].x, y: size.height))
        fill.addLine(to: CGPoint(x: xy[0].x, y: size.height))
        fill.closeSubpath()
        area.path = fill
    }
}

#if os(macOS)
typealias PlatformView = NSView

private struct SparklineHost: NSViewRepresentable {
    let series: [LiveSparkline.Point]
    let color: Color

    func makeNSView(context: Context) -> SparklineView { SparklineView(frame: .zero) }

    func updateNSView(_ view: SparklineView, context: Context) {
        view.series = series.map { ($0.date, $0.value) }
        view.color = NSColor(color).cgColor
    }
}
#else
typealias PlatformView = UIView

private struct SparklineHost: UIViewRepresentable {
    let series: [LiveSparkline.Point]
    let color: Color

    func makeUIView(context: Context) -> SparklineView { SparklineView(frame: .zero) }

    func updateUIView(_ view: SparklineView, context: Context) {
        view.series = series.map { ($0.date, $0.value) }
        view.color = UIColor(color).cgColor
    }
}
#endif

extension LiveChart {
    /// A curve through every point (Catmull–Rom as cubic Béziers), close to
    /// a monotone interpolation: the y of the control points is clamped
    /// between its neighbours, so it never overshoots.
    static func smooth(_ p: [CGPoint]) -> CGMutablePath {
        let path = CGMutablePath()
        path.move(to: p[0])
        for i in 0..<(p.count - 1) {
            let p0 = p[max(i - 1, 0)], p1 = p[i], p2 = p[i + 1], p3 = p[min(i + 2, p.count - 1)]
            let lo = min(p1.y, p2.y), hi = max(p1.y, p2.y)
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: min(max(p1.y + (p2.y - p0.y) / 6, lo), hi))
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: min(max(p2.y - (p3.y - p1.y) / 6, lo), hi))
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        return path
    }
}
