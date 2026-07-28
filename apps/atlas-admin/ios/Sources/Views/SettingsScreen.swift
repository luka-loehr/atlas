import SwiftUI

/// Host + token sheet. Opens itself on first launch while the host is empty.
struct SettingsScreen: View {
    @Binding var host: String
    @Binding var token: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Host") {
                        TextField("atlas.your-tailnet.ts.net:8787", text: $host)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Token") {
                        SecureField("optional", text: $token)
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("atlas-api")
                } footer: {
                    Text("Adresse des atlas-api im Tailnet. Der Token ist nur nötig, wenn der Server mit ATLAS_API_TOKEN läuft — Strom-Aktionen brauchen ihn immer.")
                }

                Section {
                    LabeledContent("Metrics-URL", value: "http://\(host)/api/metrics")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Einstellungen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") {
                        dismiss()
                    }
                }
            }
        }
    }
}
