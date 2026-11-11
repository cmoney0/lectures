import ActivityKit
import AppIntents
import SwiftUI

// Compiled into BOTH the app and the widget extension. The intents' work only
// exists in the app (LECTURES_APP); iOS runs Live Activity buttons and
// open-app intents in the app's process, so the extension copies are stubs.

struct LectureActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// Wall-clock time the timer counts from (now - elapsed when last resumed).
        var startedAt: Date
        /// Set while paused: the frozen elapsed seconds.
        var pausedElapsed: Double?
        /// Latest finalized transcript line.
        var lastLine: String
        /// Set only by LifeOS (APNs push) when the app went silent: the
        /// recording really stopped. The app itself never sets it.
        var lost: Bool?
    }

    var title: String
    /// Which lecture this is (to tell LifeOS a leftover activity ended).
    var lectureId: String?
}

enum LectureColors {
    static let accent = Color(red: 0xC9 / 255, green: 0x64 / 255, blue: 0x42 / 255)
    static let red = Color(red: 0xD9 / 255, green: 0x53 / 255, blue: 0x4F / 255)
    static let bg = Color(red: 0x26 / 255, green: 0x26 / 255, blue: 0x24 / 255)
    static let text = Color(red: 0xF0 / 255, green: 0xEF / 255, blue: 0xE9 / 255)
    static let sub = Color(red: 0xA6 / 255, green: 0xA4 / 255, blue: 0x9B / 255)
}

/// Start recording: Control Center / Lock Screen control, Action Button, Siri.
struct StartLectureIntent: AppIntent {
    static let title: LocalizedStringResource = "Record lecture"
    static let description = IntentDescription("Starts recording and transcribing a lecture.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        #if LECTURES_APP
        await LectureRecorder.shared.start()
        #endif
        return .result()
    }
}

/// Lock Screen / Dynamic Island pause-resume button.
struct PauseLectureIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Pause or resume recording"

    @MainActor
    func perform() async throws -> some IntentResult {
        #if LECTURES_APP
        LectureRecorder.shared.togglePause()
        #endif
        return .result()
    }
}

/// Lock Screen / Dynamic Island stop button: stops and sends to Claude with
/// the saved review options.
struct StopLectureIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop recording"

    @MainActor
    func perform() async throws -> some IntentResult {
        #if LECTURES_APP
        await LectureRecorder.shared.stop(askForOptions: false)
        #endif
        return .result()
    }
}
