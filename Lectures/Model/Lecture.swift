import Foundation
import SwiftData

/// One recorded class. The audio stays on the phone (Documents/Recordings);
/// the transcript also goes to LifeOS so the School Claude project can read it.
@Model
final class Lecture {
    @Attribute(.unique) var id: UUID
    var title: String
    var courseId: String?
    var courseName: String
    var recordedAt: Date
    var durationSec: Double
    var audioFileName: String
    /// Timestamped plain text: one "[mm:ss] sentence" line per finalized result.
    var transcript: String
    var statusRaw: String
    /// Which engine produced the transcript ("on-device" today; room for an
    /// external engine later without a data migration).
    var engine: String
    var uploadedAt: Date?
    var uploadError: String?
    /// Filled later by the review-guide pipeline (LifeOS / Claude).
    var reviewGuide: String?

    init(title: String, courseId: String?, courseName: String, recordedAt: Date = .now) {
        let id = UUID()
        self.id = id
        self.title = title
        self.courseId = courseId
        self.courseName = courseName
        self.recordedAt = recordedAt
        self.durationSec = 0
        self.audioFileName = "\(id.uuidString).m4a"
        self.transcript = ""
        self.statusRaw = LectureStatus.recording.rawValue
        self.engine = "on-device"
    }

    var status: LectureStatus {
        get { LectureStatus(rawValue: statusRaw) ?? .ready }
        set { statusRaw = newValue.rawValue }
    }

    var audioURL: URL { Storage.recordings.appendingPathComponent(audioFileName) }

    var hasAudio: Bool { FileManager.default.fileExists(atPath: audioURL.path) }

    /// Needs (re)sending: never sent, or edited since the last send.
    var needsUpload: Bool { status == .ready && uploadedAt == nil }

    var wordCount: Int { transcript.split(whereSeparator: { $0 == " " || $0 == "\n" }).count }

    /// The transcript without "[mm:ss]" markers, for reading and sharing.
    var plainTranscript: String {
        transcript.split(separator: "\n").map { line -> String in
            if line.hasPrefix("["), let close = line.firstIndex(of: "]") {
                return String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            }
            return String(line)
        }.joined(separator: " ")
    }
}

enum LectureStatus: String {
    case recording, transcribing, ready, failed
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
}
