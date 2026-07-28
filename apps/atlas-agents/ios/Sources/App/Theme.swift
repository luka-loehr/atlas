import SwiftUI

// MARK: - Design system
//
// One place for surface colors and status semantics, so every screen reads as
// the same app. Only what the three screens and the widget actually use lives
// here — an unused shape or helper is a lie about how the app looks.

enum Theme {
    // Same palette as the Atlas Admin app, so the two read as one family.
    static let bgTop = Color(red: 0.04, green: 0.05, blue: 0.09)
    static let bgBottom = Color(red: 0.02, green: 0.02, blue: 0.04)
    static let bg = bgBottom
    static let card = Color(red: 0.086, green: 0.094, blue: 0.110)
    static let accent = Color(red: 0.22, green: 0.60, blue: 1.0)      // atlas blue
    static let good = Color(red: 0.20, green: 0.85, blue: 0.55)
    static let warn = Color(red: 1.0, green: 0.72, blue: 0.20)
    static let hot = Color(red: 1.0, green: 0.35, blue: 0.42)

    /// Navy gradient with a soft accent glow at the top edge.
    static var background: some View {
        LinearGradient(colors: [bgTop, bgBottom], startPoint: .top, endPoint: .bottom)
            .overlay(alignment: .top) {
                RadialGradient(colors: [accent.opacity(0.18), .clear],
                               center: .top, startRadius: 0, endRadius: 420)
                    .blur(radius: 30)
            }
            .ignoresSafeArea()
    }

    static func statusColor(_ status: String) -> Color {
        switch status {
        case "running": .green
        case "idle": Theme.accent
        case "paused": .gray
        case "error": .red
        case "in_review": .orange
        case "in_progress": .cyan
        case "todo", "backlog": .gray
        case "done": .green
        case "cancelled": .secondary
        default: .gray
        }
    }

    /// Short label for a status chip. `BoardWord.status` is the long-form
    /// wording used on the board itself; this is the version that fits a pill.
    static func statusLabel(_ status: String) -> String {
        switch status {
        case "in_review": "In review"
        case "in_progress": "Active"
        case "todo": "Open"
        case "backlog": "Parked"
        case "blocked": "Waiting"
        case "done": "Done"
        case "cancelled": "Dropped"
        case "running": "Running"
        case "idle": "Idle"
        case "paused": "Paused"
        case "error": "Error"
        default: status.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    static func statusIcon(_ status: String) -> String {
        switch status {
        case "running": "bolt.fill"
        case "idle": "moon.zzz.fill"
        case "paused": "pause.circle.fill"
        case "error": "exclamationmark.triangle.fill"
        case "in_review": "eye.fill"
        case "in_progress": "arrow.triangle.2.circlepath"
        case "done": "checkmark.circle.fill"
        default: "circle"
        }
    }
}

// MARK: - Building blocks

/// Small status pill used for issues and agents alike.
struct StatusChip: View {
    let status: String
    var compact = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: Theme.statusIcon(status))
                .font(.system(size: compact ? 8 : 9, weight: .bold))
            Text(Theme.statusLabel(status))
                .font(.system(size: compact ? 10 : 11, weight: .semibold))
        }
        .padding(.horizontal, compact ? 6 : 8)
        .padding(.vertical, compact ? 2 : 3)
        .background(Theme.statusColor(status).opacity(0.18), in: Capsule())
        .foregroundStyle(Theme.statusColor(status))
    }
}
