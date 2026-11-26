import SwiftUI

/// Shared copy, brand palette, and links for the iOS and macOS onboarding flows.
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

    /// Atlas brand colors pulled directly from AppIcon.icon (ocean blue + glacier cyan).
    static let oceanBlue = Color(red: 0.10, green: 0.48, blue: 0.84)
    static let glacierCyan = Color(red: 0.30, green: 0.82, blue: 0.88)

    struct StorySlide: Identifiable {
        let id: Int
        let title: String
        let detail: String
    }

    static let slides: [StorySlide] = [
        StorySlide(
            id: 0,
            title: "Your home server, your library.",
            detail: "Photos, videos, and files stored on your own machine — never a cloud."
        ),
        StorySlide(
            id: 1,
            title: "Search by what you remember.",
            detail: "Faces, pets, places, and text indexed privately on your own GPU."
        ),
        StorySlide(
            id: 2,
            title: "Private over Tailscale.",
            detail: "Direct encrypted link to your iPhone and Mac. Zero open ports."
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
            detail: "Paste the agent prompt into Claude Code, Codex, or Cursor — or follow the docs."
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
