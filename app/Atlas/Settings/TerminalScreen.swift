import SwiftUI
import SwiftTerm
import LocalAuthentication

/// A shell on the server. Opening it takes Face ID every time: whoever holds
/// the unlocked phone can look at photos, but not type into the machine.
struct TerminalScreen: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var unlocked = false
    @State private var failed = false

    var body: some View {
        NavigationStack {
            Group {
                if unlocked, let api = session.api {
                    TerminalBridge(api: api).ignoresSafeArea(.container, edges: .bottom)
                } else {
                    ContentUnavailableView {
                        Label("Terminal gesperrt", systemImage: "lock.shield.fill")
                    } description: {
                        Text("Zugriff auf die atlas-Shell erfordert Face ID.")
                    } actions: {
                        if failed { Button("Entsperren") { Task { await unlock() } } }
                    }
                }
            }
            .background(.black)
            .navigationTitle("Terminal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(role: .close) { dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
        .task { await unlock() }
    }

    private func unlock() async {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else { unlocked = true; return }
        let ok = (try? await context.evaluatePolicy(.deviceOwnerAuthentication,
                                                    localizedReason: "Shell auf atlas öffnen")) ?? false
        unlocked = ok
        failed = !ok
    }
}

/// SwiftTerm's terminal view, wired to the server's PTY WebSocket.
private struct TerminalBridge: UIViewRepresentable {
    let api: API

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> TerminalView {
        let terminal = TerminalView(frame: .zero)
        terminal.terminalDelegate = context.coordinator
        terminal.nativeBackgroundColor = .black
        terminal.nativeForegroundColor = UIColor(white: 0.92, alpha: 1)
        context.coordinator.attach(terminal, api: api)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak terminal] in _ = terminal?.becomeFirstResponder() }
        return terminal
    }

    func updateUIView(_ terminal: TerminalView, context: Context) {}

    static func dismantleUIView(_ terminal: TerminalView, coordinator: Coordinator) {
        coordinator.close()
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        private weak var terminal: TerminalView?
        private var socket: URLSessionWebSocketTask?

        func attach(_ terminal: TerminalView, api: API) {
            self.terminal = terminal
            var components = URLComponents(url: api.url("system/terminal"), resolvingAgainstBaseURL: false)!
            components.scheme = components.scheme == "https" ? "wss" : "ws"
            var request = URLRequest(url: components.url!)
            request.setValue("Bearer \(api.config.token)", forHTTPHeaderField: "Authorization")
            let socket = URLSession.shared.webSocketTask(with: request)
            self.socket = socket
            socket.resume()
            receive()
        }

        func close() {
            socket?.cancel(with: .goingAway, reason: nil)
            socket = nil
        }

        private func receive() {
            socket?.receive { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(.data(let data)):
                    let bytes = [UInt8](data)
                    DispatchQueue.main.async { self.terminal?.feed(byteArray: bytes[...]) }
                    self.receive()
                case .success(.string(let text)):
                    let bytes = Array(text.utf8)
                    DispatchQueue.main.async { self.terminal?.feed(byteArray: bytes[...]) }
                    self.receive()
                case .success:
                    self.receive()
                case .failure:
                    DispatchQueue.main.async {
                        self.terminal?.feed(text: "\r\n\u{1b}[31m" + "— Verbindung getrennt —" + "\u{1b}[0m\r\n")
                    }
                }
            }
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            socket?.send(.data(Data(data))) { _ in }
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            socket?.send(.string("{\"resize\":{\"cols\":\(newCols),\"rows\":\(newRows)}}")) { _ in }
        }

        func setTerminalTitle(source: TerminalView, title: String) {}
        func scrolled(source: TerminalView, position: Double) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func bell(source: TerminalView) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
