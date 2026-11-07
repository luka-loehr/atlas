import SwiftUI
import SwiftTerm

#if os(iOS)
typealias PlatformViewRepresentable = UIViewRepresentable
#else
typealias PlatformViewRepresentable = NSViewRepresentable
#endif

/// SwiftTerm's terminal view (UIKit on iOS, AppKit on the Mac), wired to
/// the server's PTY WebSocket.
struct TerminalBridge: PlatformViewRepresentable {
    let api: API

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func make(_ coordinator: Coordinator) -> TerminalView {
        let terminal = TerminalView(frame: .zero)
        terminal.terminalDelegate = coordinator
        terminal.nativeBackgroundColor = .black
        #if os(iOS)
        terminal.nativeForegroundColor = UIColor(white: 0.92, alpha: 1)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak terminal] in _ = terminal?.becomeFirstResponder() }
        #else
        terminal.nativeForegroundColor = NSColor(white: 0.92, alpha: 1)
        terminal.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak terminal] in
            terminal?.window?.makeFirstResponder(terminal)
        }
        #endif
        coordinator.attach(terminal, api: api)
        return terminal
    }

    #if os(iOS)
    func makeUIView(context: Context) -> TerminalView { make(context.coordinator) }
    func updateUIView(_ terminal: TerminalView, context: Context) {}
    static func dismantleUIView(_ terminal: TerminalView, coordinator: Coordinator) { coordinator.close() }
    #else
    func makeNSView(context: Context) -> TerminalView { make(context.coordinator) }
    func updateNSView(_ terminal: TerminalView, context: Context) {}
    static func dismantleNSView(_ terminal: TerminalView, coordinator: Coordinator) { coordinator.close() }
    #endif

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
                        self.terminal?.feed(text: "\r\n\u{1b}[31m" + "— Disconnected —" + "\u{1b}[0m\r\n")
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
