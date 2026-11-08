import SwiftUI

/// Minimal flow layout (wraps children like text). Children are proposed the
/// container width (not .unspecified), so an over-long chip caps at the row
/// width and truncates instead of drawing past the sheet edge.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let child = ProposedViewSize(width: width.isFinite ? width : nil, height: nil)
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(child)
            if x + sz.width > width, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
        return CGSize(width: width, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let child = ProposedViewSize(width: bounds.width, height: nil)
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(child)
            if x + sz.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += rowH + spacing; rowH = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: child)
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
    }
}
