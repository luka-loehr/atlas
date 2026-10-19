import Foundation
import Network

/// Tells the app when the network comes back, or gets better (cellular to
/// Wi-Fi), so whatever stopped for want of it carries on at once instead of
/// at the next launch: the library refreshes, the backup and the thumbnail
/// fill pick up where they were.
@MainActor
final class NetworkWatch {
    static let shared = NetworkWatch()

    private let monitor = NWPathMonitor()
    private var last: (satisfied: Bool, expensive: Bool)?
    private var onBetter: (@MainActor () -> Void)?
    private var debounce: Task<Void, Never>?

    /// Starts watching (once); `onBetter` runs after the network came back
    /// or turned inexpensive, at most once per burst of changes.
    func start(onBetter: @escaping @MainActor () -> Void) {
        self.onBetter = onBetter
        guard last == nil else { return }
        last = (false, true)
        monitor.pathUpdateHandler = { path in
            let now = (satisfied: path.status == .satisfied, expensive: path.isExpensive || path.isConstrained)
            Task { @MainActor in NetworkWatch.shared.changed(now) }
        }
        monitor.start(queue: DispatchQueue(label: "atlas.network", qos: .utility))
    }

    private func changed(_ now: (satisfied: Bool, expensive: Bool)) {
        let before = last ?? (false, true)
        last = now
        let better = now.satisfied && (!before.satisfied || (before.expensive && !now.expensive))
        guard better else { return }
        debounce?.cancel()
        debounce = Task {
            // a network that just came up often needs a moment for its routes
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            onBetter?()
        }
    }
}
