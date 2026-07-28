import SwiftUI

/// Every issue, grouped by what state it is in — using words that mean what
/// they say. Tap anything to read it properly.
struct BoardScreen: View {
    @Environment(BoardStore.self) private var board
    @State private var query = ""

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22, pinnedViews: [.sectionHeaders]) {
                        ForEach(sections, id: \.status) { section in
                            Section {
                                VStack(spacing: 8) {
                                    ForEach(section.issues) { issue in
                                        NavigationLink(value: issue.key) { row(issue) }
                                            .buttonStyle(.plain)
                                    }
                                }
                            } header: {
                                header(section.status, count: section.issues.count)
                            }
                        }
                        if sections.isEmpty {
                            Text(query.isEmpty ? "Nothing on the board yet." : "No match for “\(query)”.")
                                .font(.footnote).foregroundStyle(.white.opacity(0.5))
                                .padding(.top, 40)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
                .refreshable { await board.refresh() }
            }
            .navigationTitle("Board")
            .toolbarColorScheme(.dark, for: .navigationBar)
            .searchable(text: $query, prompt: "Search the board")
            .navigationDestination(for: String.self) { IssueDetailScreen(issueKey: $0) }
        }
    }

    private var sections: [(status: String, issues: [BoardIssue])] {
        guard !query.isEmpty else { return board.sections }
        let q = query.lowercased()
        return board.sections.compactMap { s in
            let hits = s.issues.filter {
                $0.title.lowercased().contains(q)
                    || ($0.headline ?? "").lowercased().contains(q)
                    || $0.key.lowercased().contains(q)
            }
            return hits.isEmpty ? nil : (s.status, hits)
        }
    }

    private func header(_ status: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Text(BoardWord.status(status))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.statusColor(status))
            Text("\(count)")
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.4))
            Spacer()
        }
        .padding(.vertical, 7)
        .background(Theme.bg.opacity(0.96))
    }

    private func row(_ issue: BoardIssue) -> some View {
        HStack(alignment: .top, spacing: 11) {
            VStack(alignment: .leading, spacing: 5) {
                Text(issue.display)
                    .font(.callout)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Text(issue.key).font(.caption2.monospaced())
                    if let a = issue.assignee { Text(a).font(.caption2) }
                    if let n = issue.linkCount, n > 0 {
                        Label("\(n)", systemImage: "arrow.triangle.branch").font(.caption2)
                    }
                }
                .foregroundStyle(.white.opacity(0.42))
            }
            Spacer(minLength: 0)
            if issue.needsYou {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.footnote).foregroundStyle(Theme.hot)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: .rect(cornerRadius: 13))
        .overlay(
            RoundedRectangle(cornerRadius: 13)
                .stroke(issue.needsYou ? Theme.hot.opacity(0.4) : .clear)
        )
    }
}
