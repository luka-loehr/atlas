import SwiftUI

/// One issue, explained. Everything on this screen was written by the Curator
/// agent — including which commits belong here. Nothing is inferred client-side.
struct IssueDetailScreen: View {
    let issueKey: String
    @Environment(BoardStore.self) private var board
    @State private var detail: BoardIssueDetail?
    @State private var failed = false

    var body: some View {
        ZStack {
            Theme.background
            if let d = detail {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        head(d)
                        if d.needsYou { needsYouBanner(d.needsLuka ?? "") }
                        section("What it is", d.whatItIs)
                        section("Why it matters", d.whyItMatters)
                        section("Where it stands", d.currentState)
                        if let links = d.links, !links.isEmpty { commits(links) }
                        provenance(d)
                    }
                    .padding(18)
                }
            } else if failed {
                ContentUnavailableView("Couldn't load \(issueKey)",
                                       systemImage: "exclamationmark.triangle",
                                       description: Text("atlas didn't answer. Pull to retry from the board."))
            } else {
                ProgressView().tint(.white)
            }
        }
        .navigationTitle(issueKey)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task {
            detail = await board.detail(key: issueKey)
            failed = detail == nil
        }
    }

    private func head(_ d: BoardIssueDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(d.headline ?? d.title)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text(BoardWord.status(d.status))
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Theme.statusColor(d.status).opacity(0.18), in: .capsule)
                    .foregroundStyle(Theme.statusColor(d.status))
                if let a = d.assignee {
                    Text(a).font(.caption).foregroundStyle(.white.opacity(0.5))
                }
            }
            // the engineering title, kept but demoted — the headline is the point
            Text(d.title)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.38))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func needsYouBanner(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("This one needs you", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.hot)
            Text(text)
                .font(.callout).foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.hot.opacity(0.13), in: .rect(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15).stroke(Theme.hot.opacity(0.4)))
    }

    @ViewBuilder
    private func section(_ title: String, _ body: String?) -> some View {
        if let body, !body.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                Text(title.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.38))
                Text(body)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.88))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func commits(_ links: [BoardIssueDetail.Link]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("WHAT SHIPPED")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.38))
            ForEach(links) { l in
                VStack(alignment: .leading, spacing: 4) {
                    Text(l.subject ?? l.ref ?? "—")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 7) {
                        Text((l.kind ?? "commit").uppercased())
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Theme.accent.opacity(0.2), in: .capsule)
                            .foregroundStyle(Theme.accent)
                        if let r = l.repo { Text(r).font(.caption2) }
                        if !l.shortRef.isEmpty {
                            Text(l.shortRef).font(.caption2.monospaced())
                        }
                    }
                    .foregroundStyle(.white.opacity(0.42))
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.card, in: .rect(cornerRadius: 12))
            }
        }
    }

    private func provenance(_ d: BoardIssueDetail) -> some View {
        Text("Written by the Atlas Agents Curator" + (d.curatedAt.map { " · \($0.prefix(16).replacingOccurrences(of: "T", with: " "))" } ?? ""))
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.28))
            .padding(.top, 6)
    }
}
