import AVFoundation
import SwiftData
import SwiftUI
import UIKit

/// One lecture: Claude's review (notes, flashcards, quiz), the transcript and audio.
struct LectureDetailView: View {
    @Bindable var lecture: Lecture
    @Environment(\.modelContext) private var context
    @Environment(LectureRecorder.self) private var recorder
    @State private var tab = 0
    @State private var player = LecturePlayer()
    @State private var redoing = false
    @State private var message: String?
    @State private var confirmDelete = false
    @Environment(\.dismiss) private var dismiss

    private var review: LectureReview? { lecture.review }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                if lecture.stage != .done { PipelineCard(lecture: lecture) }
                if review != nil {
                    Picker("View", selection: $tab) {
                        if review?.guide != nil { Text("Guide").tag(4) }
                        Text("Review").tag(0)
                        Text("Cards").tag(1)
                        Text("Quiz").tag(2)
                        Text("Transcript").tag(3)
                    }
                    .pickerStyle(.segmented)
                }
                switch review == nil ? 3 : tab {
                case 4:
                    if let guide = review?.guide { GuideView(guide: guide) }
                case 0: ReviewNotesView(review: review!) { stamp in seek(stamp) }
                case 1: FlashcardsView(cards: review?.flashcards ?? [])
                case 2: QuizView(questions: review?.quiz ?? [])
                default: transcriptSection
                }
            }
            .padding(16)
        }
        .background(Theme.bg)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { menu }
        }
        .onAppear {
            // the iPad opens straight into the in-depth guide when there is one
            if review?.guide != nil && UIDevice.current.userInterfaceIdiom == .pad { tab = 4 }
        }
        .onDisappear { player.stop() }
        .confirmationDialog("Delete this lecture? It is removed from your phone and LifeOS.", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete lecture", role: .destructive) {
                player.stop()
                dismiss()
                // delete after the screen has closed so it never draws a deleted lecture
                let doomed = lecture
                Task { try? await Task.sleep(for: .milliseconds(500)); Pipeline.delete(doomed) }
            }
            if lecture.hasAudio {
                Button("Delete audio only (keep notes)") { player.stop(); Pipeline.deleteAudio(lecture) }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !lecture.displayCourse.isEmpty {
                Text(lecture.displayCourse.uppercased()).font(.m(11, .heavy)).foregroundStyle(Theme.accent)
            }
            Text(lecture.displayTitle).font(.m(22, .heavy)).foregroundStyle(Theme.text)
            Text("\(lecture.recordedAt.formatted(date: .abbreviated, time: .shortened)) · \(Clock.string(lecture.durationSec)) · \(lecture.wordCount) words")
                .font(.m(12)).foregroundStyle(Theme.sub)
            if lecture.hasAudio { playerBar.padding(.top, 6) }
        }
    }

    private var playerBar: some View {
        HStack(spacing: 14) {
            Button { player.toggle(lecture.audioURL) } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 34))
            }
            Button { player.skip(-15) } label: { Image(systemName: "gobackward.15").font(.system(size: 18)) }
            Button { player.skip(15) } label: { Image(systemName: "goforward.15").font(.system(size: 18)) }
            Spacer()
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                Text("\(Clock.string(player.time)) / \(Clock.string(lecture.durationSec))")
                    .font(.m(12, .semibold)).monospacedDigit().foregroundStyle(Theme.sub)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.accent)
        .padding(12)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
    }

    private var transcriptSection: some View {
        Card {
            HStack {
                Text("Transcript").font(.m(12, .bold)).foregroundStyle(Theme.sub)
                Spacer()
                Button("Copy") { UIPasteboard.general.string = lecture.transcript }.font(.m(12, .bold))
            }
            if let message { Text(message).font(.m(12)).foregroundStyle(Theme.red) }
            if lecture.transcript.isEmpty {
                Text("No transcript yet. Use Redo transcript from the menu.").font(.m(14)).foregroundStyle(Theme.sub)
            } else {
                TranscriptText(transcript: lecture.transcript) { seconds in player.play(lecture.audioURL, from: seconds) }
            }
        }
    }

    private var menu: some View {
        Menu {
            if let review {
                ShareLink(item: ReviewPDF.file(for: lecture, review: review), preview: SharePreview(lecture.displayTitle)) {
                    Label("Export PDF", systemImage: "doc.richtext")
                }
            }
            ShareLink(item: ClaudeExport.text(for: lecture)) { Label("Share transcript to Claude", systemImage: "square.and.arrow.up") }
            if lecture.hasAudio, let audio = AudioExport.file(for: lecture) {
                ShareLink(item: audio) { Label("Share audio", systemImage: "waveform") }
            }
            Button { recorder.awaitingOptions = lecture } label: {
                Label(review == nil ? "Ask Claude for a review" : "Redo review", systemImage: "sparkles")
            }
            .disabled(lecture.status != .ready)
            Button { Task { await recorder.start(resuming: lecture) } } label: {
                Label("Continue recording", systemImage: "record.circle")
            }
            .disabled(recorder.isRecording || lecture.status == .recording)
            if lecture.hasAudio {
                Button { Task { await redoTranscript() } } label: { Label("Redo transcript from audio", systemImage: "waveform") }
                    .disabled(redoing || lecture.status == .recording)
            }
            Divider()
            Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
                .disabled(lecture.status == .recording)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }

    private func seek(_ stamp: String?) {
        guard lecture.hasAudio, let stamp, let t = Clock.seconds(stamp) else { return }
        player.play(lecture.audioURL, from: t)
    }

    private func redoTranscript() async {
        redoing = true
        message = nil
        tab = 3
        defer { redoing = false }
        do {
            let pieces = try await OnDeviceSpeech.transcribe(file: lecture.audioURL)
            lecture.transcript = pieces.map { "\(Clock.marker($0.start)) \($0.text)" }.joined(separator: "\n")
            lecture.durationSec = (try? await AudioMerge.duration(of: lecture.audioURL)) ?? lecture.durationSec
            lecture.engine = "on-device"
            lecture.uploadedAt = nil
            try? context.save()
            await Pipeline.sendPending()
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
            ForEach(Array(LectureRecorder.pieces(from: transcript).enumerated()), id: \.offset) { _, piece in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Button(Clock.string(piece.start)) { seek(piece.start) }
                        .font(.m(11, .semibold)).monospacedDigit().foregroundStyle(Theme.accent).buttonStyle(.plain)
                    Text(piece.text).font(.m(15)).foregroundStyle(Theme.text).textSelection(.enabled)
                }
            }
        }
    }
}

/// Plain-text version for sharing into a Claude chat by hand.
enum ClaudeExport {
    static func text(for lecture: Lecture) -> String {
        """
        # \(lecture.displayTitle)
        \(lecture.displayCourse.isEmpty ? "" : "Course: \(lecture.displayCourse)\n")Recorded: \(lecture.recordedAt.formatted(date: .complete, time: .shortened)) (\(Clock.string(lecture.durationSec)))

        This is an automatic on-device transcript of my class lecture, so expect some misheard words.
        Please turn it into study notes: the main ideas, key definitions and formulas, anything the professor said would be on an exam or homework, and a few practice questions.

        ## Transcript
        \(lecture.transcript)
        """
    }
}

/// Simple playback of the saved recording.
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
        guard !LectureRecorder.shared.isRecording else { return } // never steal the mic session
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

/// The recording as a nicely named .m4a for sharing ("Fluids 11-9 · Couette Flow.m4a").
enum AudioExport {
    @MainActor
    static func file(for lecture: Lecture) -> URL? {
        let name = lecture.displayTitle.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).m4a")
        try? FileManager.default.removeItem(at: url)
        do { try FileManager.default.copyItem(at: lecture.audioURL, to: url) } catch { return nil }
        return url
    }
}
