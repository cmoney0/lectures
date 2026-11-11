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
    @State private var engine = TranscriptionEngine.saved

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
                    ForEach(ReviewOptions.types, id: \.0) { key, label, icon in
                        Button { options.toggle(key) } label: {
                            HStack {
                                Label(label, systemImage: icon).foregroundStyle(Theme.text)
                                Spacer()
                                if options.types.contains(key) { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                            }
                        }
                    }
                } header: {
                    Text("Default review")
                } footer: {
                    Text("Used when you stop from the Lock Screen, and preselected after Stop in the app.")
                }

                Section {
                    Picker("Transcription", selection: Binding(get: { TranscriptionEngine.saved }, set: { TranscriptionEngine.saved = $0; engine = $0 })) {
                        ForEach(TranscriptionEngine.allCases) { Text($0.label).tag($0) }
                    }
                } header: {
                    Text("Transcription")
                } footer: {
                    Text(engine == .onDevice
                         ? "Free and offline, but the review misses more (homework and dates the iPhone mishears)."
                         : "Every lecture: the live transcript stays on-device, then after Stop the audio goes to AssemblyAI (about 20 s, a few cents) and Claude reviews that transcript. Offline, the review falls back to on-device.")
                }

                Section("Recording") {
                    Text("Start from the Lock Screen / Control Center control, the Action Button (Shortcuts > Record lecture) or Siri: \"Record a lecture in Lectures\".")
                        .font(.m(12)).foregroundStyle(Theme.sub)
                }

                if let diag = RecordingDiagnostics.last {
                    Section {
                        LabeledContent("Heartbeats", value: "\(diag.log.beats)")
                        LabeledContent("Longest gap", value: Clock.string(diag.log.maxGap))
                        LabeledContent("Live Activity", value: diag.activity)
                    } header: {
                        Text("Last recording")
                    } footer: {
                        Text(diag.log.wasLate()
                             ? "iOS held the app back at least once while the phone was locked (normal ~0:20). The recording kept going; the Lock Screen now only says \"no signal\" after 15 minutes of silence."
                             : "The app checked in every ~20 s the whole time.")
                    }
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
