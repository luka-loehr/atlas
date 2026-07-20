import SwiftUI

@MainActor
@Observable
final class ShowModel {
    var shows: [Show] = []
    var bridge = false
    var error: String?
    var host = ""
    var token = ""

    // YouTube create (live progress)
    var creating = false
    var createStatus: CreateStatus?

    var client: AtlasClient { AtlasClient(host: host, token: token.isEmpty ? nil : token) }

    func load() async {
        do {
            let r = try await client.shows()
            shows = r.shows
            bridge = r.bridge
            error = nil
        } catch { self.error = "atlas nicht erreichbar" }
    }

    func create(url: String, ai: Bool) async {
        creating = true
        createStatus = nil
        do { try await client.createShow(url: url, ai: ai) } catch {
            creating = false
            return
        }
        for _ in 0..<1200 {
            try? await Task.sleep(for: .seconds(1))
            guard let s = try? await client.createStatus() else { continue }
            createStatus = s
            if s.done || s.failed || (!s.running && s.phase != "start") {
                break
            }
        }
        creating = false
        await load()
    }
}

struct ShowsScreen: View {
    var host: String
    var token: String
    @Binding var showSettings: Bool

    @State private var model = ShowModel()
    @State private var showCreate = false
    @State private var showCalibration = false
    @State private var demoShow: Show?

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background
                ScrollView {
                    VStack(spacing: 14) {
                        bridgeBadge
                        if model.shows.isEmpty {
                            emptyState
                        }
                        ForEach(model.shows) { show in
                            NavigationLink {
                                ShowPlayerView(model: model, show: show)
                            } label: {
                                ShowCard(show: show, thumbURL: model.client.showThumbURL(show.name))
                            }
                            .buttonStyle(.plain)
                        }
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
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showCalibration = true } label: {
                        Image(systemName: "camera.metering.center.weighted")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showCreate = true } label: {
                        Image(systemName: "link.badge.plus")
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $showCalibration) {
            CalibrationView(model: model)
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
            Text(model.bridge ? "Bridge aktiv — Start & Nebel sofort" : "Bridge aus — erster Start braucht ~4s")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
            Spacer()
        }
        .padding(.horizontal, 4)
    }

    private var emptyState: some View {
        GlassCard(padding: 26) {
            VStack(spacing: 12) {
                Image(systemName: "sparkles.rectangle.stack")
                    .font(.system(size: 34))
                    .foregroundStyle(Theme.accent)
                Text(model.error ?? "noch keine Shows")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("Erstelle eine Show aus einem YouTube-Link — oben rechts.")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.top, 30)
    }
}

struct ShowCard: View {
    var show: Show
    var thumbURL: URL?

    var body: some View {
        GlassCard {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(LinearGradient(colors: [Theme.accent.opacity(0.6), Theme.violet.opacity(0.6)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                    if let thumbURL {
                        AsyncImage(url: thumbURL) { img in
                            img.resizable().aspectRatio(contentMode: .fill)
                        } placeholder: {
                            Image(systemName: "play.fill")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    } else {
                        Image(systemName: "play.fill")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 14))

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
