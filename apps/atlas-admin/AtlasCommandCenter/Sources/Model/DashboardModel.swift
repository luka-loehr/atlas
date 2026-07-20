import Foundation
import Observation

@MainActor
@Observable
final class DashboardModel {
    var metrics: Metrics?
    var online = false
    var lastError: String?
    var updatedAt: Date?

    // rolling history for the sparkline (usage %, newest last)
    var cpuHistory: [Double] = []
    var gpuHistory: [Double] = []

    var host: String = "atlas.your-tailnet.ts.net:8787"
    var token: String = ""

    private var loopTask: Task<Void, Never>?
    private let maxHistory = 60

    func start() {
        stop()
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    func refresh() async {
        let client = AtlasClient(host: host, token: token.isEmpty ? nil : token)
        do {
            let m = try await client.fetch()
            metrics = m
            online = true
            lastError = nil
            updatedAt = Date()
            push(&cpuHistory, m.cpu.usage)
            push(&gpuHistory, m.gpu?.usage ?? 0)
        } catch {
            online = false
            lastError = friendly(error)
        }
    }

    func sendPower(_ action: String) async {
        let client = AtlasClient(host: host, token: token.isEmpty ? nil : token)
        try? await client.power(action)
    }

    private func push(_ arr: inout [Double], _ v: Double) {
        arr.append(v)
        if arr.count > maxHistory { arr.removeFirst(arr.count - maxHistory) }
    }

    private func friendly(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .cannotConnectToHost, .cannotFindHost, .networkConnectionLost:
                return "atlas nicht erreichbar – schläft er?"
            default: return urlError.localizedDescription
            }
        }
        return error.localizedDescription
    }
}
