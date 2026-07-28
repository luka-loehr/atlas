import ActivityKit
import SwiftUI
import WidgetKit

@main
struct AtlasAgentsWidgetBundle: WidgetBundle {
    var body: some Widget {
        AtlasAgentsStatusWidget()
        AtlasAgentsLiveActivity()
    }
}

// MARK: - Home-screen widget

struct FleetEntry: TimelineEntry {
    var date: Date
    var running: Int
    var open: Int
    var review: Int
    var runningNames: [String]
    var latestReport: String?
    var offline: Bool
}

struct FleetProvider: TimelineProvider {
    func placeholder(in context: Context) -> FleetEntry {
        FleetEntry(date: .now, running: 1, open: 4, review: 2,
                   runningNames: ["Founding Engineer"],
                   latestReport: "Second disk — options and recommendation", offline: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (FleetEntry) -> Void) {
        Task { completion(await fetch()) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<FleetEntry>) -> Void) {
        Task {
            let entry = await fetch()
            let next = Calendar.current.date(
                byAdding: .minute, value: entry.running > 0 ? 5 : 20, to: .now
            )!
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }

    // The extension has its own UserDefaults container, so the host and key
    // typed in Settings are not visible here — reading UserDefaults.standard
    // would always miss. Until the app declares an App Group, the widget uses
    // the values compiled in from Secrets.swift, and a rotated key needs a
    // rebuild for the widget even though the app itself picks it up live.
    private func fetch() async -> FleetEntry {
        let client = PaperclipClient(host: Secrets.host,
                                     token: Secrets.token,
                                     companyId: Secrets.companyId)
        do {
            async let dash = client.dashboard()
            async let agents = client.agents()
            async let artifacts = client.artifacts()
            async let issues = client.issues()
            let (d, a, arts, iss) = try await (dash, agents, artifacts, issues)
            let running = a.filter(\.isRunning)
            return FleetEntry(
                date: .now,
                running: running.count,
                open: d.tasks.open,
                review: iss.filter { $0.status == "in_review" }.count,
                runningNames: running.map(\.name),
                latestReport: arts.sorted { ($0.updatedAt ?? "") > ($1.updatedAt ?? "") }.first?.title,
                offline: false
            )
        } catch {
            return FleetEntry(date: .now, running: 0, open: 0, review: 0,
                              runningNames: [], latestReport: nil, offline: true)
        }
    }
}

struct AtlasAgentsStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "AgentsStatus", provider: FleetProvider()) { entry in
            FleetWidgetView(entry: entry)
                .containerBackground(Color(red: 0.039, green: 0.043, blue: 0.051), for: .widget)
        }
        .configurationDisplayName("Agent fleet")
        .description("Running agents and what needs you at Luka Labs.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct FleetWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: FleetEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(entry.offline ? .gray : entry.running > 0 ? .green : .blue)
                    .frame(width: 8, height: 8)
                Text(entry.offline ? "offline" : entry.running > 0 ? "\(entry.running) working" : "idle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                Spacer()
            }
            if entry.running > 0 {
                Text(entry.runningNames.prefix(2).joined(separator: ", "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            HStack(spacing: 14) {
                stat("\(entry.open)", "open", .white)
                stat("\(entry.review)", "review", entry.review > 0 ? .orange : .white)
            }
            if family == .systemMedium, let report = entry.latestReport {
                Divider().overlay(.white.opacity(0.1))
                HStack(spacing: 5) {
                    Image(systemName: "doc.text.fill").font(.system(size: 9))
                    Text(report).font(.caption2).lineLimit(1)
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(2)
    }

    private func stat(_ value: String, _ label: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Text(value)
                .font(.system(.body, design: .rounded).weight(.bold))
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Live Activity
//
// Apple's guidance drove this layout: the compact and minimal presentations
// have to stand on their own, content must stay concentric with the Island's
// shape, and clutter is the main failure mode. So compact shows one glyph and
// one number, minimal shows just the number, and the detail only appears in
// the expanded presentation the user opts into by long-pressing.

struct AtlasAgentsLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AgentActivityAttributes.self) { context in
            lockScreen(context.state)
                .activityBackgroundTint(Color(red: 0.039, green: 0.043, blue: 0.051))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "cpu.fill")
                        .font(.title3)
                        .foregroundStyle(.green)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("\(context.state.runningCount)")
                            .font(.system(.title3, design: .rounded).weight(.bold))
                            .foregroundStyle(.green)
                        Text("working")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.leadAgent)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        Text(context.state.leadTask)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if context.state.needsYou > 0 {
                        HStack(spacing: 5) {
                            Image(systemName: "hand.raised.fill")
                                .font(.system(size: 10))
                            Text("\(context.state.needsYou) waiting for you")
                                .font(.caption2.weight(.medium))
                        }
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } compactLeading: {
                Image(systemName: "cpu.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.green)
            } compactTrailing: {
                Text("\(context.state.runningCount)")
                    .font(.system(size: 15, design: .rounded).weight(.bold))
                    .foregroundStyle(context.state.needsYou > 0 ? .orange : .green)
                    .monospacedDigit()
            } minimal: {
                Text("\(context.state.runningCount)")
                    .font(.system(size: 13, design: .rounded).weight(.bold))
                    .foregroundStyle(context.state.needsYou > 0 ? .orange : .green)
                    .monospacedDigit()
            }
            .keylineTint(.green)
        }
    }

    private func lockScreen(_ state: AgentActivityAttributes.ContentState) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(.green.opacity(0.15))
                    .frame(width: 38, height: 38)
                Image(systemName: "cpu.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.green)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(state.leadAgent)
                        .font(.subheadline.weight(.semibold))
                    if !state.leadTaskId.isEmpty {
                        Text(state.leadTaskId)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.green)
                    }
                    if state.runningCount > 1 {
                        Text("+\(state.runningCount - 1)")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(state.leadTask)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if state.needsYou > 0 {
                VStack(spacing: 1) {
                    Text("\(state.needsYou)")
                        .font(.system(.title3, design: .rounded).weight(.bold))
                        .foregroundStyle(.orange)
                    Text("for you")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
    }
}
