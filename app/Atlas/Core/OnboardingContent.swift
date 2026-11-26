import SwiftUI

/// Shared copy, links, and prompts for the iOS and macOS onboarding flows.
enum OnboardingContent {
    static let docsURL = URL(string: "https://atlas.lukaloehr.com/docs")!
    static let agentSetupURL = URL(string: "https://atlas.lukaloehr.com/docs/agent-setup")!

    /// Ready-to-paste prompt for Claude Code, Codex, or Cursor using the
    /// Pholio-generated llms.txt and Markdown docs.
    static let agentPrompt = """
    Set up Atlas (self-hosted photo library, drive, and homelab control plane) for me.
    Start by reading https://atlas.lukaloehr.com/docs/llms.txt and then follow
    https://atlas.lukaloehr.com/docs/getting-started.md and https://atlas.lukaloehr.com/docs/cli.md.

    Before running any commands, ask me:
    1. Do I already have an Ubuntu Linux server (with SSH access and an NVIDIA GPU), or am I setting up from scratch?
    2. What is my server's SSH host / IP, username, and Tailscale hostname?
    3. Do I want to install the `atlas` CLI on this Mac too?

    Walk me through each step, run what you can automatically, verify every service is healthy,
    and finish by running `atlas connect` so I can connect the Atlas iPhone/Mac app.
    Never print or log my ATLAS_TOKEN or POSTGRES_PASSWORD in chat output.
    """

    struct Feature: Identifiable {
        let id: String
        let icon: String
        let tint: Color
        let title: String
        let detail: String
    }

    static let features: [Feature] = [
        Feature(
            id: "search",
            icon: "sparkles",
            tint: .indigo,
            title: "Search by what you remember",
            detail: "Find photos, videos, people, pets, and text using your own GPU."
        ),
        Feature(
            id: "privacy",
            icon: "lock.shield.fill",
            tint: .green,
            title: "Private over Tailscale",
            detail: "Everything stays on your home server with zero open ports or cloud fees."
        ),
        Feature(
            id: "apple",
            icon: "macbook.and.iphone",
            tint: .blue,
            title: "Built for your Apple devices",
            detail: "Background photo backup, personal drive, and live server control."
        ),
    ]

    struct SetupStep: Identifiable {
        let id: Int
        let title: String
        let detail: String
    }

    static let setupSteps: [SetupStep] = [
        SetupStep(
            id: 1,
            title: "Set up your Linux server",
            detail: "Paste the agent prompt into Claude Code, Codex, or Cursor — or follow the step-by-step docs."
        ),
        SetupStep(
            id: 2,
            title: "Turn on Tailscale",
            detail: "Sign into Tailscale on your server and on this device so they connect privately."
        ),
        SetupStep(
            id: 3,
            title: "Pair in one tap",
            detail: "Run “atlas connect” on your Mac, then open or paste the link here."
        ),
    ]

    /// Turns a raw network error into a clear, actionable message for first-time setup.
    static func friendlyError(for error: Error) -> String {
        if case APIError.unauthorized = error {
            return "That access token was rejected. Double-check ATLAS_TOKEN in /etc/atlas/atlas.env or run “atlas connect” again."
        }
        if case APIError.unreachable = error {
            return "Couldn’t reach your server. Make sure Tailscale is connected and your server is awake."
        }
        return error.localizedDescription
    }
}
