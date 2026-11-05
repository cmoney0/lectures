import Foundation
import SwiftData

/// One recorded class. Audio stays on the phone; the transcript goes to LifeOS,
/// where the Lectures - Reviewer Claude session writes the review back.
@Model
final class Lecture {
    @Attribute(.unique) var id: UUID
    var title: String
    /// Filled in by Claude from the transcript (the app never asks).
    var courseName: String
    var courseId: String?
    var recordedAt: Date
    var durationSec: Double
    /// Timestamped plain text: one "[m:ss] sentence" line per finalized result.
    var transcript: String
    var statusRaw: String
    /// "on-device" today; room for an external engine later.
    var engine: String
    var uploadedAt: Date?
    var uploadError: String?
    /// Ask LifeOS for a review on the next upload.
    var reviewPending: Bool
    var reviewOptionsJSON: String?
    /// Mirrors the server: none | requested | working | ready | failed
    var reviewStatusRaw: String
    var reviewJSON: String?
    var reviewError: String?

    init(title: String, recordedAt: Date = .now) {
        id = UUID()
        self.title = title
        courseName = ""
        self.recordedAt = recordedAt
        durationSec = 0
        transcript = ""
        statusRaw = LectureStatus.recording.rawValue
        engine = "on-device"
        reviewPending = false
        reviewStatusRaw = ReviewStatus.none.rawValue
    }

    var status: LectureStatus {
        get { LectureStatus(rawValue: statusRaw) ?? .ready }
        set { statusRaw = newValue.rawValue }
    }

    var reviewStatus: ReviewStatus {
        get { ReviewStatus(rawValue: reviewStatusRaw) ?? .none }
        set { reviewStatusRaw = newValue.rawValue }
    }

    var review: LectureReview? {
        guard let reviewJSON, let data = reviewJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(LectureReview.self, from: data)
    }

    var reviewOptions: ReviewOptions? {
        guard let reviewOptionsJSON, let data = reviewOptionsJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ReviewOptions.self, from: data)
    }

    /// Headline: Claude's topic title once the review exists.
    var displayTitle: String {
        if let t = review?.title, !t.isEmpty { return t }
        return title.isEmpty ? "Lecture" : title
    }

    var displayCourse: String {
        if !courseName.isEmpty { return courseName }
        if let c = review?.course, !c.isEmpty { return c }
        return ""
    }

    // MARK: audio files

    /// Chunks are written while recording (a crash loses at most one chunk);
    /// they are merged into `audioURL` when the recording ends.
    var chunkFolder: URL { Storage.recordings.appendingPathComponent(id.uuidString, isDirectory: true) }
    var audioURL: URL { Storage.recordings.appendingPathComponent("\(id.uuidString).m4a") }
    var hasAudio: Bool { FileManager.default.fileExists(atPath: audioURL.path) }

    var wordCount: Int { transcript.split(whereSeparator: { $0 == " " || $0 == "\n" }).count }

    // MARK: the pipeline shown on the home page

    var stage: Stage {
        switch status {
        case .recording: return .recording
        case .interrupted: return .interrupted
        case .finishing: return .transcribing
        case .failed: return .failed
        case .ready: break
        }
        if reviewPending { return .sending }
        switch reviewStatus {
        case .none: return .saved
        case .requested: return .sent
        case .working: return .reviewing
        case .ready: return .done
        case .failed: return .reviewFailed
        }
    }
}

enum LectureStatus: String {
    case recording, finishing, interrupted, ready, failed
}

enum ReviewStatus: String {
    case none, requested, working, ready, failed
}

enum Stage {
    case recording, interrupted, transcribing, sending, saved, sent, reviewing, done, failed, reviewFailed

    /// 0 Recorded, 1 Transcribed, 2 Sent to Claude, 3 Review ready
    var step: Int {
        switch self {
        case .recording, .interrupted, .failed: 0
        case .transcribing: 1
        case .sending, .saved: 2
        case .sent, .reviewing, .reviewFailed: 3
        case .done: 4
        }
    }

    var label: String {
        switch self {
        case .recording: "Recording"
        case .interrupted: "Recording stopped unexpectedly"
        case .transcribing: "Finishing transcript"
        case .sending: "Sending to Claude"
        case .saved: "Saved - no review requested"
        case .sent: "Waiting for Claude"
        case .reviewing: "Claude is writing your review"
        case .done: "Review ready"
        case .failed: "Couldn't save this recording"
        case .reviewFailed: "Review failed"
        }
    }

    var isWorking: Bool { [.transcribing, .sending, .sent, .reviewing].contains(self) }
}

/// What Colby picks after Stop; saved as the default for next time.
struct ReviewOptions: Codable, Equatable {
    var length = "standard"   // quick | standard | deep
    var type = "notes"        // notes | exam | flashcards | summary
    var focus = ""

    static var saved: ReviewOptions {
        get {
            guard let data = UserDefaults.standard.data(forKey: "reviewOptions"),
                  let o = try? JSONDecoder().decode(ReviewOptions.self, from: data) else { return ReviewOptions() }
            return ReviewOptions(length: o.length, type: o.type, focus: "")
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "reviewOptions") }
    }

    var json: String { String(data: (try? JSONEncoder().encode(self)) ?? Data(), encoding: .utf8) ?? "{}" }

    static let lengths: [(String, String)] = [("quick", "Quick"), ("standard", "Standard"), ("deep", "Deep")]
    static let types: [(String, String, String)] = [
        ("notes", "Study notes", "note.text"),
        ("exam", "Exam prep", "graduationcap"),
        ("flashcards", "Flashcards + quiz", "rectangle.on.rectangle"),
        ("summary", "Summary", "text.alignleft"),
    ]
}

/// The review the Reviewer session writes (REVIEWER.md). Everything optional
/// so a partial review still shows.
struct LectureReview: Codable {
    struct Section: Codable, Hashable { var heading: String?; var points: [String]? }
    struct Term: Codable, Hashable { var term: String?; var definition: String? }
    struct Flag: Codable, Hashable { var text: String?; var at: String? }
    struct Card: Codable, Hashable { var front: String?; var back: String? }
    struct Question: Codable, Hashable { var question: String?; var choices: [String]?; var answer: Int?; var explanation: String? }

    var title: String?
    var course: String?
    var summary: String?
    var sections: [Section]?
    var keyTerms: [Term]?
    var examFlags: [Flag]?
    var flashcards: [Card]?
    var quiz: [Question]?
    var followUps: [String]?
}

struct TranscriptPiece: Sendable {
    var start: Double
    var text: String
}

enum Storage {
    static let recordings: URL = {
        let dir = URL.documentsDirectory.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
}

enum Clock {
    /// 75 -> "1:15", 4510 -> "1:15:10"
    static func string(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    static func marker(_ seconds: Double) -> String { "[\(string(seconds))]" }

    /// "1:02:03" -> 3723
    static func seconds(_ stamp: String) -> Double? {
        let parts = stamp.split(separator: ":").compactMap { Double($0) }
        return parts.isEmpty ? nil : parts.reduce(0) { $0 * 60 + $1 }
    }
}
