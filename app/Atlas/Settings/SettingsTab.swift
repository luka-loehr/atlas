import SwiftUI

/// A spinner while a server screen loads; once the request has failed, the
/// same message the other server screens show.
struct LoadingOrUnavailable: View {
    let loaded: Bool
    var body: some View {
        if loaded {
            ServerUnavailableView()
        } else {
            ProgressView()
        }
    }
}

/// The server could not be reached.
struct ServerUnavailableView: View {
    var body: some View {
        ContentUnavailableView("atlas Unreachable", systemImage: "moon.zzz.fill",
                               description: Text("Check that atlas is running and this iPhone is on the tailnet."))
    }
}
