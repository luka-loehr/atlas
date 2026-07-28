import Foundation

/// Subscribes to paperclip-bridge's SSE stream so the app reflects the company
/// in real time instead of polling. Falls back silently — the app still polls
/// on a slow timer, so a dead bridge degrades rather than breaks.
@MainActor
@Observable
final class LiveStream {
    private(set) var connected = false
    private(set) var lastEventAt: Date?

    var host: String = ""
    var token: String = ""
    var onChange: (() -> Void)?

    private var task: Task<Void, Never>?

    func connect(host: String, token: String, onChange: @escaping () -> Void) {
        guard !host.isEmpty, !token.isEmpty else { return }
        self.host = host
        self.token = token
        self.onChange = onChange
        task?.cancel()
        task = Task { [weak self] in await self?.loop() }
    }

    func disconnect() {
        task?.cancel()
        task = nil
        connected = false
    }

    private func loop() async {
        var backoff: UInt64 = 2
        while !Task.isCancelled {
            do {
                try await stream()
                backoff = 2
            } catch {
                connected = false
            }
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: .seconds(Double(backoff)))
            backoff = min(backoff * 2, 30)
        }
    }

    private func stream() async throws {
        guard let url = URL(string: "http://\(host)/stream") else { return }
        var request = URLRequest(url: url, timeoutInterval: 3600)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        connected = true

        var event = ""
        var data = ""
        for try await line in bytes.lines {
            if Task.isCancelled { break }
            if line.isEmpty {
                handle(event: event, data: data)
                event = ""
                data = ""
            } else if line.hasPrefix("event: ") {
                event = String(line.dropFirst(7))
            } else if line.hasPrefix("data: ") {
                data += String(line.dropFirst(6))
            }
            // ": keepalive" comments fall through and are ignored
        }
        connected = false
    }

    private func handle(event: String, data: String) {
        guard !data.isEmpty else { return }
        lastEventAt = Date()
        switch event {
        case "snapshot", "delta":
            // The REST refresh owns the model; the stream just says "something moved".
            onChange?()
        default:
            // `run` (per-agent output) and `error` are published by the bridge
            // but no screen renders them, so they only count as liveness.
            break
        }
    }
}
