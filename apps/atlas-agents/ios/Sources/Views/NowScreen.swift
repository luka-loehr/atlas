import SwiftUI

/// The screen Luka opens to answer one question: is anything actually happening?
/// It answers that in the first line, before any scrolling.
struct NowScreen: View {
    @Environment(BoardStore.self) private var board

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        headline
                        if !board.needsYou.isEmpty { needsYouBlock }
                        if !board.fleet.agents.isEmpty { workingBlock }
                        if board.fleet.agents.isEmpty && board.fleet.running > 0 { runningWithoutDetail }
                        if let err = board.lastError { errorBlock(err) }
                        footer
                    }
                    .padding(18)
                }
                .refreshable { await board.refresh() }
            }
            .navigationTitle("Now")
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }

    // MARK: the one-line answer

    private var headline: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(summaryLine)
                .font(.system(size: 27, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            if board.fleet.isStale {
                Label("This snapshot is over 15 minutes old", systemImage: "clock.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(Theme.warn)
            }
        }
    }

    private var summaryLine: String {
        let n = board.fleet.running
        switch n {
        case 0:  return "Nothing running right now."
        case 1:  return "1 agent working."
        default: return "\(n) agents working in parallel."
        }
    }

    // MARK: what's on you

    private var needsYouBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Waiting on you", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.hot)
            ForEach(board.needsYou) { issue in
                NavigationLink(value: issue.key) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(issue.needsLuka ?? "")
                            .font(.callout)
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(issue.key)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.white.opacity(0.45))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Theme.hot.opacity(0.13), in: .rect(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.hot.opacity(0.35)))
                }
                .buttonStyle(.plain)
            }
        }
        .navigationDestination(for: String.self) { IssueDetailScreen(issueKey: $0) }
    }

    // MARK: who is working

    private var workingBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Working now").font(.subheadline.weight(.semibold)).foregroundStyle(.white.opacity(0.75))
                Spacer()
                if board.fleet.queued > 0 {
                    // never the word "queued" — he read that as "stuck"
                    Text("\(board.fleet.queued) waiting to start")
                        .font(.caption).foregroundStyle(.white.opacity(0.5))
                }
            }
            ForEach(board.fleet.agents) { w in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Circle().fill(Theme.good).frame(width: 7, height: 7)
                        Text(w.agentName ?? "Agent")
                            .font(.callout.weight(.semibold)).foregroundStyle(.white)
                        Spacer()
                        if let k = w.issueKey {
                            Text(k).font(.caption2.monospaced()).foregroundStyle(.white.opacity(0.4))
                        }
                    }
                    if let h = w.headline, !h.isEmpty {
                        Text(h)
                            .font(.footnote).foregroundStyle(.white.opacity(0.7))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Theme.card, in: .rect(cornerRadius: 14))
            }
        }
    }

    private var runningWithoutDetail: some View {
        Text("\(board.fleet.running) running, but the snapshot has no detail yet.")
            .font(.footnote).foregroundStyle(.white.opacity(0.5))
    }

    private func errorBlock(_ msg: String) -> some View {
        Label(msg, systemImage: "wifi.exclamationmark")
            .font(.footnote)
            .foregroundStyle(Theme.warn)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.warn.opacity(0.12), in: .rect(cornerRadius: 12))
    }

    private var footer: some View {
        HStack {
            Text("\(board.issues.count) issues on the board")
            Spacer()
            if let t = board.lastRefresh {
                Text(t.formatted(date: .omitted, time: .shortened))
            }
        }
        .font(.caption2)
        .foregroundStyle(.white.opacity(0.35))
        .padding(.top, 4)
    }
}
