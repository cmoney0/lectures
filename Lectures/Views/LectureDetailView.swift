import AVFoundation
import SwiftData
import SwiftUI
import UIKit

/// One lecture: playback, the transcript, and getting it to Claude.
struct LectureDetailView: View {
    @Bindable var lecture: Lecture
    @Environment(\.modelContext) private var context
    @Environment(LifeOSClient.self) private var lifeos
    @State private var player = LecturePlayer()
    @State private var retranscribing = false
    @State private var message: String?
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Card {
                    TextField("Title", text: $lecture.title, axis: .vertical)
                        .font(.m(20, .bold)).foregroundStyle(Theme.text)
                        .onSubmit { edited() }
                    Text([lecture.courseName.isEmpty ? nil : lecture.courseName,
                          lecture.recordedAt.formatted(date: .abbreviated, time: .shortened),
                          Clock.string(lecture.durationSec),
                          "\(lecture.wordCount) words"].compactMap { $0 }.joined(separator: " · "))
                        .font(.m(12)).foregroundStyle(Theme.sub)
                    syncLine
                }

                if lecture.hasAudio { playerCard }

                Card {
                    Text("Send to Claude").font(.m(12, .bold)).foregroundStyle(Theme.sub)
                    Text(lifeos.isConnected
                         ? "Your School Claude project reads this from LifeOS automatically. Or share it into any chat:"
                         : "Share it into a Claude chat, or connect LifeOS in Settings so your School project gets every lecture automatically.")
                        .font(.m(12)).foregroundStyle(Theme.sub)
                    HStack(spacing: 10) {
                        ShareLink(item: ClaudeExport.file(for: lecture), preview: SharePreview(lecture.title)) {
                            Label("Share", systemImage: "square.and.arrow.up").font(.m(14, .bold))
                                .frame(maxWidth: .infinity).padding(.vertical, 11)
                                .foregroundStyle(.white).background(Theme.accent, in: RoundedRectangle(cornerRadius: 12))
                        }
                        Button {
                            UIPasteboard.general.string = ClaudeExport.text(for: lecture)
                            copied = true
                        } label: {
                            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc").font(.m(14, .bold))
                                .frame(maxWidth: .infinity).padding(.vertical, 11)
                                .foregroundStyle(Theme.text).background(Theme.bg, in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                    }
                }

                if let guide = lecture.reviewGuide, !guide.isEmpty {
                    Card {
                        Text("Review guide").font(.m(12, .bold)).foregroundStyle(Theme.sub)
                        Text(guide).font(.m(14)).foregroundStyle(Theme.text).textSelection(.enabled)
                    }
                }

                Card {
                    HStack {
                        Text("Transcript").font(.m(12, .bold)).foregroundStyle(Theme.sub)
                        Spacer()
                        if lecture.hasAudio {
                            Button(retranscribing ? "Transcribing..." : "Redo from audio") { Task { await retranscribe() } }
                                .font(.m(12, .bold)).disabled(retranscribing || lecture.status == .recording)
                        }
                    }
                    if let message { Text(message).font(.m(12)).foregroundStyle(Theme.red) }
                    if lecture.transcript.isEmpty {
                        Text(lecture.status == .failed
                             ? "The app closed before this transcript was saved. Tap Redo from audio."
                             : "No transcript yet.")
                            .font(.m(14)).foregroundStyle(Theme.sub)
                    } else {
                        TranscriptText(transcript: lecture.transcript) { seconds in player.play(lecture.audioURL, from: seconds) }
                    }
                }
            }
            .padding(16)
        }
        .background(Theme.bg)
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { player.stop(); edited() }
    }

    private var syncLine: some View {
        HStack(spacing: 6) {
            if lecture.uploadedAt != nil {
                Image(systemName: "checkmark.icloud.fill").foregroundStyle(Theme.green)
                Text("In LifeOS - your School project can read it")
            } else if let err = lecture.uploadError {
                Image(systemName: "exclamationmark.icloud").foregroundStyle(Theme.red)
                Text(err).lineLimit(2)
                Button("Retry") { Task { await Uploader.send(lecture, with: lifeos); try? context.save() } }.font(.m(12, .bold))
            } else if lecture.status == .ready {
                Image(systemName: "icloud.and.arrow.up").foregroundStyle(Theme.sub)
                Text(lifeos.isConnected ? "Waiting to send to LifeOS" : "Not connected to LifeOS")
            }
        }
        .font(.m(12)).foregroundStyle(Theme.sub)
    }

    private var playerCard: some View {
        Card {
            HStack(spacing: 14) {
                Button { player.toggle(lecture.audioURL) } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 38))
                }
                Button { player.skip(-15) } label: { Image(systemName: "gobackward.15").font(.system(size: 20)) }
                Button { player.skip(15) } label: { Image(systemName: "goforward.15").font(.system(size: 20)) }
                Spacer()
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    Text("\(Clock.string(player.time)) / \(Clock.string(lecture.durationSec))")
                        .font(.m(12, .semibold)).monospacedDigit().foregroundStyle(Theme.sub)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
        }
    }

    /// Title edits re-send to LifeOS.
    private func edited() {
        guard context.hasChanges else { return }
        lecture.uploadedAt = nil
        try? context.save()
        Task { await Uploader.sendPending(in: context, with: lifeos) }
    }

    private func retranscribe() async {
        retranscribing = true
        message = nil
        defer { retranscribing = false }
        do {
            let pieces = try await OnDeviceSpeech.transcribe(file: lecture.audioURL)
            lecture.transcript = pieces.map { "\(Clock.marker($0.start)) \($0.text)" }.joined(separator: "\n")
            if let file = try? AVAudioFile(forReading: lecture.audioURL) {
                lecture.durationSec = Double(file.length) / file.fileFormat.sampleRate
            }
            lecture.engine = "on-device"
            lecture.status = .ready
            lecture.uploadedAt = nil
            try? context.save()
            await Uploader.sendPending(in: context, with: lifeos)
        } catch {
            message = "Couldn't transcribe: \(error.localizedDescription)"
        }
    }
}

