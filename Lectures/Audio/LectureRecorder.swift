import ActivityKit
import AVFoundation
import Observation
import SwiftData
import UIKit

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
        observeSession()
        startActivity(title: target.title)
    }

    // MARK: pause

    func togglePause() {
        guard let pipeline else { return }
        if isPaused {
            do {
                try AVAudioSession.sharedInstance().setActive(true)
                try pipeline.resume()
                isPaused = false
            } catch {
                errorMessage = "Couldn't resume: \(error.localizedDescription)"
            }
        } else {
            pipeline.pause()
            isPaused = true
            try? context.save()
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

        if askForOptions {
            awaitingOptions = lecture
        } else {
            Pipeline.requestReview(for: lecture, options: .saved)
            await Pipeline.sendPending()
        }
        if let total = try? await AudioMerge.merge(folder: lecture.chunkFolder, into: lecture.audioURL), total > 0 {
            lecture.durationSec = total
            try? context.save()
        }
    }

    // MARK: transcript

    private func receive(text: String, start: Double, isFinal: Bool) {
        guard let lecture = current else { return }
        if isFinal {
            volatileText = ""
            guard !text.isEmpty else { return }
            append(TranscriptPiece(start: offset + start, text: text), to: lecture)
            updateActivity(force: false)
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
            lastLine: liveLines.last?.text ?? "Listening...")
    }

    private func startActivity(title: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        activity = try? Activity.request(
            attributes: LectureActivityAttributes(title: title),
            content: ActivityContent(state: activityState(), staleDate: nil))
    }

    private func updateActivity(force: Bool) {
        guard let activity, force || Date().timeIntervalSince(lastActivityUpdate) > 20 else { return }
        lastActivityUpdate = Date()
        let state = activityState()
        Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
    }

    private func endActivity() async {
        await activity?.end(nil, dismissalPolicy: .immediate)
        activity = nil
    }

    /// A crash leaves its Live Activity behind; clear it on launch.
    static func endOrphanedActivities() async {
        for a in Activity<LectureActivityAttributes>.activities { await a.end(nil, dismissalPolicy: .immediate) }
    }

    // MARK: interruptions (calls, Siri) and route changes (AirPods)

    private func observeSession() {
        let center = NotificationCenter.default
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
