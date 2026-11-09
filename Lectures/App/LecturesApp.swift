import AppIntents
import SwiftData
import SwiftUI
import UserNotifications

@main
struct LecturesApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

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

/// Tapping the "stopped recording" notification resumes the lecture.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.notification.request.identifier == CrashWatchdog.id else { return }
        await Pipeline.resumeLatestInterrupted()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
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
            // a crash's watchdog that hasn't fired yet: the Continue card covers it now
            if !recorder.isRecording { CrashWatchdog.cancel() }
            Pipeline.recoverInterrupted(except: recorder.current?.id)
            await Pipeline.sendPending()
            await Pipeline.syncFromLifeOS()
            await Pipeline.pollLoop()
        }
        .onChange(of: phase) { _, now in
            guard now == .active else { return }
            Task { await Pipeline.sendPending(); await Pipeline.syncFromLifeOS() }
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

    /// After a crash: pick the newest interrupted lecture back up.
    static func resumeLatestInterrupted() async {
        let recorder = LectureRecorder.shared
        guard !recorder.isRecording else { return }
        recoverInterrupted(except: nil)
        let interrupted = LectureStatus.interrupted.rawValue
        var latest = FetchDescriptor<Lecture>(predicate: #Predicate { $0.statusRaw == interrupted },
                                              sortBy: [SortDescriptor(\.recordedAt, order: .reverse)])
        latest.fetchLimit = 1
        guard let lecture = try? context.fetch(latest).first else { return }
        await recorder.start(resuming: lecture)
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

    /// Removes a lecture everywhere: audio + chunks on the phone, the saved
    /// lecture, and its copy in LifeOS (transcript + review).
    static func delete(_ lecture: Lecture) {
        let id = lecture.id, uploaded = lecture.uploadedAt != nil || lecture.reviewStatus != .none
        try? FileManager.default.removeItem(at: lecture.audioURL)
        try? FileManager.default.removeItem(at: lecture.chunkFolder)
        context.delete(lecture)
        try? context.save()
        if uploaded { Task { try? await LifeOSClient.shared.remove(id) } }
    }

    /// Frees space but keeps the transcript and review.
    static func deleteAudio(_ lecture: Lecture) {
        try? FileManager.default.removeItem(at: lecture.audioURL)
        try? FileManager.default.removeItem(at: lecture.chunkFolder)
    }

    /// Cloud transcription of a finished lecture: make sure LifeOS has the
    /// lecture, upload the audio, start the engine. With `forReview`, a failure
    /// falls back to the on-device transcript so the review still happens.
    static func cloudTranscribe(_ lecture: Lecture, engine: TranscriptionEngine, forReview: Bool) async {
        guard engine != .onDevice, lecture.hasAudio else { return }
        let lifeos = LifeOSClient.shared
        do {
            try await lifeos.upload(lecture)
            try await lifeos.uploadAudio(lecture)
            try await lifeos.transcribe(lecture.id, engine: engine)
            lecture.cloudError = nil
        } catch {
            lecture.cloudError = "\(engine.label): \(error.localizedDescription)"
            if forReview {
                lecture.transcriptEngine = TranscriptionEngine.onDevice.rawValue
                if lecture.reviewStatus == .requested { lecture.reviewPending = true }
                lecture.uploadedAt = nil
                try? context.save()
                await sendPending()
            }
        }
        try? context.save()
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
            apply(row, to: lecture)
        }
        try? context.save()
    }

    /// Pulls every recent lecture from LifeOS: the iPad gets what the iPhone
    /// recorded, and every device gets finished reviews and guides.
    static func syncFromLifeOS() async {
        guard LifeOSClient.shared.isConnected, let rows = try? await LifeOSClient.shared.allLectures() else { return }
        let all = (try? context.fetch(FetchDescriptor<Lecture>())) ?? []
        var byId: [String: Lecture] = [:]
        for l in all { byId[l.id.uuidString.lowercased()] = l }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        var seen = Set<String>()
        for row in rows {
            let key = row.id.lowercased()
            seen.insert(key)
            let lecture: Lecture
            if let local = byId[key] {
                lecture = local
                // never touch a lecture this device is still recording or sending
                guard local.status == .ready, !local.reviewPending else { continue }
            } else {
                guard let uuid = UUID(uuidString: row.id) else { continue }
                let date = row.recordedAt.flatMap { iso.date(from: $0) ?? isoPlain.date(from: $0) } ?? .now
                lecture = Lecture(title: row.title ?? "Lecture", recordedAt: date, id: uuid)
                lecture.status = .ready
                lecture.uploadedAt = .now
                context.insert(lecture)
            }
            if let t = row.transcript, !lecture.hasAudio || lecture.transcript.isEmpty { lecture.transcript = t }
            if let d = row.durationSec, d > 0, !lecture.hasAudio { lecture.durationSec = d }
            apply(row, to: lecture)
        }
        // copies of lectures deleted on another device (only ones without audio here)
        let window = Date().addingTimeInterval(-110 * 86_400)
        for l in all where !seen.contains(l.id.uuidString.lowercased()) && !l.hasAudio
            && l.uploadedAt != nil && l.status == .ready && !l.reviewPending && l.recordedAt > window {
            context.delete(l)
        }
        try? context.save()
    }

    private static func apply(_ row: LifeOSClient.ServerLecture, to lecture: Lecture) {
        if let course = row.course, !course.isEmpty { lecture.courseName = course }
        if let cid = row.courseId, !cid.isEmpty { lecture.courseId = cid }
        if let short = row.courseShort, !short.isEmpty { lecture.courseShort = short }
        if let status = row.reviewStatus.flatMap(ReviewStatus.init(rawValue:)) { lecture.reviewStatus = status }
        lecture.reviewError = row.reviewError
        if let review = row.review, let data = try? JSONEncoder().encode(review) {
            lecture.reviewJSON = String(data: data, encoding: .utf8)
            if lecture.courseName.isEmpty, let c = review.course, !c.isEmpty { lecture.courseName = c }
        }
    }

    /// While the app is open: check every 15 s whenever something is waiting on Claude.
    static func pollLoop() async {
        while !Task.isCancelled {
            await refreshReviews()
            try? await Task.sleep(for: .seconds(15))
        }
    }
}
