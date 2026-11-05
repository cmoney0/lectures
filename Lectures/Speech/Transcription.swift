import AVFoundation
import Speech

/// One finalized piece of transcript and where it starts in the recording.
struct TranscriptPiece: Sendable {
    var start: Double
    var text: String
}

enum TranscriptionError: LocalizedError {
    case unsupportedLocale
    case noAudioFormat

    var errorDescription: String? {
        switch self {
        case .unsupportedLocale: "On-device transcription isn't available for this language."
        case .noAudioFormat: "The transcriber couldn't agree on an audio format."
        }
    }
}

/// Apple's on-device long-form transcriber (iOS 26 SpeechAnalyzer). Built for
/// lectures and distant speech; runs offline and costs nothing.
enum OnDeviceSpeech {
    static func locale() async throws -> Locale {
        if let l = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) { return l }
        if let l = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) { return l }
        throw TranscriptionError.unsupportedLocale
    }

    static func makeTranscriber(live: Bool) async throws -> SpeechTranscriber {
        let transcriber = SpeechTranscriber(
            locale: try await locale(),
            transcriptionOptions: [],
            reportingOptions: live ? [.volatileResults] : [],
            attributeOptions: [.audioTimeRange])
        // First run downloads the language model (a one-time, small download).
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        return transcriber
    }

    static func text(of result: SpeechTranscriber.Result) -> String {
        String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Re-transcribes a saved recording from scratch (used after a crash, or to
    /// redo a bad live transcript).
    static func transcribe(file url: URL) async throws -> [TranscriptPiece] {
        let transcriber = try await makeTranscriber(live: false)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task { () throws -> [TranscriptPiece] in
            var pieces: [TranscriptPiece] = []
            for try await result in transcriber.results where result.isFinal {
                let text = text(of: result)
                if !text.isEmpty { pieces.append(TranscriptPiece(start: result.range.start.seconds, text: text)) }
            }
            return pieces
        }
        let audio = try AVAudioFile(forReading: url)
        if let last = try await analyzer.analyzeSequence(from: audio) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collector.value
    }
}

/// Streams microphone buffers into SpeechAnalyzer while a lecture records.
final class LiveTranscriber: @unchecked Sendable {
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private(set) var format: AVAudioFormat?

    /// `onResult(text, startSeconds, isFinal)` runs on the main actor.
    func start(onResult: @escaping @MainActor (String, Double, Bool) -> Void) async throws {
        let transcriber = try await OnDeviceSpeech.makeTranscriber(live: true)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw TranscriptionError.noAudioFormat
        }
        self.format = format
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        input = continuation
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        resultsTask = Task {
            do {
                for try await result in transcriber.results {
                    let text = OnDeviceSpeech.text(of: result)
                    let start = result.range.start.seconds
                    let isFinal = result.isFinal
                    await MainActor.run { onResult(text, start.isFinite ? start : 0, isFinal) }
                }
            } catch {
                // The recording itself keeps going; the audio can be re-transcribed.
            }
        }
        try await analyzer.start(inputSequence: stream)
    }

    /// Called from the audio thread with buffers already in `format`.
    func feed(_ buffer: AVAudioPCMBuffer) {
        input?.yield(AnalyzerInput(buffer: buffer))
    }

    /// Flushes everything still being processed into final results.
    func finish() async {
        input?.finish()
        input = nil
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        await resultsTask?.value
        analyzer = nil
        resultsTask = nil
    }
}
