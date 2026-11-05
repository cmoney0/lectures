import AVFoundation
import os

/// Microphone -> (AAC chunks on disk) + (live transcriber).
///
/// Every mic buffer is converted to one fixed recording format (mono 24 kHz),
/// so AirPods in/out never breaks a file. Audio is written in 60-second .m4a
/// chunks: a crash or force-quit loses at most the chunk being written, and
/// `AudioMerge` joins them into one file when the recording ends.
final class AudioPipeline: @unchecked Sendable {
    static let recordFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!
    static let chunkSeconds = 60.0

    private let engine = AVAudioEngine()
    private var folder: URL!
    private var chunkIndex = 0
    private var chunkFrames: Int64 = 0
    private var file: AVAudioFile?
    private var micConverter: AVAudioConverter?
    private var speechConverter: AVAudioConverter?
    private var speechFormat: AVAudioFormat?
    private var onSpeechBuffer: ((AVAudioPCMBuffer) -> Void)?
    private let meter = OSAllocatedUnfairLock(initialState: Meter())

    struct Meter { var frames: Int64 = 0; var level: Float = 0 }

    /// Seconds recorded in this session (pauses don't count).
    var recordedSeconds: Double { Double(meter.withLock { $0.frames }) / Self.recordFormat.sampleRate }
    /// 0...1 input loudness for the meter.
    var level: Float { meter.withLock { $0.level } }

    func start(folder: URL, speechFormat: AVAudioFormat?, onSpeechBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        self.folder = folder
        // continue numbering after chunks a crashed session left behind
        chunkIndex = AudioMerge.chunks(in: folder).count
        try openChunk()
        self.speechFormat = speechFormat
        if let speechFormat, speechFormat != Self.recordFormat {
            speechConverter = AVAudioConverter(from: Self.recordFormat, to: speechFormat)
        }
        self.onSpeechBuffer = onSpeechBuffer
        installTap()
        engine.prepare()
        try engine.start()
    }

    func pause() {
        engine.pause()
        meter.withLock { $0.level = 0 }
    }

    func resume() throws {
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
        file = nil // closes and finalizes the last chunk
        onSpeechBuffer = nil
    }

    private func openChunk() throws {
        let url = folder.appendingPathComponent(String(format: "chunk-%05d.m4a", chunkIndex))
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Self.recordFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 48_000,
        ]
        file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        chunkFrames = 0
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
        chunkFrames += Int64(recorded.frameLength)
        if Double(chunkFrames) >= Self.chunkSeconds * Self.recordFormat.sampleRate {
            file = nil
            chunkIndex += 1
            try? openChunk()
        }
        let level = Self.rms(recorded)
        meter.withLock { m in
            m.frames += Int64(recorded.frameLength)
            m.level = level
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
        let db = 20 * log10(max(rms, 0.000_01))
        return max(0, min(1, (db + 50) / 50))
    }
}

/// Joins a lecture's chunks (after any audio merged earlier) into one .m4a.
enum AudioMerge {
    static func chunks(in folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("chunk-") && $0.pathExtension == "m4a" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Returns the total length in seconds. Unreadable chunks (the one being
    /// written when the app was killed) are skipped.
    @discardableResult
    static func merge(folder: URL, into output: URL) async throws -> Double {
        let fm = FileManager.default
        let chunkFiles = chunks(in: folder)
        var inputs: [URL] = fm.fileExists(atPath: output.path) ? [output] : []
        inputs += chunkFiles
        guard !inputs.isEmpty else { return 0 }
        if inputs == [output] { return try await duration(of: output) }

        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { return 0 }
        var cursor = CMTime.zero
        for url in inputs {
            let asset = AVURLAsset(url: url)
            guard let source = try? await asset.loadTracks(withMediaType: .audio).first,
                  let length = try? await asset.load(.duration), length.seconds > 0 else { continue }
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: source, at: cursor)
            cursor = cursor + length
        }
        guard cursor.seconds > 0, let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else { return 0 }
        let temp = folder.appendingPathComponent("merged-\(UUID().uuidString).m4a")
        try await export.export(to: temp, as: .m4a)
        try? fm.removeItem(at: output)
        try fm.moveItem(at: temp, to: output)
        for chunk in chunkFiles { try? fm.removeItem(at: chunk) }
        return cursor.seconds
    }

    static func duration(of url: URL) async throws -> Double {
        try await AVURLAsset(url: url).load(.duration).seconds
    }
}
