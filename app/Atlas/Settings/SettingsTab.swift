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

extension View {
    /// A change the server did not take: said, instead of looking as if it
    /// had worked.
    func changeFailedAlert(_ isPresented: Binding<Bool>) -> some View {
        alert("Couldn’t Save Change", isPresented: isPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Check that atlas is running and this iPhone is on the tailnet.")
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
