import AppIntents
import SwiftData
import SwiftUI

@main
struct LecturesApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(LectureRecorder.shared)
                .environment(LifeOSClient.shared)
                .tint(Theme.accent)
        }
        .modelContainer(Store.container)
    }
}

/// One store shared by the screens and the intents (Live Activity buttons, Siri).
enum Store {
    @MainActor static let container: ModelContainer = {
        do { return try ModelContainer(for: Lecture.self) } catch { fatalError("Lectures store: \(error)") }
    }()
}

/// "Record lecture" for the Action Button, Siri and Spotlight.
struct LecturesShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartLectureIntent(),
            phrases: ["Record a lecture in \(.applicationName)", "Start \(.applicationName)", "Record class in \(.applicationName)"],
            shortTitle: "Record lecture",
            systemImageName: "record.circle")
    }
}

struct RootView: View {
    @Environment(\.scenePhase) private var phase
    @Environment(LectureRecorder.self) private var recorder

    var body: some View {
        @Bindable var recorder = recorder
        NavigationStack {
            HomeView()
        }
        .fullScreenCover(isPresented: $recorder.showRecorder) { RecordView() }
        .sheet(item: $recorder.awaitingOptions) { lecture in ReviewOptionsSheet(lecture: lecture) }
        .task {
            await LectureRecorder.endOrphanedActivities()
            Pipeline.recoverInterrupted(except: recorder.current?.id)
            await Pipeline.sendPending()
            await Pipeline.pollLoop()
        }
        .onChange(of: phase) { _, now in
            guard now == .active else { return }
            Task { await Pipeline.sendPending(); await Pipeline.refreshReviews() }
        }
    }
}

/// Recorded -> transcribed -> sent to Claude -> review ready.
@MainActor
enum Pipeline {
    private static var context: ModelContext { Store.container.mainContext }

    /// A lecture still "recording" at launch means the app was killed mid-class.
    /// Its transcript (saved every ~15 s) and audio chunks are on disk; it shows
    /// as "stopped unexpectedly" with Continue / Finish.
    static func recoverInterrupted(except current: UUID?) {
        let recording = LectureStatus.recording.rawValue
        let finishing = LectureStatus.finishing.rawValue
        let stuck = (try? context.fetch(FetchDescriptor<Lecture>(predicate: #Predicate {
            $0.statusRaw == recording || $0.statusRaw == finishing
        }))) ?? []
        for lecture in stuck where lecture.id != current {
            lecture.status = lecture.status == .finishing ? .ready : .interrupted
        }
        try? context.save()
    }

    static func requestReview(for lecture: Lecture, options: ReviewOptions) {
        lecture.reviewOptionsJSON = options.json
        lecture.reviewPending = true
        lecture.reviewError = nil
        lecture.uploadedAt = nil
        try? context.save()
    }

    /// Finish an interrupted lecture without recording more.
    static func finish(_ lecture: Lecture) async {
        if let total = try? await AudioMerge.merge(folder: lecture.chunkFolder, into: lecture.audioURL), total > 0 {
            lecture.durationSec = total
        }
        lecture.status = .ready
        try? context.save()
        LectureRecorder.shared.awaitingOptions = lecture
    }

    /// Uploads everything LifeOS doesn't have yet (and pending review requests).
    static func sendPending() async {
        let lifeos = LifeOSClient.shared
        guard lifeos.isConnected else { return }
        let ready = LectureStatus.ready.rawValue
        let pending = (try? context.fetch(FetchDescriptor<Lecture>(predicate: #Predicate {
            $0.statusRaw == ready && ($0.uploadedAt == nil || $0.reviewPending)
        }))) ?? []
        for lecture in pending {
            do {
                try await lifeos.upload(lecture)
                lecture.uploadedAt = .now
                lecture.uploadError = nil
                if lecture.reviewPending {
                    lecture.reviewPending = false
                    lecture.reviewStatus = .requested
                }
            } catch {
                lecture.uploadError = error.localizedDescription
            }
        }
        try? context.save()
    }

    /// Pulls review status / finished reviews from LifeOS.
    static func refreshReviews() async {
        let requested = ReviewStatus.requested.rawValue
        let working = ReviewStatus.working.rawValue
        let waiting = (try? context.fetch(FetchDescriptor<Lecture>(predicate: #Predicate {
            $0.reviewStatusRaw == requested || $0.reviewStatusRaw == working
        }))) ?? []
        guard !waiting.isEmpty, let rows = try? await LifeOSClient.shared.reviews(for: waiting.map(\.id)) else { return }
        for row in rows {
            guard let lecture = waiting.first(where: { $0.id.uuidString.lowercased() == row.id.lowercased() }) else { continue }
            if let course = row.course, !course.isEmpty { lecture.courseName = course }
            if let cid = row.courseId, !cid.isEmpty { lecture.courseId = cid }
            if let status = row.reviewStatus.flatMap(ReviewStatus.init(rawValue:)) { lecture.reviewStatus = status }
            lecture.reviewError = row.reviewError
            if let review = row.review, let data = try? JSONEncoder().encode(review) {
                lecture.reviewJSON = String(data: data, encoding: .utf8)
                if lecture.courseName.isEmpty, let c = review.course, !c.isEmpty { lecture.courseName = c }
            }
        }
        try? context.save()
    }

    /// While the app is open: check every 15 s whenever something is waiting on Claude.
    static func pollLoop() async {
        while !Task.isCancelled {
            await refreshReviews()
            try? await Task.sleep(for: .seconds(15))
        }
    }
}
