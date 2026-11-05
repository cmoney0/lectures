import SwiftUI

/// Connect to LifeOS (passcode typed once; only the key it unlocks is kept)
/// and the default review options.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(LifeOSClient.self) private var lifeos
    @State private var passcode = ""
    @State private var busy = false
    @State private var error: String?
    @State private var options = ReviewOptions.saved

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if lifeos.isConnected {
                        Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.green)
                        Button("Disconnect", role: .destructive) { lifeos.disconnect() }
                    } else {
                        SecureField("LifeOS passcode", text: $passcode)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                        Button {
                            Task { await connect() }
                        } label: {
                            if busy { ProgressView() } else { Text("Connect") }
                        }
                        .disabled(busy || passcode.count < 4)
                        if let error { Text(error).font(.m(12)).foregroundStyle(Theme.red) }
                    }
                } header: {
                    Text("LifeOS")
                } footer: {
                    Text("Lectures go through LifeOS to your Claude reviewer, and reviews come back the same way. Same passcode as the LifeOS app; it is not saved.")
                }

                Section {
                    Picker("Length", selection: $options.length) {
                        ForEach(ReviewOptions.lengths, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    Picker("Type", selection: $options.type) {
                        ForEach(ReviewOptions.types, id: \.0) { Text($0.1).tag($0.0) }
                    }
                } header: {
                    Text("Default review")
                } footer: {
                    Text("Used when you stop from the Lock Screen, and preselected after Stop in the app.")
                }

                Section("Recording") {
                    LabeledContent("Transcription", value: "On-device (Apple)")
                    Text("Free and offline; audio never leaves your phone, only the text. Start from the Lock Screen / Control Center control, the Action Button (Shortcuts > Record lecture) or Siri: \"Record a lecture in Lectures\".")
                        .font(.m(12)).foregroundStyle(Theme.sub)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onChange(of: options) { _, new in ReviewOptions.saved = new }
        }
    }

    private func connect() async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            try await lifeos.connect(passcode: passcode)
            passcode = ""
            await Pipeline.sendPending()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
