import SwiftUI

struct SettingsView: View {
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
                    Text("atlas-agent")
                } footer: {
                    Text("Adresse des atlas-agent im Tailnet — Lichter, Shows und Nebel laufen über ihn. Der Token ist nur nötig, wenn der Agent mit ATLAS_AGENT_TOKEN läuft.")
                }

                Section {
                    LabeledContent("Shows-API", value: "http://\(host)/api/shows")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    LabeledContent("Lichter-API", value: "http://\(host)/api/lights")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Einstellungen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
    }
}
