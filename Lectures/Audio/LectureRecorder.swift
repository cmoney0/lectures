import ActivityKit
import AVFoundation
import Network
import Observation
import SwiftData
import UIKit
import UserNotifications

/// Drives one recording: audio session, the mic pipeline, the live transcript,
/// the Live Activity, and saving it all into the Lecture as it goes.
/// One shared instance so the Live Activity buttons and Siri/Action Button
/// intents reach the same recorder as the app's screens.
@MainActor
@Observable
final class LectureRecorder {
    static let shared = LectureRecorder()

    private(set) var current: Lecture?
    private(set) var isStarting = false
    private(set) var isPaused = false
    private(set) var liveLines: [TranscriptPiece] = []
    private(set) var volatileText = ""
    var errorMessage: String?
    /// Set when the recording screen should open (Record tapped, intent, resume).
    var showRecorder = false
    /// After an in-app Stop: the lecture waiting for review options.
    var awaitingOptions: Lecture?

    private var pipeline: AudioPipeline?
    private var transcriber: LiveTranscriber?
    /// Seconds already recorded before this session (resume after a crash).
    private var offset: Double = 0
    private var lastSave = Date.distantPast
    private var observers: [NSObjectProtocol] = []
    private var activity: Activity<LectureActivityAttributes>?
    private var lastActivityUpdate = Date.distantPast
    private var watchdog: Task<Void, Never>?
    /// Heartbeats to LifeOS this recording (Settings > Last recording).
    private var heartbeats = HeartbeatLog()
    /// The Live Activity's APNs token: LifeOS pushes "Recording stopped" with it.
    private var pushToken: String?
    private var tokenTask: Task<Void, Never>?
    /// Back online after a dead spot: heartbeat at once so LifeOS never thinks it stopped.
    private var pathMonitor: NWPathMonitor?

    private var context: ModelContext { Store.container.mainContext }

    var isRecording: Bool { current != nil }
    var elapsed: Double { offset + (pipeline?.recordedSeconds ?? 0) }
    var level: Float { pipeline?.level ?? 0 }

    // MARK: start / resume

    /// One button: no questions, the class is worked out later by Claude.
    /// Pass a lecture to keep adding to it (after the app was killed).
    func start(resuming lecture: Lecture? = nil) async {
        showRecorder = true
        guard current == nil, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        errorMessage = nil

        await CrashWatchdog.requestPermission()
        guard await AVAudioApplication.requestRecordPermission() else {
            errorMessage = "Microphone access is off. Turn it on in Settings > Lectures."
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .default, options: [])
            try session.setActive(true)
        } catch {
            errorMessage = "Couldn't start the microphone: \(error.localizedDescription)"
            return
        }

        let target: Lecture
        if let lecture {
            // fold any chunks a crash left behind into the main file first
            if let total = try? await AudioMerge.merge(folder: lecture.chunkFolder, into: lecture.audioURL), total > 0 {
                lecture.durationSec = total
            }
            target = lecture
            offset = lecture.durationSec
            liveLines = Self.pieces(from: lecture.transcript)
        } else {
            let day = Date().formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
            target = Lecture(title: "Lecture - \(day)")
            context.insert(target)
            offset = 0
            liveLines = []
        }
        target.status = .recording
        try? context.save()
        volatileText = ""
        isPaused = false

        // The transcriber is optional: if it can't start, the audio still records.
        let live = LiveTranscriber()
        do {
            try await live.start { [weak self] text, start, isFinal in
                self?.receive(text: text, start: start, isFinal: isFinal)
            }
            transcriber = live
        } catch {
            transcriber = nil
            errorMessage = "Recording audio only - live transcript unavailable (\(error.localizedDescription)). Use Redo transcript afterwards."
        }

