import SwiftUI
import UIKit

/// Schnellscroller am rechten Rand: Griff ziehen, Monat und Jahre erscheinen,
/// beim Loslassen steht das Raster dort. Alle Werte kommen vorberechnet aus
/// `Library.months`, im Drag-Pfad wird nur binär gesucht.
struct TimeScrubber: View {
    let months: [Library.Month]
    let total: Int
    /// Asset position at the top of the screen.
    let current: Int
    /// The grid is moving: show the slim indicator. At rest nothing shows;
    /// grabbing the indicator turns it into the full scrubber.
    var visible = false
    var onJump: (Library.Month) -> Void

    @State private var dragging = false
    @State private var dragFrac: CGFloat = 0
    @State private var lastMonth = ""

    private let space = "scrubTrack"

    private func frac(_ position: Int) -> CGFloat { CGFloat(position) / CGFloat(max(total - 1, 1)) }

    private var yearMarks: [(year: Int, frac: CGFloat)] {
        var seen = Set<Int>()
        return months.compactMap { m in
            seen.insert(m.year).inserted && m.year > 0 ? (m.year, frac(m.first)) : nil
        }
    }

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let f = dragging ? dragFrac : frac(current)
            let handleY = clamp(f * h, 22, h - 22)
            ZStack(alignment: .topTrailing) {
                if dragging {
                    ForEach(yearMarks, id: \.year) { m in
                        Text(String(m.year))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .glassEffect(.regular, in: .capsule)
                            .position(x: geo.size.width - 34, y: clamp(m.frac * h, 12, h - 12))
                            .allowsHitTesting(false)
                    }
                    Text(month(at: dragFrac).label)
                        .font(.system(size: 15, weight: .semibold))
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .glassEffect(.regular, in: .capsule)
                        .position(x: geo.size.width - 118, y: handleY)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
                handle
                    .position(x: geo.size.width - 20, y: handleY)
                    .gesture(drag(h: h))
                    .opacity(dragging || visible ? 1 : 0)
                    .allowsHitTesting(dragging || visible)
            }
            .coordinateSpace(.named(space))
            .frame(width: geo.size.width, height: h)
        }
        .frame(width: 150)
        .frame(maxHeight: .infinity)
    }

    /// A standard slim scroll indicator; while dragged, the big handle.
    @ViewBuilder private var handle: some View {
        ZStack {
            if dragging {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.primary)
                    .frame(width: 36, height: 46)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .transition(.scale(scale: 0.3, anchor: .trailing).combined(with: .opacity))
            } else {
                Capsule()
                    .fill(Color.secondary)
                    .frame(width: 5, height: 40)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 2)
                    .transition(.opacity)
            }
        }
        .frame(width: 36, height: 46)
        .animation(.snappy(duration: 0.2), value: dragging)
        .contentShape(Rectangle().inset(by: -12))
    }

    private func drag(h: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
            .onChanged { v in
                if !dragging {
                    withAnimation(.snappy(duration: 0.2)) { dragging = true }
                    UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                }
                dragFrac = clamp(v.location.y / h, 0, 1)
                let m = month(at: dragFrac)
                if m.key != lastMonth {
                    lastMonth = m.key
                    UISelectionFeedbackGenerator().selectionChanged()
                    onJump(m)
                }
            }
            .onEnded { _ in
                withAnimation(.easeOut(duration: 0.25)) { dragging = false }
            }
    }

    /// The month at a fraction of the track (binary search over start positions).
    private func month(at f: CGFloat) -> Library.Month {
        let position = Int(f * CGFloat(max(total - 1, 0)))
        var lo = 0, hi = months.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if months[mid].first <= position { lo = mid } else { hi = mid - 1 }
        }
        return months[lo]
    }

    private func clamp<T: Comparable>(_ v: T, _ lo: T, _ hi: T) -> T { min(max(v, lo), hi) }
}
