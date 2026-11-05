import AVFoundation
import os

/// Microphone -> (AAC file on disk) + (live transcriber).
///
/// Every mic buffer is first converted to one fixed recording format (mono,
/// 24 kHz), so a route change (AirPods in/out) that changes the mic's format
/// never breaks the file. That buffer is written to the .m4a and converted
/// again to whatever format the transcriber asked for.
final class AudioPipeline: @unchecked Sendable {
    static let recordFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!

    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private var micConverter: AVAudioConverter?
    private var speechConverter: AVAudioConverter?
    private var speechFormat: AVAudioFormat?
    private var onSpeechBuffer: ((AVAudioPCMBuffer) -> Void)?
    private let lock = OSAllocatedUnfairLock(initialState: Meter())

    struct Meter { var frames: Int64 = 0; var level: Float = 0 }

    /// Seconds of audio written so far (pauses for interruptions don't count).
    var recordedSeconds: Double { Double(lock.withLock { $0.frames }) / Self.recordFormat.sampleRate }
    /// 0...1 input loudness for the meter.
    var level: Float { lock.withLock { $0.level } }

    func start(writingTo url: URL, speechFormat: AVAudioFormat?, onSpeechBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Self.recordFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 48_000,
        ]
        file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        self.speechFormat = speechFormat
        if let speechFormat, speechFormat != Self.recordFormat {
            speechConverter = AVAudioConverter(from: Self.recordFormat, to: speechFormat)
        }
        self.onSpeechBuffer = onSpeechBuffer
        installTap()
        engine.prepare()
        try engine.start()
    }

    /// After an interruption (phone call) or a route change.
    func restart() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        installTap()
        engine.prepare()
        try? engine.start()
    }

    func stop() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        file = nil // closes and finalizes the .m4a
        onSpeechBuffer = nil
    }

    private func installTap() {
        let input = engine.inputNode
        let micFormat = input.outputFormat(forBus: 0)
        guard micFormat.sampleRate > 0, micFormat.channelCount > 0 else { return }
        micConverter = AVAudioConverter(from: micFormat, to: Self.recordFormat)
        input.installTap(onBus: 0, bufferSize: 4096, format: micFormat) { [weak self] buffer, _ in
            self?.handle(buffer)
        }
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        guard let micConverter, let recorded = Self.convert(buffer, with: micConverter, to: Self.recordFormat) else { return }
        try? file?.write(from: recorded)
        let level = Self.rms(recorded)
        lock.withLock { meter in
            meter.frames += Int64(recorded.frameLength)
            meter.level = level
        }
        if let speechConverter, let speechFormat {
            if let speech = Self.convert(recorded, with: speechConverter, to: speechFormat) { onSpeechBuffer?(speech) }
        } else {
            onSpeechBuffer?(recorded)
        }
    }

    static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if fed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0 else { return nil }
        return out
    }

    private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<n { sum += data[i] * data[i] }
        let rms = (sum / Float(n)).squareRoot()
        // ~ -50 dB .. 0 dB onto 0...1
        let db = 20 * log10(max(rms, 0.000_01))
        return max(0, min(1, (db + 50) / 50))
    }
}