/// Transcript lines; tap a timestamp to hear that moment.
struct TranscriptText: View {
    let transcript: String
    var seek: (Double) -> Void

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(Array(transcript.split(separator: "\n").enumerated()), id: \.offset) { _, line in
                let (time, text) = Self.parse(String(line))
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let time {
                        Button(Clock.string(time)) { seek(time) }
                            .font(.m(11, .semibold)).monospacedDigit().foregroundStyle(Theme.accent).buttonStyle(.plain)
                    }
                    Text(text).font(.m(15)).foregroundStyle(Theme.text).textSelection(.enabled)
                }
            }
        }
    }

    /// "[1:02:03] text" -> (3723, "text")
    static func parse(_ line: String) -> (Double?, String) {
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return (nil, line) }
        let stamp = line[line.index(after: line.startIndex)..<close]
        let parts = stamp.split(separator: ":").compactMap { Double($0) }
        let seconds = parts.reduce(0) { $0 * 60 + $1 }
        let text = String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        return (parts.isEmpty ? nil : seconds, text)
    }
}

/// What gets shared or copied into Claude: a short brief + the transcript.
enum ClaudeExport {
    static func text(for lecture: Lecture) -> String {
        """
        # \(lecture.title)
        Course: \(lecture.courseName.isEmpty ? "-" : lecture.courseName)
        Recorded: \(lecture.recordedAt.formatted(date: .complete, time: .shortened)) (\(Clock.string(lecture.durationSec)))

        This is an automatic, on-device transcript of my class lecture, so expect some misheard words.
        Please turn it into study notes: the main ideas, key definitions and formulas, anything the professor said would be on an exam or homework, and a few practice questions.

        ## Transcript
        \(lecture.transcript)
        """
    }

    static func file(for lecture: Lecture) -> URL {
        let safe = lecture.title.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safe.isEmpty ? "Lecture" : safe).md")
        try? text(for: lecture).write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

/// Simple playback of a saved recording.
@MainActor
@Observable
final class LecturePlayer {
    private var player: AVAudioPlayer?
    private var url: URL?
    private(set) var isPlaying = false

    var time: Double { player?.currentTime ?? 0 }

    func toggle(_ url: URL) {
        if isPlaying { player?.pause(); isPlaying = false } else { play(url, from: nil) }
    }

    func play(_ url: URL, from seconds: Double?) {
        if self.url != url || player == nil {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try? AVAudioSession.sharedInstance().setActive(true)
            player = try? AVAudioPlayer(contentsOf: url)
            player?.prepareToPlay()
            self.url = url
        }
        if let seconds { player?.currentTime = max(0, seconds - 2) }
        player?.play()
        isPlaying = player?.isPlaying ?? false
    }

    func skip(_ delta: Double) {
        guard let player else { return }
        player.currentTime = max(0, min(player.duration, player.currentTime + delta))
    }

    func stop() {
        player?.stop()
        isPlaying = false
    }
}
