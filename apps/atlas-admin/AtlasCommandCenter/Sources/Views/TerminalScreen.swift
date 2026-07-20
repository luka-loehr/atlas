import SwiftUI
import SwiftTerm

/// Full-screen terminal overlay (presented like a sheet, closable top-left —
/// a tab would trap the user once the keyboard hides the tab bar).
struct TerminalSheet: View {
    var host: String
    var token: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                TerminalBridge(host: host, token: token)
                    .ignoresSafeArea(.container, edges: .bottom)
            }
            .navigationTitle("luka@atlas")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.black, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

/// Wraps a SwiftTerm TerminalView and bridges it to the agent's /term PTY
/// over a WebSocket.
struct TerminalBridge: UIViewRepresentable {
    var host: String
    var token: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> TerminalView {
        let tv = TerminalView(frame: .zero)
        tv.terminalDelegate = context.coordinator
        tv.nativeBackgroundColor = .black
        tv.nativeForegroundColor = UIColor(white: 0.92, alpha: 1)
        context.coordinator.attach(terminal: tv, host: host, token: token)
        // auto-focus: keyboard up as soon as the terminal appears
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak tv] in
            tv?.becomeFirstResponder()
        }
        return tv
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {
        if uiView.window != nil, !uiView.isFirstResponder {
            uiView.becomeFirstResponder()
        }
    }

    static func dismantleUIView(_ uiView: TerminalView, coordinator: Coordinator) {
        coordinator.close()
    }

    final class Coordinator: NSObject, TerminalViewDelegate, URLSessionWebSocketDelegate {
        private weak var terminal: TerminalView?
        private var task: URLSessionWebSocketTask?

        func attach(terminal: TerminalView, host: String, token: String) {
            self.terminal = terminal
            var s = "ws://\(host)/term"
            if !token.isEmpty { s += "?token=\(token)" }
            guard let url = URL(string: s) else { return }
            let session = URLSession(configuration: .default)
            let task = session.webSocketTask(with: url)
            self.task = task
            task.resume()
            receive()
        }

        func close() {
            task?.cancel(with: .goingAway, reason: nil)
            task = nil
        }

        private func receive() {
            task?.receive { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let message):
                    switch message {
                    case .data(let d):
                        let bytes = [UInt8](d)
                        DispatchQueue.main.async { self.terminal?.feed(byteArray: bytes[...]) }
                    case .string(let str):
                        let bytes = Array(str.utf8)
                        DispatchQueue.main.async { self.terminal?.feed(byteArray: bytes[...]) }
                    @unknown default: break
                    }
                    self.receive()
                case .failure:
                    DispatchQueue.main.async {
                        self.terminal?.feed(text: "\r\n\u{1b}[31m— Verbindung getrennt —\u{1b}[0m\r\n")
                    }
                }
            }
        }

        // MARK: TerminalViewDelegate

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            task?.send(.data(Data(data))) { _ in }
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            let msg = "{\"resize\":{\"cols\":\(newCols),\"rows\":\(newRows)}}"
            task?.send(.string(msg)) { _ in }
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
