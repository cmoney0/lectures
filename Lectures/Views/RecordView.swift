import SwiftData
import SwiftUI

/// Full-screen recorder: pick the class, hit record, watch the transcript come in.
/// Closing the screen keeps recording (it keeps going with the phone locked too).
struct RecordView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(LectureRecorder.self) private var recorder
    @Environment(LifeOSClient.self) private var lifeos
    @AppStorage("lastCourseId") private var lastCourseId = ""
    @State private var course: Course?
    @State private var title = ""
    @State private var titleEdited = false
    @State private var confirmStop = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                if recorder.isRecording { recordingPanel } else { setupPanel }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Theme.bg)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(recorder.isRecording ? "Minimize" : "Cancel") { dismiss() }
                }
            }
            .navigationTitle(recorder.isRecording ? "Recording" : "New lecture")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            if course == nil { course = lifeos.courses.first { $0.id == lastCourseId } }
            if !titleEdited { title = defaultTitle }
        }
        .onChange(of: course) { _, _ in if !titleEdited { title = defaultTitle } }
    }

    private var defaultTitle: String {
        let day = Date().formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        return course.map { "\($0.short) - \(day)" } ?? "Lecture - \(day)"
    }

    // MARK: before recording

    private var setupPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Card {
                Text("Class").font(.m(12, .bold)).foregroundStyle(Theme.sub)
                if lifeos.courses.isEmpty {
                    Text(lifeos.isConnected ? "No active Canvas courses found." : "Connect LifeOS in Settings to pick from your Canvas classes.")
                        .font(.m(13)).foregroundStyle(Theme.sub)
                } else {
                    FlowChips(courses: lifeos.courses, selected: $course)
                }
            }
            Card {
                Text("Title").font(.m(12, .bold)).foregroundStyle(Theme.sub)
                TextField("Lecture title", text: $title)
                    .font(.m(16, .semibold))
                    .onChange(of: title) { _, new in if new != defaultTitle { titleEdited = true } }
            }
            if let error = recorder.errorMessage {
                Text(error).font(.m(13)).foregroundStyle(Theme.red)
            }
            Spacer(minLength: 20)
            Button {
                lastCourseId = course?.id ?? ""
                Task { await recorder.start(title: title, course: course, in: context) }
            } label: {
                HStack {
                    if recorder.isStarting { ProgressView().tint(.white) } else { Image(systemName: "record.circle.fill") }
                    Text(recorder.isStarting ? "Getting ready..." : "Start recording").font(.m(18, .bold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .foregroundStyle(.white)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(recorder.isStarting)
            Text("The first recording downloads Apple's speech model once. After that it works offline.")
                .font(.m(11)).foregroundStyle(Theme.sub)
        }
    }

    // MARK: while recording

    private var recordingPanel: some View {
        VStack(spacing: 14) {
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                VStack(spacing: 8) {
                    Text(Clock.string(recorder.elapsed))
                        .font(.m(52, .heavy)).monospacedDigit().foregroundStyle(Theme.text)
                    LevelBar(level: recorder.level)
                    Text(recorder.current?.title ?? "").font(.m(14, .semibold)).foregroundStyle(Theme.sub).lineLimit(1)
                }
            }
            if let error = recorder.errorMessage {
                Text(error).font(.m(12)).foregroundStyle(Theme.red).frame(maxWidth: .infinity, alignment: .leading)
            }
            LiveTranscriptView(lines: recorder.liveLines, volatile: recorder.volatileText)
            Button { confirmStop = true } label: {
                Label("Stop", systemImage: "stop.fill")
                    .font(.m(18, .bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .foregroundStyle(.white)
                    .background(Theme.red, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)
            .confirmationDialog("End this recording?", isPresented: $confirmStop) {
                Button("Stop and save", role: .destructive) {
                    Task {
                        await recorder.stop()
                        await Uploader.sendPending(in: context, with: lifeos)
                        dismiss()
                    }
                }
            }
        }
    }
}

struct FlowChips: View {
    let courses: [Course]
    @Binding var selected: Course?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(courses) { c in
                    Chip(label: c.short, selected: selected == c) { selected = selected == c ? nil : c }
                }
            }
        }
        if let selected { Text(selected.name).font(.m(12)).foregroundStyle(Theme.sub).lineLimit(1) }
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
            }
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .onChange(of: lines.count) { _, _ in withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
            .onChange(of: volatile) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
        }
    }
}
