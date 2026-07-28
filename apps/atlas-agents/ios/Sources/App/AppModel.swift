import ActivityKit
import Foundation
import SwiftUI
import UserNotifications

@MainActor
@Observable
final class AppModel {
    // connection — defaults come from Secrets.swift, overridable in Settings
    var host: String = UserDefaults.standard.string(forKey: "pcHost") ?? Secrets.host {
        didSet { UserDefaults.standard.set(host, forKey: "pcHost") }
    }
    var token: String = UserDefaults.standard.string(forKey: "pcToken") ?? Secrets.token {
        didSet { UserDefaults.standard.set(token, forKey: "pcToken") }
    }
    var bridgeHost: String = UserDefaults.standard.string(forKey: "bridgeHost") ?? Secrets.bridgeHost {
        didSet { UserDefaults.standard.set(bridgeHost, forKey: "bridgeHost") }
    }
    var liveActivityEnabled: Bool = UserDefaults.standard.object(forKey: "liveActivity") as? Bool ?? true {
        didSet { UserDefaults.standard.set(liveActivityEnabled, forKey: "liveActivity") }
    }
    var notifyOnReport: Bool = UserDefaults.standard.object(forKey: "notifyReport") as? Bool ?? true {
        didSet { UserDefaults.standard.set(notifyOnReport, forKey: "notifyReport") }
    }

    var client: PaperclipClient {
        PaperclipClient(host: host, token: token, companyId: Secrets.companyId)
    }

    let live = LiveStream()

    var bridge: BridgeClient { BridgeClient(host: bridgeHost, token: token) }

    // our own layer: the conversation, open questions, and what it all costs
    var asks: [Ask] = []
    var spend: Spend = .empty

    /// Which tab is showing — lets the dashboard push you into Inbox/Tasks.
    var selectedTab: Int = 0

    // state
    var dashboard: Dashboard?
    var agents: [PCAgent] = []
    var issues: [PCIssue] = []
    var artifacts: [PCArtifact] = []
    var activity: [PCActivity] = []
    var lastError: String?
    var lastRefresh: Date?

    private var pollTask: Task<Void, Never>?

    var runningAgents: [PCAgent] { agents.filter(\.isRunning) }
    /// The only thing that blocks Luka now: open questions from his lead.
    var needsYouCount: Int { asks.count }

    func issueFor(_ agent: PCAgent) -> PCIssue? {
        issues.first { $0.assigneeAgentId == agent.id && $0.status == "in_progress" }
            ?? issues.first { $0.assigneeAgentId == agent.id && $0.status != "done" && $0.status != "cancelled" }
    }

    // MARK: refresh

    func refresh() async {
        do {
            async let d = client.dashboard()
            async let a = client.agents()
            async let i = client.issues()
            async let art = client.artifacts()
            async let act = client.activity()
            let (dash, ags, iss, arts, acts) = try await (d, a, i, art, act)
            dashboard = dash
            agents = ags
            issues = iss.sorted { ($0.updatedAt ?? "") > ($1.updatedAt ?? "") }
            artifacts = arts.sorted { ($0.updatedAt ?? "") > ($1.updatedAt ?? "") }
            activity = acts
            lastError = nil
            lastRefresh = Date()
            await refreshBridge()
            await syncLiveActivity()
            notifyIfNeeded()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// The bridge owns chat, asks and spend — it degrades independently of Paperclip.
    func refreshBridge() async {
        async let a = bridge.asks()
        async let s = bridge.spend()
        if let open = try? await a { asks = open.filter { $0.status == "pending" } }
        if let money = try? await s { spend = money }
    }

    private func notifyIfNeeded() {
        NotificationEngine.diffAndNotify(
            asks: asks,
            artifacts: artifacts,
            wantReport: notifyOnReport
        )
    }

    func startPolling(interval: TimeInterval = 20) {
        live.connect(host: bridgeHost, token: token) { [weak self] in
            Task { @MainActor in await self?.refresh() }
        }
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                // The bridge drives freshness; this is just a safety net.
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        live.disconnect()
    }

    // MARK: Live Activity / Dynamic Island

    private var activityHandle: Activity<AgentActivityAttributes>?

    func syncLiveActivity() async {
        guard liveActivityEnabled else { await endLiveActivity(); return }
        let running = runningAgents
        guard !running.isEmpty else { await endLiveActivity(); return }

        let lead = running.first
        let state = AgentActivityAttributes.ContentState(
            runningCount: running.count,
            leadAgent: lead?.name ?? "Agent",
            leadTask: lead.flatMap { issueFor($0)?.title } ?? "working",
            leadTaskId: lead.flatMap { issueFor($0)?.identifier } ?? "",
            needsYou: needsYouCount,
            updatedAt: Date()
        )
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(600))

        if activityHandle == nil {
            activityHandle = Activity<AgentActivityAttributes>.activities.first
        }
        if let handle = activityHandle {
            await handle.update(content)
        } else if ActivityAuthorizationInfo().areActivitiesEnabled {
            activityHandle = try? Activity.request(
                attributes: AgentActivityAttributes(companyName: "Luka Labs"),
                content: content
            )
        }
    }

    func endLiveActivity() async {
        for activity in Activity<AgentActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        activityHandle = nil
    }
}

// MARK: - Local notifications

enum NotificationEngine {
    /// Only three things are worth interrupting Luka for: his lead asked
    /// something, his lead replied, or a report landed.
    static func diffAndNotify(
        asks: [Ask],
        artifacts: [PCArtifact],
        wantReport: Bool = true
    ) {
        let defaults = UserDefaults.standard
        let firstRun = defaults.object(forKey: "seenAskIds") == nil

        let askIds = Set(asks.map(\.id))
        let artifactIds = Set(artifacts.map(\.id))
        let seenAsks = Set(defaults.stringArray(forKey: "seenAskIds") ?? [])
        let seenArtifacts = Set(defaults.stringArray(forKey: "seenArtifactIds") ?? [])

        defaults.set(Array(askIds), forKey: "seenAskIds")
        defaults.set(Array(artifactIds), forKey: "seenArtifactIds")
        if firstRun { return }

        for ask in asks where !seenAsks.contains(ask.id) {
            post(title: "\(ask.agent) needs a decision",
                 body: ask.headline,
                 id: "ask-\(ask.id)")
        }
        if wantReport {
            for artifact in artifacts where !seenArtifacts.contains(artifact.id) {
                post(title: "New report from \(artifact.createdByAgent?.name ?? "an agent")",
                     body: artifact.title ?? "Document",
                     id: "artifact-\(artifact.id)")
            }
        }
    }

    private static func post(title: String, body: String, id: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: id, content: content, trigger: nil)
        )
    }

    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge, .timeSensitive]) { _, _ in }
    }
}
