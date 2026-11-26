import AppKit
import SwiftUI

/// First-launch onboarding on macOS: a quiet, Apple-native visual story with
/// procedural vector server scenes, one-click AI agent setup docs, and fast
/// `atlas://connect` pairing.
struct MacConnectView: View {
    @Environment(Session.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step: Step = .welcome
    @State private var page = 0
    @State private var userInteracted = false
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
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle(step == .welcome ? "Atlas" : "Connect to Atlas")
        .sheet(isPresented: $showSetupGuide) {
            MacSetupGuideSheet()
        }
        .task {
            guard !reduceMotion else { return }
            while !Task.isCancelled && !userInteracted {
                try? await Task.sleep(for: .seconds(5.5))
                guard !Task.isCancelled && !userInteracted && step == .welcome && !showSetupGuide else { continue }
                withAnimation(.easeInOut(duration: 0.4)) {
                    page = (page + 1) % OnboardingContent.slides.count
                }
            }
        }
    }

    private var welcomeView: some View {
        let slide = OnboardingContent.slides[page]
        return VStack(spacing: 24) {
            HStack(spacing: 8) {
                AtlasDiamondMark(size: 18, tint: OnboardingContent.oceanBlue)
                Text("Atlas")
                    .font(.headline.weight(.semibold))
                    .tracking(-0.3)
            }

            // Bespoke animated vector stage with subtle left/right navigation
            ZStack {
                OnboardingStageView(scene: slide.id)
                    .id(slide.id)
                    .transition(.opacity)
                    .frame(width: 360, height: 220)

                HStack {
                    Button {
                        userInteracted = true
                        withAnimation(.snappy(duration: 0.28)) {
                            page = (page - 1 + OnboardingContent.slides.count) % OnboardingContent.slides.count
                        }
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.subheadline.weight(.semibold))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .glassEffect(.regular.interactive(), in: .circle)

                    Spacer()

                    Button {
                        userInteracted = true
                        withAnimation(.snappy(duration: 0.28)) {
                            page = (page + 1) % OnboardingContent.slides.count
                        }
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.subheadline.weight(.semibold))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .glassEffect(.regular.interactive(), in: .circle)
                }
                .frame(maxWidth: 420)
            }

            VStack(spacing: 8) {
                Text(slide.title)
                    .font(.title.weight(.semibold))
                    .tracking(-0.5)
                    .multilineTextAlignment(.center)
                Text(slide.detail)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            .id("copy-\(slide.id)")
            .transition(.opacity)

            // Minimal pill page dots
            HStack(spacing: 7) {
                ForEach(OnboardingContent.slides) { item in
                    let active = page == item.id
                    Button {
                        userInteracted = true
                        withAnimation(.snappy(duration: 0.28)) {
                            page = item.id
                        }
                    } label: {
                        Capsule()
                            .fill(active ? OnboardingContent.oceanBlue : Color.secondary.opacity(0.35))
                            .frame(width: active ? 20 : 6, height: 6)
                    }
                    .buttonStyle(.plain)
                }
            }

            VStack(spacing: 10) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { step = .connect }
                } label: {
                    Text("Connect to Server")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(OnboardingContent.oceanBlue)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)

                Button {
                    showSetupGuide = true
                } label: {
                    Text("Don’t have a server yet? Set up Atlas…")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .frame(maxWidth: 320)
            .padding(.top, 4)
        }
    }

    private var connectView: some View {
        VStack(spacing: 20) {
            ServerLinkGraphic(connecting: connecting, hasError: error != nil)
                .frame(maxWidth: 260)

            VStack(spacing: 6) {
                Text("Connect to Your Server")
                    .font(.title2.weight(.semibold))
                    .tracking(-0.3)
                Text("Paste the link from “atlas connect”, or enter your server address and token.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                pasteConnectLink()
            } label: {
                Label("Paste “atlas connect” Link", systemImage: "link")
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
                .tint(OnboardingContent.oceanBlue)
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
                        .font(.title2.weight(.semibold))
                    Text("Get your home server running in minutes.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Let your agent set it up", systemImage: "terminal")
                        .font(.headline)
                    Text("Paste one prompt into Claude Code, Codex, or Cursor. The docs serve llms.txt and clean Markdown so your agent can guide or automate the entire install.")
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
                                  systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(OnboardingContent.oceanBlue)

                        Button {
                            NSWorkspace.shared.open(OnboardingContent.docsURL)
                        } label: {
                            Label("Open Docs", systemImage: "arrow.up.right")
                        }
                    }
                }
                .padding(6)
            }

            VStack(alignment: .leading, spacing: 14) {
                ForEach(OnboardingContent.setupSteps) { step in
                    HStack(alignment: .top, spacing: 12) {
                        Text("\(step.id)")
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                            .background(Color.secondary.opacity(0.16), in: Circle())
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
