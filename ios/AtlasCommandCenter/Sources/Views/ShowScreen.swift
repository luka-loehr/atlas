import SwiftUI

@MainActor
@Observable
final class ShowModel {
    var shows: [Show] = []
    var bridge = false
    var error: String?
    var host = ""
    var token = ""

    // YouTube create
    var creating = false
    var createLog = ""

    var client: AtlasClient { AtlasClient(host: host, token: token.isEmpty ? nil : token) }

    func load() async {
        do {
            let r = try await client.shows()
            shows = r.shows
            bridge = r.bridge
            error = nil
        } catch { self.error = "atlas nicht erreichbar" }
    }

    func create(url: String) async {
        creating = true
        createLog = "starte …"
        do { try await client.createShow(url: url) } catch {
            creating = false; createLog = "Start fehlgeschlagen"; return
        }
        // poll until done
        for _ in 0..<300 {
            try? await Task.sleep(for: .seconds(2))
            guard let s = try? await client.createStatus() else { continue }
            createLog = s.log.split(separator: "\n").last.map(String.init) ?? createLog
            if s.done || s.failed || !s.running {
                creating = false
                await load()
                return
            }
        }
        creating = false
    }
}

struct ShowScreen: View {
    var host: String
    var token: String
    @State private var model = ShowModel()
    @State private var showCreate = false
    @State private var demoShow: Show?

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background
                ScrollView {
                    VStack(spacing: 14) {
                        bridgeBadge
                        ForEach(model.shows) { show in
                            NavigationLink {
                                ShowPlayerView(model: model, show: show)
                            } label: {
                                ShowCard(show: show)
                            }
                            .buttonStyle(.plain)
                        }
                        // standalone fog — no show required
                        FogHoldButton(client: model.client)
                            .padding(.top, 18)
                    }
                    .padding(16)
                }
                .scrollIndicators(.hidden)
                .refreshable { await model.load() }
            }
            .navigationDestination(item: $demoShow) { ShowPlayerView(model: model, show: $0) }
            .navigationTitle("Lightshows")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task { try? await model.client.stopBridge(); await model.load() }
                    } label: {
                        Image(systemName: "power")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showCreate = true } label: {
                        Image(systemName: "link.badge.plus")
                    }
                }
            }
        }
        .task {
            model.host = host
            model.token = token
            await model.load()
            if let n = ProcessInfo.processInfo.environment["ATLAS_DEMO_SHOW"],
               let s = model.shows.first(where: { $0.name == n }) {
                demoShow = s
            }
        }
        .sheet(isPresented: $showCreate) {
            CreateShowSheet(model: model)
        }
    }

    private var bridgeBadge: some View {
        HStack(spacing: 8) {
            Circle().fill(model.bridge ? Theme.good : Theme.warn).frame(width: 8, height: 8)
            Text(model.bridge ? "Bridge aktiv" : "Bridge aus — Start weckt sie")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
            Spacer()
        }
        .padding(.horizontal, 4)
    }
}

struct ShowCard: View {
    var show: Show

    var body: some View {
        GlassCard {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(LinearGradient(colors: [Theme.accent.opacity(0.6), Theme.violet.opacity(0.6)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 52, height: 52)
                    Image(systemName: show.running ? "waveform" : "play.fill")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(show.title)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text("\(Int(show.bpm)) BPM · \(Int(show.durationS / 60)):\(String(format: "%02d", Int(show.durationS) % 60))")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                }
                Spacer()
                if show.running {
                    Text("LIVE")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(Theme.hot)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Theme.hot.opacity(0.15), in: Capsule())
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.3))
            }
        }
    }
}

struct CreateShowSheet: View {
    var model: ShowModel
    @State private var url = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background
                VStack(spacing: 18) {
                    Image(systemName: "link.badge.plus")
                        .font(.system(size: 40))
                        .foregroundStyle(Theme.accent)
                        .padding(.top, 20)
                    Text("Show aus YouTube")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("Link einfügen — atlas lädt den Song, analysiert Beats & Drops auf der GPU und baut die Show.")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.5))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)

                    TextField("https://youtu.be/…", text: $url)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .padding(14)
                        .glassEffect(.regular, in: .rect(cornerRadius: 16))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)

                    if model.creating {
                        VStack(spacing: 8) {
                            ProgressView().tint(.white)
                            Text(model.createLog)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.5))
                                .lineLimit(2)
                        }
                    } else {
                        Button {
                            Task { await model.create(url: url) }
                        } label: {
                            Text("Show erstellen")
                                .font(.system(size: 16, weight: .bold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                        }
                        .buttonStyle(.glassProminent)
                        .tint(Theme.accent)
                        .disabled(!url.hasPrefix("http"))
                        .padding(.horizontal, 20)
                    }
                    Spacer()
                }
            }
            .navigationTitle("Neue Show")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
            .onChange(of: model.creating) { _, now in
                if !now && !model.shows.isEmpty { dismiss() }
            }
        }
    }
}
