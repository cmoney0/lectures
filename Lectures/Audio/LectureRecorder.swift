import AVFoundation
import Observation
import SwiftData

/// Drives one recording: audio session, the mic pipeline, the live transcript
/// and saving it all into the Lecture as it goes.
@MainActor
@Observable
final class LectureRecorder {
    private(set) var current: Lecture?
    private(set) var isStarting = false
    /// Finalized text for the live view (newest last).
    private(set) var liveLines: [TranscriptPiece] = []
    /// The sentence still being worked on (gray in the UI).
    private(set) var volatileText = ""
    var errorMessage: String?

    private var pipeline: AudioPipeline?
    private var transcriber: LiveTranscriber?
    private var context: ModelContext?
    private var lastSave = Date.distantPast
    private var observers: [NSObjectProtocol] = []

    var isRecording: Bool { current != nil }
    var elapsed: Double { pipeline?.recordedSeconds ?? 0 }
    var level: Float { pipeline?.level ?? 0 }

    func start(title: String, course: Course?, in context: ModelContext) async {
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

        let lecture = Lecture(title: title, courseId: course?.id, courseName: course?.name ?? "")
        context.insert(lecture)
        try? context.save()
        self.context = context
        liveLines = []
        volatileText = ""

        // The transcriber is optional: if it can't start, the audio still records.
        let live = LiveTranscriber()
        do {
            try await live.start { [weak self] text, start, isFinal in
                self?.receive(text: text, start: start, isFinal: isFinal)
            }
            transcriber = live
        } catch {
            transcriber = nil
            errorMessage = "Recording audio only - live transcript unavailable (\(error.localizedDescription)). You can transcribe it afterwards."
        }

        let pipeline = AudioPipeline()
        do {
            let feed = transcriber
            try pipeline.start(writingTo: lecture.audioURL, speechFormat: feed?.format) { buffer in
                feed?.feed(buffer)
            }
        } catch {
            errorMessage = "Couldn't start recording: \(error.localizedDescription)"
            await transcriber?.finish()
            transcriber = nil
            context.delete(lecture)
            try? context.save()
            return
        }
        self.pipeline = pipeline
        current = lecture
        observeSession()
    }

    func stop() async {
        guard let lecture = current, let pipeline else { return }
        stopObserving()
        pipeline.stop()
        lecture.durationSec = pipeline.recordedSeconds
        lecture.status = .transcribing
        await transcriber?.finish()
        transcriber = nil
        if !volatileText.isEmpty {
            // anything the analyzer never finalized
            append(TranscriptPiece(start: liveLines.last?.start ?? 0, text: volatileText), to: lecture)
            volatileText = ""
        }
        lecture.status = .ready
        lecture.uploadedAt = nil
        try? context?.save()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        self.pipeline = nil
        current = nil
    }

    private func receive(text: String, start: Double, isFinal: Bool) {
        guard let lecture = current else { return }
        if isFinal {
            volatileText = ""
            guard !text.isEmpty else { return }
            append(TranscriptPiece(start: start, text: text), to: lecture)
        } else {
            volatileText = text
        }
    }

    private func append(_ piece: TranscriptPiece, to lecture: Lecture) {
        liveLines.append(piece)
        let line = "\(Clock.marker(piece.start)) \(piece.text)"
        lecture.transcript = lecture.transcript.isEmpty ? line : lecture.transcript + "\n" + line
        lecture.durationSec = pipeline?.recordedSeconds ?? lecture.durationSec
        // Save every ~20 s so a crash loses almost nothing.
        if Date().timeIntervalSince(lastSave) > 20 {
            try? context?.save()
            lastSave = Date()
        }
    }

    // MARK: interruptions (calls, Siri) and route changes (AirPods)

    private func observeSession() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard raw == AVAudioSession.InterruptionType.ended.rawValue else { return }
            Task { @MainActor in
                try? AVAudioSession.sharedInstance().setActive(true)
                self?.pipeline?.restart()
            }
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.pipeline?.restart() }
        })
    }

    private func stopObserving() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }
}
