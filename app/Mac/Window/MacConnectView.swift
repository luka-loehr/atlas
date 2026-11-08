import SwiftUI

/// The first launch: where the server is and its token. `atlas connect`
/// prints a link that fills in both.
struct MacConnectView: View {
    @Environment(Session.self) private var session
    @State private var address = ""
    @State private var token = ""
    @State private var connecting = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 20) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 96, height: 96)
                    .accessibilityHidden(true)
                VStack(spacing: 6) {
                    Text("Connect to atlas").font(.title.bold())
                    Text("Your photos and files live on your own server. Enter its address and access token.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                Form {
                    TextField("Server Address", text: $address, prompt: Text("atlas.your-tailnet.ts.net"))
                        .textContentType(.URL)
                        .plainTextEntry()
                    SecureField("Access Token", text: $token)
                        .textContentType(.password)
                }
                .formStyle(.grouped)
                .scrollDisabled(true)
                .frame(height: 120)
                Group {
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    } else {
                        Text("“atlas connect” in Terminal prints a link that fills in both.")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
                Button {
                    connect()
                } label: {
                    if connecting { ProgressView().controlSize(.small).frame(width: 120) } else { Text("Connect").frame(width: 120) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(address.isEmpty || token.isEmpty || connecting)
            }
            .frame(maxWidth: 440)
            .padding(32)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Connect")
    }

    private func connect() {
        guard !address.isEmpty, !token.isEmpty else { return }
        connecting = true
        error = nil
        Task {
            defer { connecting = false }
            do { try await session.connect(to: address, token: token) } catch { self.error = error.localizedDescription }
        }
    }
}
