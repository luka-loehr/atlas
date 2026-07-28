import SwiftUI

struct SettingsScreen: View {
    @Environment(AppModel.self) private var model
    @State private var projects: [PCProject] = []
    @State private var skills: [PCSkill] = []
    @State private var routines: [PCRoutine] = []
    @State private var runningRoutine: String?

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            List {
                connectionSection
                notificationSection
                companySection
                automationSection
                diagnosticsSection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Settings")
            .task { await load() }
            .refreshable { await load() }
        }
    }

    // MARK: connection

    private var connectionSection: some View {
        @Bindable var model = model
        return Section {
            LabeledContent("Status") {
                HStack(spacing: 6) {
                    Circle()
                        .fill(model.lastError == nil ? .green : .red)
                        .frame(width: 7, height: 7)
                    Text(model.lastError == nil ? "Connected" : "Error")
                        .font(.caption)
                }
            }
            LabeledContent("Live stream") {
                Text(model.live.connected ? "Connected" : "Reconnecting…")
                    .font(.caption)
                    .foregroundStyle(model.live.connected ? .green : .secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Paperclip host").font(.caption).foregroundStyle(.secondary)
                TextField("host:port", text: $model.host)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(.callout.monospaced())
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Bridge host").font(.caption).foregroundStyle(.secondary)
                TextField("host:port", text: $model.bridgeHost)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(.callout.monospaced())
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Board API key").font(.caption).foregroundStyle(.secondary)
                SecureField("pcp_board_…", text: $model.token)
                    .font(.callout.monospaced())
            }
        } header: {
            Text("Connection")
        } footer: {
            Text("Both services live on the tailnet. The bridge pushes live updates; without it the app falls back to polling every 20 s.")
        }
    }

    // MARK: notifications

    private var notificationSection: some View {
        @Bindable var model = model
        return Section {
            Toggle("Live Activity while agents run", isOn: $model.liveActivityEnabled)
            Toggle("Notify on new reports", isOn: $model.notifyOnReport)
        } header: {
            Text("Alerts")
        } footer: {
Text("Your lead always notifies you — when it replies, and when it needs a decision.")
        }
    }

    // MARK: company

    private var companySection: some View {
        Section("Company") {
            LabeledContent("Agents", value: "\(model.agents.count)")
            LabeledContent("Open tasks", value: "\(model.dashboard?.tasks.open ?? 0)")
            LabeledContent("Open questions", value: "\(model.needsYouCount)")
            LabeledContent("Spent", value: String(format: "$%.2f", model.spend.totals.usd))
            if !projects.isEmpty {
                NavigationLink {
                    List(projects) { project in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(project.name).font(.subheadline)
                            HStack(spacing: 6) {
                                if let s = project.status { StatusChip(status: s, compact: true) }
                                if let d = project.description {
                                    Text(d).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .navigationTitle("Projects")
                } label: {
                    LabeledContent("Projects", value: "\(projects.count)")
                }
            }
        }
    }

    // MARK: skills + routines

    private var automationSection: some View {
        Section {
            NavigationLink {
                List(skills) { skill in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(skill.name).font(.subheadline)
                        if let d = skill.description {
                            Text(d).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
                        }
                        if let path = skill.folderPath {
                            Text(path).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                        }
                    }
                }
                .navigationTitle("Skills")
            } label: {
                LabeledContent("Skills", value: "\(skills.count)")
            }

            NavigationLink {
                List(routines) { routine in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(routine.title).font(.subheadline)
                            if let s = routine.status {
                                Text(s).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button {
                            runningRoutine = routine.id
                            Task {
                                try? await model.client.runRoutine(routineId: routine.id)
                                runningRoutine = nil
                                await model.refresh()
                            }
                        } label: {
                            if runningRoutine == routine.id {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Run").font(.caption.weight(.medium))
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .navigationTitle("Routines")
            } label: {
                LabeledContent("Routines", value: "\(routines.count)")
            }
        } header: {
            Text("Automation")
        } footer: {
            Text("Skills are the capabilities agents can use. Routines are scheduled sweeps you can also trigger by hand.")
        }
    }

    // MARK: diagnostics

    private var diagnosticsSection: some View {
        Section {
            LabeledContent("Last refresh") {
                if let t = model.lastRefresh {
                    Text(t, style: .time)
                } else {
                    Text("—")
                }
            }
            if let at = model.live.lastEventAt {
                LabeledContent("Last live event") { Text(at, style: .relative) }
            }
            if let error = model.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Button("Refresh now") {
                Task { await model.refresh() }
            }
            Button("Restart live stream") {
                model.stopPolling()
                model.startPolling()
            }
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("Paperclip stays the backbone — this app is the interface. Anything not exposed here still exists in the Paperclip web UI on the tailnet.")
        }
    }

    private func load() async {
        async let p = model.client.projects()
        async let s = model.client.skills()
        async let r = model.client.routines()
        projects = (try? await p) ?? []
        skills = (try? await s) ?? []
        routines = (try? await r) ?? []
    }
}
