import SwiftUI
import UIKit

/// First-launch onboarding on iPhone and iPad: a quiet, Apple-native visual story
/// with procedural vector server scenes, one-tap AI agent setup docs, and fast
/// `atlas://connect` pairing.
struct ConnectScreen: View {
    @State private var page = 0
    @State private var userInteracted = false
    @State private var showConnect = false
    @State private var showSetupGuide = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Quiet top brand bar
                HStack(spacing: 8) {
                    AtlasDiamondMark(size: 20, tint: OnboardingContent.oceanBlue)
                    Text("Atlas")
                        .font(.headline.weight(.semibold))
                        .tracking(-0.3)
                }
                .padding(.top, 16)

                Spacer(minLength: 8)

                // Swipeable bespoke vector stage
                TabView(selection: $page) {
                    ForEach(OnboardingContent.slides) { slide in
                        VStack(spacing: 24) {
                            OnboardingStageView(scene: slide.id)
                                .frame(height: 230)
                                .frame(maxWidth: 420)

                            VStack(spacing: 8) {
                                Text(slide.title)
                                    .font(.title.weight(.semibold))
                                    .tracking(-0.5)
                                    .multilineTextAlignment(.center)
                                Text(slide.detail)
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: 340)
                            .padding(.horizontal, 24)
                        }
                        .tag(slide.id)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(maxHeight: 380)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 10).onChanged { _ in
                        userInteracted = true
                    }
                )

                // Minimal pill page indicator
                HStack(spacing: 7) {
                    ForEach(OnboardingContent.slides) { slide in
                        let active = page == slide.id
                        Button {
                            userInteracted = true
                            withAnimation(.snappy(duration: 0.3)) {
                                page = slide.id
                            }
                        } label: {
                            Capsule()
                                .fill(active ? OnboardingContent.oceanBlue : Color(.tertiaryLabel))
                                .frame(width: active ? 20 : 6, height: 6)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Slide \(slide.id + 1)")
                    }
                }
                .padding(.top, 10)

                Spacer(minLength: 16)

                // Bottom native action stack
                VStack(spacing: 10) {
                    Button {
                        showConnect = true
                    } label: {
                        Text("Connect to Server")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(OnboardingContent.oceanBlue)
                    .controlSize(.large)

                    Button {
                        showSetupGuide = true
                    } label: {
                        Text("Don’t have a server yet? Set up Atlas")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: 420)
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemBackground).ignoresSafeArea())
            .task {
                guard !reduceMotion else { return }
                while !Task.isCancelled && !userInteracted {
                    try? await Task.sleep(for: .seconds(5.5))
                    guard !Task.isCancelled && !userInteracted && !showConnect && !showSetupGuide else { continue }
                    withAnimation(.easeInOut(duration: 0.45)) {
                        page = (page + 1) % OnboardingContent.slides.count
                    }
                }
            }
            .navigationDestination(isPresented: $showConnect) {
                ConnectFormView(showSetupGuide: $showSetupGuide)
            }
            .sheet(isPresented: $showSetupGuide) {
                SetupGuideSheet()
            }
        }
    }
}

private struct ConnectFormView: View {
    @Environment(Session.self) private var session
    @Binding var showSetupGuide: Bool
    @State private var address = ""
    @State private var token = ""
    @State private var connecting = false
    @State private var error: String?
    @FocusState private var focus: Field?

    private enum Field { case address, token }

    var body: some View {
        Form {
            Section {
                ServerLinkGraphic(connecting: connecting, hasError: error != nil)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 0, trailing: 0))
            }

            Section {
                Button {
                    pasteConnectLink()
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Paste Connect Link")
                                .font(.body.weight(.medium))
                            Text("From “atlas connect” on your Mac")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "link")
                            .foregroundStyle(OnboardingContent.oceanBlue)
                    }
                }
                .disabled(connecting)
            } header: {
                Text("Fastest Way")
            }

            Section {
                TextField("Server Address", text: $address, prompt: Text("atlas.your-tailnet.ts.net"))
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .address)
                    .submitLabel(.next)
                    .onSubmit { focus = .token }
                SecureField("Access Token", text: $token)
                    .textContentType(.password)
                    .focused($focus, equals: .token)
                    .submitLabel(.go)
                    .onSubmit { connect() }
            } header: {
                Text("Or Enter Manually")
            } footer: {
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                } else {
                    Text("Make sure Tailscale is turned on. Port 8787 is added automatically.")
                }
            }

            Section {
                Button {
                    connect()
                } label: {
                    if connecting {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text("Connect")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                }
                .tint(OnboardingContent.oceanBlue)
                .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || connecting)
            }

            Section {
                Button {
                    showSetupGuide = true
                } label: {
                    Label("Need to set up a server?", systemImage: "server.rack")
                        .foregroundStyle(.primary)
                }
            }
        }
        .navigationTitle("Connect")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func pasteConnectLink() {
        error = nil
        guard let raw = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: raw),
              let link = Session.connectLink(url) else {
            error = "Clipboard doesn’t contain an “atlas://connect” link. Run “atlas connect” on your Mac first."
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

private struct SetupGuideSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Let your agent set it up", systemImage: "terminal")
                            .font(.headline)
                        Text("Paste one prompt into Claude Code, Codex, or Cursor. The docs serve llms.txt and Markdown so your agent can configure your server, Tailscale, CLI, and app link.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Button {
                            UIPasteboard.general.string = OnboardingContent.agentPrompt
                            copied = true
                            Task {
                                try? await Task.sleep(for: .seconds(2))
                                copied = false
                            }
                        } label: {
                            Label(copied ? "Prompt Copied" : "Copy Agent Prompt",
                                  systemImage: copied ? "checkmark" : "doc.on.doc")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(OnboardingContent.oceanBlue)
                        .controlSize(.regular)
                    }
                    .padding(.vertical, 6)
                }

                Section("How It Works") {
                    ForEach(OnboardingContent.setupSteps) { step in
                        HStack(alignment: .top, spacing: 14) {
                            Text("\(step.id)")
                                .font(.caption.weight(.semibold).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 24, height: 24)
                                .background(Color(.tertiarySystemFill), in: Circle())
                            VStack(alignment: .leading, spacing: 3) {
                                Text(step.title)
                                    .font(.subheadline.weight(.semibold))
                                Text(step.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

                Section {
                    Link(destination: OnboardingContent.docsURL) {
                        Label("Open Documentation", systemImage: "arrow.up.right")
                    }
                    Link(destination: OnboardingContent.agentSetupURL) {
                        Label("Agent Setup Guide", systemImage: "doc.text")
                    }
                }
            }
            .navigationTitle("Set Up Atlas")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
