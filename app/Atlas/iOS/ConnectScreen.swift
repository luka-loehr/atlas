import SwiftUI
import UIKit

/// First-launch onboarding on iPhone and iPad: welcomes new users, helps them
/// set up a server (or copy the AI agent setup prompt), and connects via an
/// `atlas://connect` link or manual entry.
struct ConnectScreen: View {
    @State private var showConnect = false
    @State private var showSetupGuide = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 32) {
                    VStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .fill(Color.accentColor.opacity(0.14))
                                .frame(width: 84, height: 84)
                                .glassEffect(.regular, in: .rect(cornerRadius: 24))
                            Image(systemName: "photo.stack.fill")
                                .font(.system(size: 36, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                        }
                        .accessibilityHidden(true)

                        VStack(spacing: 8) {
                            Text("Welcome to Atlas")
                                .font(.largeTitle.bold())
                                .multilineTextAlignment(.center)
                            Text("Your personal photo library, drive, and home server — completely private.")
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.top, 28)

                    VStack(alignment: .leading, spacing: 22) {
                        ForEach(OnboardingContent.features) { feature in
                            HStack(alignment: .top, spacing: 16) {
                                Image(systemName: feature.icon)
                                    .font(.title2.weight(.semibold))
                                    .foregroundStyle(feature.tint)
                                    .frame(width: 36, height: 36)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(feature.title)
                                        .font(.headline)
                                    Text(feature.detail)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: 460, alignment: .leading)
                    .padding(.horizontal, 4)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    Button {
                        showConnect = true
                    } label: {
                        Text("Connect to My Server")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button {
                        showSetupGuide = true
                    } label: {
                        Text("Don’t Have a Server Yet? Set Up Atlas")
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderless)
                }
                .frame(maxWidth: 460)
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity)
                .background(.bar)
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
                        Image(systemName: "link.badge.plus")
                            .foregroundStyle(Color.accentColor)
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
                .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || connecting)
            }

            Section {
                Button {
                    showSetupGuide = true
                } label: {
                    Label("Need to Set Up a Server?", systemImage: "book.pages")
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
                        Label("Let Your AI Agent Set It Up", systemImage: "sparkles")
                            .font(.headline)
                        Text("Copy one prompt and paste it into Claude Code, Codex, or Cursor. Our docs expose llms.txt and Markdown pages so your agent can configure your server, Tailscale, CLI, and app link.")
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
                                  systemImage: copied ? "checkmark.circle.fill" : "doc.on.doc")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                    }
                    .padding(.vertical, 6)
                }

                Section("How It Works") {
                    ForEach(OnboardingContent.setupSteps) { step in
                        HStack(alignment: .top, spacing: 14) {
                            Text("\(step.id)")
                                .font(.caption.bold().monospacedDigit())
                                .foregroundStyle(.white)
                                .frame(width: 24, height: 24)
                                .background(Color.accentColor, in: Circle())
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
                        Label("Open Full Documentation", systemImage: "arrow.up.right.square")
                    }
                    Link(destination: OnboardingContent.agentSetupURL) {
                        Label("View Agent Setup Guide", systemImage: "terminal")
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
