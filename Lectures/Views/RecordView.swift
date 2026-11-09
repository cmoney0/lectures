import SwiftUI
import UIKit

/// Full-screen recorder. Opens already recording - no setup questions.
/// Closing it keeps recording (and so does locking the phone).
struct RecordView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(LectureRecorder.self) private var recorder
    @State private var confirmStop = false
    @State private var copied = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                    VStack(spacing: 8) {
                        Text(Clock.string(recorder.elapsed))
                            .font(.m(56, .heavy)).monospacedDigit().foregroundStyle(recorder.isPaused ? Theme.sub : Theme.text)
                        LevelBar(level: recorder.isPaused ? 0 : recorder.level)
                        Text(statusLine).font(.m(13, .semibold)).foregroundStyle(Theme.sub)
                    }
                }
                if let error = recorder.errorMessage {
                    Text(error).font(.m(12)).foregroundStyle(Theme.red).frame(maxWidth: .infinity, alignment: .leading)
                }
                LiveTranscriptView(lines: recorder.liveLines, volatile: recorder.volatileText)
                    .overlay(alignment: .topTrailing) {
                        Button {
                            UIPasteboard.general.string = recorder.liveLines.map(\.text).joined(separator: " ")
                            copied = true
                            Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                        } label: {
                            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                                .font(.m(12, .bold)).padding(.horizontal, 10).padding(.vertical, 6)
                                .background(Theme.bg, in: Capsule())
                        }
                        .buttonStyle(.plain).foregroundStyle(Theme.accent).padding(10)
                        .disabled(recorder.liveLines.isEmpty)
                    }
                HStack(spacing: 12) {
                    Button { recorder.togglePause() } label: {
                        Label(recorder.isPaused ? "Resume" : "Pause", systemImage: recorder.isPaused ? "play.fill" : "pause.fill")
                            .font(.m(17, .bold)).frame(maxWidth: .infinity).padding(.vertical, 16)
                            .foregroundStyle(Theme.text).background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                    Button { confirmStop = true } label: {
                        Label("Stop", systemImage: "stop.fill")
                            .font(.m(17, .bold)).frame(maxWidth: .infinity).padding(.vertical, 16)
                            .foregroundStyle(.white).background(Theme.red, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                }
                .buttonStyle(.plain)
                .disabled(!recorder.isRecording)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Theme.bg)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(recorder.isRecording ? "Minimize" : "Close") { dismiss() }
                }
            }
            .navigationTitle(recorder.isStarting ? "Starting..." : "Recording")
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("End this lecture?", isPresented: $confirmStop) {
                Button("Stop", role: .destructive) {
                    // close first so the review-options sheet can open on Home
                    dismiss()
                    Task { await recorder.stop(askForOptions: true) }
                }
            }
        }
    }

    private var statusLine: String {
        if recorder.isStarting { return "Getting the microphone and speech model ready..." }
        if recorder.isPaused { return "Paused" }
        return recorder.isRecording ? "Recording - keeps going with the phone locked" : ""
    }
}

struct LevelBar: View {
    var level: Float

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.line)
                Capsule().fill(Theme.accent).frame(width: max(6, geo.size.width * CGFloat(level)))
            }
        }
        .frame(height: 6)
        .animation(.linear(duration: 0.2), value: level)
    }
}

struct LiveTranscriptView: View {
    let lines: [TranscriptPiece]
    let volatile: String

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if lines.isEmpty && volatile.isEmpty {
                        Text("Listening... the transcript shows up here.").font(.m(14)).foregroundStyle(Theme.sub)
                    }
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, piece in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(Clock.string(piece.start)).font(.m(11, .semibold)).foregroundStyle(Theme.sub).monospacedDigit()
                            Text(piece.text).font(.m(15)).foregroundStyle(Theme.text)
                        }
                    }
                    if !volatile.isEmpty {
                        Text(volatile).font(.m(15)).foregroundStyle(Theme.sub)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .padding(.top, 30)
            }
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .onChange(of: lines.count) { _, _ in withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
            .onChange(of: volatile) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
        }
    }
}

