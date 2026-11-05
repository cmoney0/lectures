import SwiftData
import SwiftUI

@main
struct LecturesApp: App {
    @State private var recorder = LectureRecorder()
    @State private var lifeos = LifeOSClient()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(recorder)
                .environment(lifeos)
                .tint(Theme.accent)
        }
        .modelContainer(for: Lecture.self)
    }
}

struct RootView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var phase
    @Environment(LectureRecorder.self) private var recorder
    @Environment(LifeOSClient.self) private var lifeos

    var body: some View {
        NavigationStack {
            LectureListView()
        }
        .task {
            Recovery.markInterrupted(in: context, except: recorder.current?.id)
            await lifeos.refreshCourses()
            await Uploader.sendPending(in: context, with: lifeos)
        }
        .onChange(of: phase) { _, now in
            guard now == .active else { return }
            Task { await Uploader.sendPending(in: context, with: lifeos) }
        }
    }
}

/// A lecture still marked "recording" when the app launches means the app was
/// killed mid-class. The audio up to that point is on disk; flag it so the
/// detail screen offers to transcribe it again.
enum Recovery {
    @MainActor
    static func markInterrupted(in context: ModelContext, except current: UUID?) {
        let recording = LectureStatus.recording.rawValue
        let transcribing = LectureStatus.transcribing.rawValue
        let stuck = (try? context.fetch(FetchDescriptor<Lecture>(predicate: #Predicate {
            $0.statusRaw == recording || $0.statusRaw == transcribing
        }))) ?? []
        for lecture in stuck where lecture.id != current {
            lecture.status = lecture.transcript.isEmpty ? .failed : .ready
            lecture.uploadedAt = nil
        }
        try? context.save()
    }
}

/// Sends every finished lecture LifeOS doesn't have yet.
enum Uploader {
    @MainActor
    static func sendPending(in context: ModelContext, with lifeos: LifeOSClient) async {
        guard lifeos.isConnected else { return }
        let ready = LectureStatus.ready.rawValue
        let pending = (try? context.fetch(FetchDescriptor<Lecture>(predicate: #Predicate {
            $0.statusRaw == ready && $0.uploadedAt == nil
        }))) ?? []
        for lecture in pending { await send(lecture, with: lifeos) }
        try? context.save()
    }

    @MainActor
    static func send(_ lecture: Lecture, with lifeos: LifeOSClient) async {
        do {
            try await lifeos.upload(lecture)
            lecture.uploadedAt = .now
            lecture.uploadError = nil
        } catch {
            lecture.uploadError = error.localizedDescription
        }
    }
}
