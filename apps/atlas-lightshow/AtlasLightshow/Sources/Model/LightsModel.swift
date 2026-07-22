import SwiftUI
import Observation

/// One controllable RGB fixture (index = its 3-channel slot in the DMX frame).
struct Lamp: Identifiable, Sendable {
    let id: Int
    let name: String
    let icon: String
}

/// Manual light board: local state for every fixture, debounced pushes of the
/// full 21-channel frame to the agent (which heartbeats it to the bridge —
/// no show required).
@MainActor
@Observable
final class LightsModel {
    static let lamps: [Lamp] = [
        Lamp(id: 0, name: "Decke", icon: "light.recessed.fill"),
        Lamp(id: 1, name: "Display 1", icon: "play.display"),
        Lamp(id: 2, name: "Regal hinten", icon: "lamp.table.fill"),
        Lamp(id: 3, name: "Regal links", icon: "lamp.floor.fill"),
        Lamp(id: 4, name: "Display 2", icon: "play.display"),
        Lamp(id: 5, name: "Regal rechts", icon: "lamp.floor.fill"),
    ]

    var colors: [Color] = LightsModel.defaultColors
    var on: [Bool] = Array(repeating: false, count: 6)
    var laser = false
    var strobe = false

    var bridge = false
    var busy = false          // bridge is warming up for the first frame
    var error: String?

    var host = ""
    var token = ""
    var client: AtlasClient { AtlasClient(host: host, token: token.isEmpty ? nil : token) }

    static let defaultColors: [Color] = [
        Color(red: 1.0, green: 0.75, blue: 0.45),   // warm ceiling
        Color(red: 0.35, green: 0.55, blue: 1.0),
        Color(red: 0.9, green: 0.3, blue: 0.9),
        Color(red: 1.0, green: 0.4, blue: 0.5),
        Color(red: 0.3, green: 0.9, blue: 0.8),
        Color(red: 0.55, green: 0.45, blue: 1.0),
    ]

    /// The 21-channel DMX frame the bridge understands (ch 19 fog always 0).
    private func frame() -> [Int] {
        var ch = [Int](repeating: 0, count: 21)
        for i in 0..<6 where on[i] {
            let (r, g, b) = colors[i].rgb255
            ch[i * 3] = r
            ch[i * 3 + 1] = g
            ch[i * 3 + 2] = b
        }
        ch[19] = laser ? 255 : 0
        ch[20] = strobe ? 255 : 0
        return ch
    }

    // MARK: talking to atlas

    private var sendTask: Task<Void, Never>?

    /// Debounced push — dragging a color wheel fires continuously, the agent
    /// only needs the trailing state (it heartbeats the frame itself).
    func push() {
        sendTask?.cancel()
        let ch = frame()
        let wasCold = !bridge
        sendTask = Task {
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            if wasCold { busy = true }
            do {
                let s = try await client.lightsSet(ch)
                bridge = s.bridge
                error = nil
            } catch {
                self.error = "atlas nicht erreichbar"
            }
            busy = false
        }
    }

    /// Pull the agent's held frame so the board matches reality after launch.
    func sync() async {
        do {
            let s = try await client.lights()
            bridge = s.bridge
            error = nil
            guard s.on, s.channels.count >= 21 else { return }
            for i in 0..<6 {
                let r = s.channels[i * 3], g = s.channels[i * 3 + 1], b = s.channels[i * 3 + 2]
                if r + g + b > 0 {
                    on[i] = true
                    colors[i] = Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
                }
            }
            laser = s.channels[19] > 127
            strobe = s.channels[20] > 127
        } catch {
            self.error = "atlas nicht erreichbar"
        }
    }

    func allOn() {
        for i in 0..<6 { on[i] = true }
        push()
    }

    func allOff() {
        sendTask?.cancel()
        for i in 0..<6 { on[i] = false }
        laser = false
        strobe = false
        Task {
            do {
                try await client.lightsOff()
                error = nil
            } catch {
                self.error = "atlas nicht erreichbar"
            }
        }
    }
}

extension Color {
    /// sRGB components as 0…255 DMX values.
    var rgb255: (Int, Int, Int) {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Int(max(0, min(1, r)) * 255), Int(max(0, min(1, g)) * 255), Int(max(0, min(1, b)) * 255))
    }
}
