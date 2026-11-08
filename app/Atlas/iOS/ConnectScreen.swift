import SwiftUI

/// Erster Start: Wo steht der Server, und wie lautet das Zugangstoken.
struct ConnectScreen: View {
    @Environment(Session.self) private var session
    @State private var address = ""
    @State private var token = ""
    @State private var connecting = false
    @State private var error: String?
    @FocusState private var focus: Field?

    private enum Field { case address, token }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "photo.stack")
                            .font(.largeTitle)
                            .imageScale(.large)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text("Connect to atlas")
                            .font(.title2.bold())
                        Text("Your photos and files live on your own server. Enter its address and access token.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .listRowBackground(Color.clear)
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
                } footer: {
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    } else {
                        Text("“atlas connect” on the Mac shows a link that fills in both.")
                    }
                }
                Section {
                    Button {
                        connect()
                    } label: {
                        if connecting {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text("Connect").frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(address.isEmpty || token.isEmpty || connecting)
                }
            }
        }
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
                self.error = error.localizedDescription
            }
        }
    }
}
