import SwiftUI

struct SettingsView: View {
    @Binding var host: String
    @Binding var token: String
    var onDone: () -> Void

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
                    Text("atlas-agent")
                } footer: {
                    Text("Adresse des atlas-agent im Tailnet. Der Token ist nur nötig, wenn der Agent mit ATLAS_AGENT_TOKEN läuft — Strom-Aktionen brauchen ihn immer.")
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
                        onDone()
                        dismiss()
                    }
                }
            }
        }
    }
}