/// After Stop: how Claude should review it. Sends itself with the last-used
/// choices after 10 seconds if left alone.
struct ReviewOptionsSheet: View {
    let lecture: Lecture
    @Environment(\.dismiss) private var dismiss
    @State private var options = ReviewOptions.saved
    @State private var countdown = 10
    @State private var touched = false
    /// Set by any choice (send / save / delete) - the countdown must never fire after.
    @State private var decided = false
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("\(Clock.string(lecture.durationSec)) · \(lecture.wordCount) words").font(.m(13)).foregroundStyle(Theme.sub)

                    Text("Length").font(.m(12, .bold)).foregroundStyle(Theme.sub)
                    Picker("Length", selection: $options.length) {
                        ForEach(ReviewOptions.lengths, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .pickerStyle(.segmented)

                    Text("Review type - pick any").font(.m(12, .bold)).foregroundStyle(Theme.sub)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        ForEach(ReviewOptions.types, id: \.0) { key, label, icon in
                            let on = options.types.contains(key)
                            Button { options.toggle(key) } label: {
                                VStack(spacing: 6) {
                                    Image(systemName: on ? "checkmark.circle.fill" : icon).font(.system(size: 20))
                                    Text(label).font(.m(13, .bold))
                                }
                                .frame(maxWidth: .infinity).padding(.vertical, 14)
                                .foregroundStyle(on ? .white : Theme.text)
                                .background(on ? Theme.accent : Theme.card, in: RoundedRectangle(cornerRadius: 14))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Text("Focus (optional)").font(.m(12, .bold)).foregroundStyle(Theme.sub)
                    TextField("e.g. focus on the derivations", text: $options.focus, axis: .vertical)
                        .font(.m(15)).padding(12).background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
                }
                .padding(16)
            }
            .background(Theme.bg)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    Button { send() } label: {
                        Text(touched ? "Send to Claude" : "Send to Claude (\(countdown))")
                            .font(.m(17, .bold)).frame(maxWidth: .infinity).padding(.vertical, 16)
                            .foregroundStyle(.white).background(Theme.accent, in: RoundedRectangle(cornerRadius: 16))
                    }
                    HStack(spacing: 24) {
                        Button("Save only - no review") { justSave() }.font(.m(14, .semibold)).foregroundStyle(Theme.sub)
                        Button("Delete recording") { touched = true; confirmDelete = true }
                            .font(.m(14, .semibold)).foregroundStyle(Theme.red)
                    }
                }
                .buttonStyle(.plain)
                .padding(16).background(Theme.bg)
            }
            .navigationTitle("Review this lecture")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: options) { _, _ in touched = true }
            .task {
                // Auto-send after 10 s untouched. A cancelled sleep (the sheet
                // closing after Save / Delete) must stop here - it used to fall
                // through and send anyway.
                while !touched && !decided && countdown > 0 {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    if !touched && !decided { countdown -= 1 }
                }
                if !touched && !decided && !Task.isCancelled { send() }
            }
            .confirmationDialog("Delete this recording? Nothing is sent to Claude.", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete recording", role: .destructive) { deleteRecording() }
            }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled()
    }

    private func send() {
        guard !decided else { return }
        decided = true
        ReviewOptions.saved = options
        Pipeline.requestReview(for: lecture, options: options)
        Task { await Pipeline.sendPending() }
        LectureRecorder.shared.awaitingOptions = nil
        dismiss()
    }

    private func justSave() {
        guard !decided else { return }
        decided = true
        Task { await Pipeline.sendPending() }
        LectureRecorder.shared.awaitingOptions = nil
        dismiss()
    }

    private func deleteRecording() {
        guard !decided else { return }
        decided = true
        LectureRecorder.shared.awaitingOptions = nil
        dismiss()
        // after the sheet closes, so it never draws a deleted lecture
        let doomed = lecture
        Task { try? await Task.sleep(for: .milliseconds(500)); Pipeline.delete(doomed) }
    }
}
