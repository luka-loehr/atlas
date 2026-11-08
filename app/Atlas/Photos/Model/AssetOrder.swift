import Foundation

extension Array where Element == Asset {
    /// The timeline's order, which every grid uses on iPhone and Mac: oldest
    /// first, undated before everything, ties as given.
    func timelineOrdered() -> [Asset] {
        enumerated().sorted { a, b in
            switch (a.element.takenAt, b.element.takenAt) {
            case let (x?, y?) where x != y: x < y
            case (nil, _?): true
            case (_?, nil): false
            default: a.offset < b.offset
            }
        }.map(\.element)
    }
}
