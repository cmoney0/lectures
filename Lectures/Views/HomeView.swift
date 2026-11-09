import SwiftData
import SwiftUI

/// Home: the one Record button, what's in progress (with each step), then
/// finished reviews sorted by class.
struct HomeView: View {
    @Environment(\.modelContext) private var context
    @Environment(LectureRecorder.self) private var recorder
    @Environment(LifeOSClient.self) private var lifeos
    @Query(sort: \Lecture.recordedAt, order: .reverse) private var lectures: [Lecture]
    @State private var showSettings = false
    @State private var pendingDelete: Lecture?
    /// Class sections start collapsed; the open ones are remembered.
    @AppStorage("expandedClasses") private var expandedRaw = ""
    private var expanded: Set<String> { Set(expandedRaw.split(separator: "\n").map(String.init)) }

    private func toggle(_ name: String) {
        var set = expanded
        if set.contains(name) { set.remove(name) } else { set.insert(name) }
        withAnimation(.snappy) { expandedRaw = set.sorted().joined(separator: "\n") }
    }

    private var inProgress: [Lecture] { lectures.filter { $0.stage != .done && $0.stage != .saved && $0.stage != .recording } }
    private var finished: [Lecture] { lectures.filter { $0.stage == .done || $0.stage == .saved } }

    private var classes: [(String, [Lecture])] {
        let grouped = Dictionary(grouping: finished) { $0.sectionName }
        return grouped.sorted { ($0.value.first?.recordedAt ?? .distantPast) > ($1.value.first?.recordedAt ?? .distantPast) }
    }

    var body: some View {
        // A List (not a ScrollView) so lectures get native swipe-to-delete.
        List {
            Section {
                recordButton
                if !lifeos.isConnected {
                    Button { showSettings = true } label: {
                        Label("Connect LifeOS so lectures go to Claude", systemImage: "link").font(.m(13, .semibold))
                    }
                }
                if lectures.isEmpty {
                    Text("Tap Record when class starts. Stop when it ends - Claude sends back a review, filed under the class.")
                        .font(.m(13)).foregroundStyle(Theme.sub)
                }
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))

            if !inProgress.isEmpty {
                Section {
                    ForEach(inProgress) { lecture in
                        ZStack {
                            NavigationLink(value: lecture) { EmptyView() }.opacity(0)
                            PipelineCard(lecture: lecture)
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 5, leading: 0, bottom: 5, trailing: 0))
                        .swipeActions(edge: .trailing) { swipeDelete(lecture) }
                        .contextMenu { if lecture.stage != .recording { deleteButton(lecture) } }
                    }
                } header: {
                    SectionTitle("In progress")
                }
            }

            ForEach(classes, id: \.0) { course, items in
                Section {
                    if expanded.contains(course) {
                    ForEach(items) { lecture in
                        ZStack {
                            NavigationLink(value: lecture) { EmptyView() }.opacity(0)
                            ReviewRow(lecture: lecture)
                        }
                        .listRowBackground(Theme.card)
                        .listRowSeparatorTint(Theme.line)
                        .listRowInsets(EdgeInsets())
                        .swipeActions(edge: .trailing) { swipeDelete(lecture) }
                        .contextMenu { deleteButton(lecture) }
                    }
                    }
                } header: {
                    ClassHeader(name: course, count: items.count, open: expanded.contains(course)) { toggle(course) }
                }
            }
        }
        .listStyle(.insetGrouped)
        // every block (Record, cards, class groups) shares one 16 pt gutter
        .contentMargins(.horizontal, 16, for: .scrollContent)
        .listSectionSpacing(14)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 10)
        .background(Theme.bg)
        .navigationTitle("Lectures")
        .navigationDestination(for: Lecture.self) { LectureDetailView(lecture: $0) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .refreshable {
            await Pipeline.sendPending()
            await Pipeline.syncFromLifeOS()
        }
        .confirmationDialog("Delete this lecture? It is removed from your phone and LifeOS.", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), presenting: pendingDelete) { lecture in
            Button("Delete lecture", role: .destructive) { delete(lecture) }
            if lecture.hasAudio { Button("Delete audio only (keep notes)") { Pipeline.deleteAudio(lecture) } }
        }
    }

    private var recordButton: some View {
        Button {
            if recorder.isRecording { recorder.showRecorder = true } else { Task { await recorder.start() } }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: recorder.isRecording ? "waveform" : "record.circle.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .symbolEffect(.pulse, isActive: recorder.isRecording && !recorder.isPaused)
                VStack(alignment: .leading, spacing: 2) {
                    if recorder.isRecording {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            Text("\(recorder.isPaused ? "Paused" : "Recording") \(Clock.string(recorder.elapsed))").font(.m(18, .bold)).monospacedDigit()
                        }
                        Text("Tap to open").font(.m(12)).opacity(0.85)
                    } else {
                        Text("Record").font(.m(20, .heavy))
                        Text("Stop when class ends - Claude does the rest").font(.m(12)).opacity(0.85)
                    }
                }
                Spacer()
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 18).padding(.vertical, 20)
            .background(recorder.isRecording ? Theme.red : Theme.accent, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// Swipe left -> Delete -> confirm (whole lecture, or just the audio).
    @ViewBuilder
    private func swipeDelete(_ lecture: Lecture) -> some View {
        if lecture.stage != .recording {
            Button { pendingDelete = lecture } label: { Label("Delete", systemImage: "trash") }
                .tint(Theme.red)
        }
    }

    private func deleteButton(_ lecture: Lecture) -> some View {
        Button(role: .destructive) { pendingDelete = lecture } label: { Label("Delete", systemImage: "trash") }
    }

    private func delete(_ lecture: Lecture) { Pipeline.delete(lecture) }
}

struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.m(13, .bold)).foregroundStyle(Theme.sub).textCase(nil)
            .padding(.leading, 4).padding(.bottom, 2)
            .listRowInsets(EdgeInsets())
    }
}

/// A lecture on its way through the pipeline, with the four steps.
struct PipelineCard: View {
    let lecture: Lecture

    var body: some View {
        Card {
            HStack {
                Text(lecture.displayTitle).font(.m(15, .bold)).foregroundStyle(Theme.text).lineLimit(1)
                Spacer()
                Text(Clock.string(lecture.durationSec)).font(.m(12, .semibold)).foregroundStyle(Theme.sub).monospacedDigit()
            }
            PipelineSteps(stage: lecture.stage)
            HStack(spacing: 6) {
                if lecture.stage.isWorking { ProgressView().controlSize(.mini) }
                Text(detail).font(.m(12)).foregroundStyle(isError ? Theme.red : Theme.sub).lineLimit(2)
            }
            if lecture.stage == .interrupted { InterruptedActions(lecture: lecture) }
        }
    }

    private var isError: Bool { [.failed, .reviewFailed, .interrupted].contains(lecture.stage) || lecture.uploadError != nil }

    private var detail: String {
        if lecture.stage == .sending, let err = lecture.uploadError { return "Not sent yet: \(err)" }
        if lecture.stage == .reviewFailed { return "Review failed: \(lecture.reviewError ?? "unknown")" }
        if lecture.stage == .interrupted { return "Saved up to \(Clock.string(lecture.durationSec)). Keep recording or finish it." }
        return lecture.stage.label
    }
}

struct InterruptedActions: View {
    let lecture: Lecture
    @Environment(LectureRecorder.self) private var recorder

    var body: some View {
        HStack(spacing: 10) {
            Button { Task { await recorder.start(resuming: lecture) } } label: {
                Label("Continue recording", systemImage: "record.circle").font(.m(13, .bold))
                    .frame(maxWidth: .infinity).padding(.vertical, 9)
                    .foregroundStyle(.white).background(Theme.accent, in: RoundedRectangle(cornerRadius: 10))
            }
            Button { Task { await Pipeline.finish(lecture) } } label: {
                Text("Finish & send").font(.m(13, .bold))
                    .frame(maxWidth: .infinity).padding(.vertical, 9)
                    .foregroundStyle(Theme.text).background(Theme.bg, in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .buttonStyle(.plain)
        .disabled(recorder.isRecording)
    }
}

/// Recorded -> Transcribed -> Sent to Claude -> Review ready
struct PipelineSteps: View {
    let stage: Stage
    private let names = ["Recorded", "Transcribed", "Sent", "Review"]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<4, id: \.self) { i in
                VStack(alignment: .leading, spacing: 4) {
                    Capsule().fill(color(i)).frame(height: 5)
                    Text(names[i]).font(.m(10, .semibold)).foregroundStyle(i < stage.step ? Theme.text : Theme.sub)
                }
            }
        }
    }

    private func color(_ i: Int) -> Color {
        if i < stage.step { return Theme.accent }
        if i == stage.step {
            if [.failed, .reviewFailed, .interrupted].contains(stage) { return Theme.red }
            return Theme.accent.opacity(0.35)
        }
        return Theme.line
    }
}

/// A finished lecture under its class.
struct ReviewRow: View {
    let lecture: Lecture

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: lecture.stage == .done ? "doc.text.fill" : "waveform")
                .font(.system(size: 18)).foregroundStyle(Theme.accent).frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(lecture.displayTitle).font(.m(15, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                Text("\(lecture.recordedAt.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())) · \(Clock.string(lecture.durationSec))\(lecture.stage == .saved ? " · no review" : "")")
                    .font(.m(12)).foregroundStyle(Theme.sub)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.sub)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

/// Tappable class header: chevron, short class name, lecture count.
struct ClassHeader: View {
    let name: String
    let count: Int
    let open: Bool
    var toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .rotationEffect(.degrees(open ? 90 : 0))
                Text(name).font(.m(16, .heavy)).foregroundStyle(Theme.text)
                Spacer()
                Text("\(count)").font(.m(13, .bold)).foregroundStyle(Theme.sub)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Theme.card, in: Capsule())
            }
            .foregroundStyle(Theme.accent)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .textCase(nil)
        .listRowInsets(EdgeInsets())
    }
}