        let pipeline = AudioPipeline()
        do {
            let feed = transcriber
            try pipeline.start(folder: target.chunkFolder, speechFormat: feed?.format) { buffer in
                feed?.feed(buffer)
            }
        } catch {
            errorMessage = "Couldn't start recording: \(error.localizedDescription)"
            await transcriber?.finish()
            transcriber = nil
            if lecture == nil { context.delete(target) } else { target.status = .interrupted }
            try? context.save()
            return
        }
        self.pipeline = pipeline
        current = target
        heartbeats = HeartbeatLog()
        observeSession()
        startActivity(title: target.title, lectureId: target.id)
        startPathMonitor()
        armWatchdog()
    }

    // MARK: pause

    func togglePause() {
        guard let pipeline else { return }
        if isPaused {
            do {
                try AVAudioSession.sharedInstance().setActive(true)
                try pipeline.resume()
                isPaused = false
                armWatchdog()
                sendLive("recording")
            } catch {
                errorMessage = "Couldn't resume: \(error.localizedDescription)"
            }
        } else {
            pipeline.pause()
            isPaused = true
            // a paused app may be suspended - that's not a crash
            disarmWatchdog()
            try? context.save()
            sendLive("paused")
        }
        updateActivity(force: true)
    }

    // MARK: stop

    /// In the app Stop asks for review options; from the Lock Screen it sends
    /// straight away with the saved ones.
    func stop(askForOptions: Bool) async {
        guard let lecture = current, let pipeline else { return }
        // keep running long enough to finish + upload if this came from the Lock Screen
        let task = UIApplication.shared.beginBackgroundTask(withName: "finish-lecture")
        defer { UIApplication.shared.endBackgroundTask(task) }

        stopObserving()
        disarmWatchdog()
        stopPathMonitor()
        sendLive("ended")
        pipeline.stop()
        lecture.durationSec = elapsed
        lecture.status = .finishing
        await transcriber?.finish()
        transcriber = nil
        if !volatileText.isEmpty {
            append(TranscriptPiece(start: liveLines.last?.start ?? offset, text: volatileText), to: lecture)
            volatileText = ""
        }
        lecture.status = .ready
        lecture.uploadedAt = nil
        try? context.save()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        await endActivity()
        self.pipeline = nil
        current = nil
        isPaused = false
        offset = 0

        // Settings > Transcription: the review uses this engine's transcript
        let engine = TranscriptionEngine.saved
        lecture.transcriptEngine = engine.rawValue
        try? context.save()
        if askForOptions { awaitingOptions = lecture }
        if let total = try? await AudioMerge.merge(folder: lecture.chunkFolder, into: lecture.audioURL), total > 0 {
            lecture.durationSec = total
            try? context.save()
        }
        // cloud engine: upload the merged audio and start it before asking for the review
        if engine != .onDevice { await Pipeline.cloudTranscribe(lecture, engine: engine, forReview: true) }
        if !askForOptions {
            Pipeline.requestReview(for: lecture, options: .saved)
            await Pipeline.sendPending()
        }
    }

    // MARK: transcript

    private func receive(text: String, start: Double, isFinal: Bool) {
        guard let lecture = current else { return }
        if isFinal {
            volatileText = ""
            guard !text.isEmpty else { return }
            append(TranscriptPiece(start: offset + start, text: text), to: lecture)
        } else {
            volatileText = text
        }
    }

    private func append(_ piece: TranscriptPiece, to lecture: Lecture) {
        liveLines.append(piece)
        let line = "\(Clock.marker(piece.start)) \(piece.text)"
        lecture.transcript = lecture.transcript.isEmpty ? line : lecture.transcript + "\n" + line
        lecture.durationSec = elapsed
        // save every ~15 s so a crash loses almost nothing
        if Date().timeIntervalSince(lastSave) > 15 {
            try? context.save()
            lastSave = Date()
        }
    }

    static func pieces(from transcript: String) -> [TranscriptPiece] {
        transcript.split(separator: "\n").map { line in
            let s = String(line)
            if s.hasPrefix("["), let close = s.firstIndex(of: "]"),
               let t = Clock.seconds(String(s[s.index(after: s.startIndex)..<close])) {
                return TranscriptPiece(start: t, text: String(s[s.index(after: close)...]).trimmingCharacters(in: .whitespaces))
            }
            return TranscriptPiece(start: 0, text: s)
        }
    }

    // MARK: Live Activity

    private func activityState() -> LectureActivityAttributes.ContentState {
        LectureActivityAttributes.ContentState(
            startedAt: Date().addingTimeInterval(-elapsed),
            pausedElapsed: isPaused ? elapsed : nil,
            lastLine: liveLines.last?.text ?? "Listening...",
            lost: nil)
    }

    private func startActivity(title: String, lectureId: UUID) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attributes = LectureActivityAttributes(title: title, lectureId: lectureId.uuidString)
        let content = ActivityContent(state: activityState(), staleDate: staleDate)
        // with a push token LifeOS can mark it stopped if the app dies; without
        // push (older build profile) it still shows, just without that backstop
        activity = (try? Activity.request(attributes: attributes, content: content, pushType: .token))
            ?? (try? Activity.request(attributes: attributes, content: content))
        pushToken = nil
        tokenTask?.cancel()
        if let activity {
            tokenTask = Task { [weak self] in
                for await data in activity.pushTokenUpdates {
                    let hex = data.map { String(format: "%02x", $0) }.joined()
                    await MainActor.run { self?.pushToken = hex; self?.sendLive("recording") }
                }
            }
        }
        sendLive("recording")
    }

    /// Tell LifeOS the recording's state (heartbeat / pause / resume / end).
    private func sendLive(_ state: String) {
        guard let lecture = current, LifeOSClient.shared.isConnected else { return }
        let id = lecture.id, token = pushToken, started = Date().addingTimeInterval(-elapsed)
        Task { [weak self] in
            let ok = await LifeOSClient.shared.live(id, state: state, token: token, startedAt: started)
            guard state == "recording" else { return }
            await MainActor.run {
                guard let self else { return }
                self.heartbeats.beat(at: Date(), delivered: ok)
                RecordingDiagnostics.save(self.heartbeats, activity: self.activity.map { "\($0.activityState)" } ?? "none")
            }
        }
    }

    private func startPathMonitor() {
        stopPathMonitor()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in
                guard let self, self.isRecording, !self.isPaused else { return }
                self.sendLive("recording")
            }
        }
        monitor.start(queue: DispatchQueue(label: "lectures.path"))
        pathMonitor = monitor
    }

    private func stopPathMonitor() {
        pathMonitor?.cancel()
        pathMonitor = nil
    }

    private func updateActivity(force: Bool) {
        guard let activity, force || Date().timeIntervalSince(lastActivityUpdate) > LiveActivityPolicy.heartbeat else { return }
        lastActivityUpdate = Date()
        let state = activityState()
        let stale = staleDate
        Task { await activity.update(ActivityContent(state: state, staleDate: stale)) }
    }

    /// Never a stale date: only LifeOS's push can say "stopped" (LiveActivityPolicy).
    private var staleDate: Date? { LiveActivityPolicy.staleDate(now: Date(), paused: isPaused) }

    // MARK: crash watchdog (Colby lost 15 min to a silent crash, 2026-11-09)

    /// Every 20 s: push the "stopped recording" notification another 75 s out
    /// and refresh the Live Activity's stale date. If the app is killed, the
    /// pushes stop and the notification fires.
    private func armWatchdog() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                CrashWatchdog.schedule(in: LiveActivityPolicy.crashNotificationAfter)
                self?.heartbeat()
                try? await Task.sleep(for: .seconds(LiveActivityPolicy.heartbeat))
            }
        }
    }

    /// Every 20 s: tell LifeOS we're alive (the Live Activity itself only
    /// changes on start / pause / resume / stop).
    private func heartbeat() {
        sendLive("recording")
    }

    private func disarmWatchdog() {
        watchdog?.cancel()
        watchdog = nil
        CrashWatchdog.cancel()
    }

    private func endActivity() async {
        tokenTask?.cancel()
        tokenTask = nil
        pushToken = nil
        await activity?.end(nil, dismissalPolicy: .immediate)
        activity = nil
    }

    /// A crash leaves its Live Activity behind; clear it on launch (never the
    /// one recording right now) and tell LifeOS it ended.
    static func endOrphanedActivities() async {
        let live = shared.activity?.id
        for a in Activity<LectureActivityAttributes>.activities where a.id != live {
            if let raw = a.attributes.lectureId, let id = UUID(uuidString: raw) {
                await LifeOSClient.shared.live(id, state: "ended", token: nil, startedAt: nil)
            }
            await a.end(nil, dismissalPolicy: .immediate)
        }
    }

    // MARK: interruptions (calls, Siri) and route changes (AirPods)

    private func observeSession() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updateActivity(force: true) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard raw == AVAudioSession.InterruptionType.ended.rawValue else { return }
            Task { @MainActor in
                guard let self, !self.isPaused else { return }
                try? AVAudioSession.sharedInstance().setActive(true)
                self.pipeline?.restart()
            }
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isPaused else { return }
                self.pipeline?.restart()
            }
        })
    }

    private func stopObserving() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }
}

/// What the last recording's heartbeat looked like (Settings > Diagnostics):
/// a long max gap means iOS held back the app while the phone was locked.
enum RecordingDiagnostics {
    private static let key = "diag.heartbeats"
    private static let activityKey = "diag.activityState"

    static func save(_ log: HeartbeatLog, activity: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(log), forKey: key)
        UserDefaults.standard.set(activity, forKey: activityKey)
    }

    static var last: (log: HeartbeatLog, activity: String)? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let log = try? JSONDecoder().decode(HeartbeatLog.self, from: data) else { return nil }
        return (log, UserDefaults.standard.string(forKey: activityKey) ?? "unknown")
    }
}

/// The "app stopped recording" notification (see LectureRecorder.armWatchdog).
enum CrashWatchdog {
    static let id = "recording-watchdog"

    static func requestPermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    static func schedule(in seconds: TimeInterval) {
        let content = UNMutableNotificationContent()
        content.title = "Lectures stopped recording"
        content.body = "The app closed while recording. Tap to resume this lecture."
        content.sound = .default
        content.interruptionLevel = .active
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)
        // same id each time, so this replaces the previous one
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    static func cancel() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
    }
}
