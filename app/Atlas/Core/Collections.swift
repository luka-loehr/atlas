import Foundation

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }

    /// Consecutive slices of at most `size` elements.
    func chunked(_ size: Int) -> [ArraySlice<Element>] {
        stride(from: 0, to: count, by: size).map { self[$0 ..< Swift.min($0 + size, count)] }
    }
}
