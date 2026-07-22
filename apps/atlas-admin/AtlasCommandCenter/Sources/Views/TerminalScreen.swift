import SwiftUI
import SwiftTerm

/// Full-screen terminal overlay (presented like a sheet, closable top-left —
/// a tab would trap the user once the keyboard hides the tab bar).
struct TerminalSheet: View {
    var host: String
    var token: String
    @Environment(\.dismiss) private var dismiss

    // Face-ID gate: the shell (and its websocket) only exists AFTER a
    // successful unlock — whoever holds the phone can read metrics, but
    // cannot type a single character into atlas without authenticating.
    // Every presentation starts locked again (fresh @State per cover).
    @State private var unlocked = false
    @State private var authFailed = false
    @State private var authing = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if unlocked {
                    TerminalBridge(host: host, token: token)
                        .ignoresSafeArea(.container, edges: .bottom)
                } else {
                    lockView
                }
            }
            .navigationTitle("Terminal")
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
        .task { await unlock() }   // Face ID direkt beim Öffnen anstoßen
    }

    private var lockView: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 52))
                .foregroundStyle(.white.opacity(0.35))
            Text("Terminal gesperrt")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
            Text("Zugriff auf die atlas-Shell erfordert Face ID.")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
            if authFailed {
                Button {
                    Task { await unlock() }
                } label: {
                    Label("Mit Face ID entsperren", systemImage: "faceid")
                        .font(.system(size: 15, weight: .semibold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 11)
                }
                .buttonStyle(.glassProminent)
            } else if authing {
                ProgressView().tint(.white)
            }
        }
        .padding(32)
    }

    private func unlock() async {
        guard !unlocked, !authing else { return }
        authing = true
        authFailed = false
        let ok = await Biometric.authenticate(reason: "Terminal-Zugriff auf atlas freigeben")
        authing = false
        if ok {
            withAnimation(.snappy) { unlocked = true }
        } else {
            authFailed = true
        }
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
