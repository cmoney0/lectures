import SwiftData
import SwiftUI

/// Home: a big record button, then every lecture grouped by course.
struct LectureListView: View {
    @Environment(\.modelContext) private var context
    @Environment(LectureRecorder.self) private var recorder
    @Environment(LifeOSClient.self) private var lifeos
    @Query(sort: \Lecture.recordedAt, order: .reverse) private var lectures: [Lecture]
    @State private var showRecord = false
    @State private var showSettings = false
    @State private var pendingDelete: Lecture?

    private var groups: [(String, [Lecture])] {
        let byCourse = Dictionary(grouping: lectures) { $0.courseName.isEmpty ? "Other" : $0.courseName }
        return byCourse.sorted { ($0.value.first?.recordedAt ?? .distantPast) > ($1.value.first?.recordedAt ?? .distantPast) }
    }

    var body: some View {
        List {
            Section {
                recordButton
                if !lifeos.isConnected {
                    Button { showSettings = true } label: {
                        Label("Connect LifeOS to send lectures to Claude", systemImage: "link")
                            .font(.m(13, .semibold))
                    }
                }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            .listRowSeparator(.hidden)

            ForEach(groups, id: \.0) { course, items in
                Section {
                    ForEach(items) { lecture in
                        NavigationLink(value: lecture) { LectureRow(lecture: lecture) }
                            .listRowBackground(Theme.card)
                            .swipeActions {
                                Button(role: .destructive) { pendingDelete = lecture } label: { Label("Delete", systemImage: "trash") }
                            }
                    }
                } header: {
                    Text(course).font(.m(13, .bold)).foregroundStyle(Theme.sub).textCase(nil)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle("Lectures")
        .navigationDestination(for: Lecture.self) { LectureDetailView(lecture: $0) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
            }
        }
        .fullScreenCover(isPresented: $showRecord) { RecordView() }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .refreshable {
            await lifeos.refreshCourses()
            await Uploader.sendPending(in: context, with: lifeos)
        }
        .confirmationDialog("Delete this lecture?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), presenting: pendingDelete) { lecture in
            Button("Delete from phone and LifeOS", role: .destructive) { delete(lecture, everywhere: true) }
            Button("Delete from phone only", role: .destructive) { delete(lecture, everywhere: false) }
        }
    }

    private var recordButton: some View {
        Button { showRecord = true } label: {
            HStack(spacing: 12) {
                Image(systemName: recorder.isRecording ? "waveform" : "record.circle.fill")
                    .font(.system(size: 26, weight: .semibold))
                VStack(alignment: .leading, spacing: 2) {
                    Text(recorder.isRecording ? "Recording - tap to open" : "Record a lecture").font(.m(17, .bold))
                    Text(recorder.isRecording ? (recorder.current?.title ?? "") : "Transcribed live, on your phone").font(.m(12)).opacity(0.85)
                }
                Spacer()
            }
            .foregroundStyle(.white)
            .padding(16)
            .background(recorder.isRecording ? Theme.red : Theme.accent, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func delete(_ lecture: Lecture, everywhere: Bool) {
        let id = lecture.id, uploaded = lecture.uploadedAt != nil
        try? FileManager.default.removeItem(at: lecture.audioURL)
        context.delete(lecture)
        try? context.save()
        if everywhere && uploaded { Task { try? await lifeos.remove(id) } }
    }
}

struct LectureRow: View {
    let lecture: Lecture

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(lecture.title.isEmpty ? "Untitled lecture" : lecture.title)
                .font(.m(15, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
            HStack(spacing: 6) {
                Text(lecture.recordedAt.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()))
                Text("·")
                Text(Clock.string(lecture.durationSec))
                Spacer()
                statusIcon
            }
            .font(.m(12)).foregroundStyle(Theme.sub)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var statusIcon: some View {
        switch lecture.status {
        case .recording: Image(systemName: "record.circle").foregroundStyle(Theme.red)
        case .transcribing: ProgressView().controlSize(.mini)
        case .failed: Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.red)
        case .ready:
            if lecture.uploadedAt != nil {
                Image(systemName: "checkmark.icloud").foregroundStyle(Theme.green)
            } else if lecture.uploadError != nil {
                Image(systemName: "exclamationmark.icloud").foregroundStyle(Theme.red)
            } else {
                Image(systemName: "icloud.and.arrow.up").foregroundStyle(Theme.sub)
            }
        }
    }
}
