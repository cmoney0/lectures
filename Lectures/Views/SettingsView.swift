import SwiftUI

/// Connect to LifeOS with the LifeOS passcode (typed once; only the widget key
/// it unlocks is kept, in the Keychain).
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(LifeOSClient.self) private var lifeos
    @State private var passcode = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if lifeos.isConnected {
                        Label("Connected to LifeOS", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.green)
                        Text("\(lifeos.courses.count) Canvas classes loaded. Finished lectures go to LifeOS, where your School Claude project reads them.")
                            .font(.m(12)).foregroundStyle(Theme.sub)
                        Button("Reload classes") { Task { await lifeos.refreshCourses() } }
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
                    Text("Same passcode as the LifeOS app. It is only used once to unlock a key; the passcode is not saved.")
                }

                Section("Transcription") {
                    LabeledContent("Engine", value: "On-device (Apple)")
                    Text("Free, private and offline. Audio never leaves your phone; only the text goes to LifeOS.")
                        .font(.m(12)).foregroundStyle(Theme.sub)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func connect() async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            try await lifeos.connect(passcode: passcode)
            passcode = ""
            await Uploader.sendPending(in: context, with: lifeos)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
