import ActivityKit
import Foundation

/// Live Activity state.
///
/// Apple's guidance: a Live Activity is a glance surface, and the compact and
/// minimal presentations must stand on their own. So the state carries one
/// lead agent and its task rather than a list — plus the count that decides
/// whether Luka needs to act. Content states also have to stay well under
/// ActivityKit's 4 KB budget, which rules out shipping the whole roster.
struct AgentActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var runningCount: Int
        var leadAgent: String
        var leadTask: String
        var leadTaskId: String
        var needsYou: Int
        var updatedAt: Date
    }
    var companyName: String
}
