import AppKit
import SwiftUI

/// First-launch onboarding on macOS: welcomes new users, offers a built-in
/// setup guide with a one-click AI agent prompt, and connects via an
/// `atlas://connect` link or manual entry.
struct MacConnectView: View {
    @Environment(Session.self) private var session
    @State private var step: Step = .welcome
    @State private var showSetupGuide = false
    @State private var address = ""
    @State private var token = ""
    @State private var connecting = false
    @State private var error: String?

    private enum Step { case welcome, connect }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Group {
                switch step {
                case .welcome:
                    welcomeView
                case .connect:
                    connectView
                }
            }
            .frame(maxWidth: 480)
            .padding(36)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(step == .welcome ? "Welcome to Atlas" : "Connect to Atlas")
        .sheet(isPresented: $showSetupGuide) {
            MacSetupGuideSheet()
        }
    }

    private var welcomeView: some View {
        VStack(spacing: 28) {
            VStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 88, height: 88)
                    .accessibilityHidden(true)
                Text("Welcome to Atlas")
                    .font(.largeTitle.bold())
                Text("Your personal photo library, drive, and home server — completely private.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 18) {
                ForEach(OnboardingContent.features) { feature in
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: feature.icon)
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(feature.tint)
                            .frame(width: 32, height: 32)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(feature.title)
                                .font(.headline)
                            Text(feature.detail)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 10) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { step = .connect }
                } label: {
                    Text("Connect to My Server")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)

                Button {
                    showSetupGuide = true
                } label: {
                    Text("Don’t Have a Server Yet? Set Up Atlas…")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
    }

    private var connectView: some View {
        VStack(spacing: 20) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text("Connect to Your Server")
                    .font(.title.bold())
                Text("Paste the link from “atlas connect”, or enter your server address and token.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                pasteConnectLink()
            } label: {
                Label("Paste “atlas connect” Link", systemImage: "link.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(connecting)

            Form {
                TextField("Server Address", text: $address, prompt: Text("atlas.your-tailnet.ts.net"))
                    .textContentType(.URL)
                    .plainTextEntry()
                SecureField("Access Token", text: $token)
                    .textContentType(.password)
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(height: 112)

            Group {
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                } else {
                    Text("Make sure Tailscale is running. Port 8787 is added automatically.")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                Button("Back") {
                    error = nil
                    withAnimation(.easeInOut(duration: 0.2)) { step = .welcome }
                }
                .controlSize(.large)

                Button {
                    connect()
                } label: {
                    if connecting {
                        ProgressView().controlSize(.small).frame(width: 120)
                    } else {
                        Text("Connect").frame(width: 120)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || connecting)
            }

            Button("Need to set up a server?") {
                showSetupGuide = true
            }
            .buttonStyle(.link)
            .font(.callout)
        }
    }

    private func pasteConnectLink() {
        error = nil
        guard let raw = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: raw),
              let link = Session.connectLink(url) else {
            error = "Clipboard doesn’t contain an “atlas://connect” link. Run “atlas connect” in Terminal first."
            return
        }
        address = link.address
        token = link.token
        connect()
    }

    private func connect() {
        guard !address.isEmpty, !token.isEmpty else { return }
        connecting = true
        error = nil
        Task {
            defer { connecting = false }
            do {
                try await session.connect(to: address, token: token)
            } catch {
                self.error = OnboardingContent.friendlyError(for: error)
            }
        }
    }
}

private struct MacSetupGuideSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Set Up Atlas")
                        .font(.title2.bold())
                    Text("Get your home server running in minutes.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Let Your AI Agent Set It Up", systemImage: "sparkles")
                        .font(.headline)
                    Text("Copy one prompt and paste it into Claude Code, Codex, or Cursor. The Atlas docs serve llms.txt and clean Markdown so your agent can guide or automate the entire install.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(OnboardingContent.agentPrompt, forType: .string)
                            copied = true
                            Task {
                                try? await Task.sleep(for: .seconds(2))
                                copied = false
                            }
                        } label: {
                            Label(copied ? "Prompt Copied" : "Copy Agent Prompt",
                                  systemImage: copied ? "checkmark.circle.fill" : "doc.on.doc")
                        }
                        .buttonStyle(.borderedProminent)

                        Button {
                            NSWorkspace.shared.open(OnboardingContent.docsURL)
                        } label: {
                            Label("Open Full Docs", systemImage: "arrow.up.right.square")
                        }
                    }
                }
                .padding(6)
            }

            VStack(alignment: .leading, spacing: 14) {
                ForEach(OnboardingContent.setupSteps) { step in
                    HStack(alignment: .top, spacing: 12) {
                        Text("\(step.id)")
                            .font(.caption.bold().monospacedDigit())
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(Color.accentColor, in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.title)
                                .font(.headline)
                            Text(step.detail)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}
