import Foundation

// Compiled into the app, the widget extension AND the unit tests (no UI, no
// ActivityKit) so the Live Activity rules are tested on their own.
//
// Bug 2026-11-11 (Colby): the Lock Screen said "Recording stopped" while the
// app was still recording, and no crash notification came - so the app was
// alive; its Live Activity refreshes just weren't landing while the phone was
// locked, and a 90 s stale date turned that into "stopped".
//
// Design now: the app never uses a stale date. It updates the Live Activity on
// real changes (start / pause / resume / stop) and heartbeats LifeOS every
// 20 s. Only LifeOS decides "stopped": after 75 s of silence it pushes the Live
// Activity (APNs) with `lost = true`. A dead app can't update its own Live
// Activity, but a push always can. The local "Lectures stopped recording"
// notification stays as the offline backup.

enum LiveActivityPolicy {
    /// App -> LifeOS heartbeat while recording, and the crash notification re-arm.
    static let heartbeat: TimeInterval = 20
    /// The local "Lectures stopped recording" notification fires this long after the last heartbeat.
    static let crashNotificationAfter: TimeInterval = 75
    /// LifeOS marks the recording lost after this much silence (api/_lectures.js LOST_AFTER_MS).
    static let serverLostAfter: TimeInterval = 75
    /// The old local stale window that caused the bug (kept for the regression test).
    static let legacyStaleAfter: TimeInterval = 90

    /// The app never sets a stale date - a late local refresh can't flip the Lock Screen.
    static func staleDate(now: Date, paused: Bool) -> Date? { nil }

    /// The old rule, for the regression test only.
    static func legacyIsStale(now: Date, lastRefresh: Date) -> Bool {
        now >= lastRefresh.addingTimeInterval(legacyStaleAfter)
    }

    /// Would LifeOS call this recording lost at `now`, given the last heartbeat that reached it?
    static func serverCallsLost(now: Date, lastBeat: Date, paused: Bool) -> Bool {
        !paused && now.timeIntervalSince(lastBeat) > serverLostAfter
    }
}

/// What the Lock Screen / Dynamic Island shows.
enum LiveActivityMode: Equatable {
    case recording, paused, stopped, saving, saved

    /// `lost` comes only from LifeOS; `stale` (the system's flag) is ignored on purpose.
    /// `stopping` / `saved` come from the app right after Stop is tapped.
    init(paused: Bool, lost: Bool, stopping: Bool = false, saved: Bool = false) {
        if saved { self = .saved }
        else if stopping { self = .saving }
        else { self = lost ? .stopped : (paused ? .paused : .recording) }
    }

    var label: String {
        switch self {
        case .recording: "Recording lecture"
        case .paused: "Paused"
        case .stopped: "Recording stopped"
        case .saving: "Saving lecture..."
        case .saved: "Saved"
        }
    }

    var lockScreenText: String {
        switch self {
        case .stopped: "Recording stopped - tap to resume"
        case .saved: "Saved - sending to Claude"
        default: label
        }
    }

    /// Pause / Stop only make sense while recording (Stop stays while saving, mid-pulse).
    var showsControls: Bool { self == .recording || self == .paused || self == .saving }
}

/// Heartbeats to LifeOS during one recording (Settings > Last recording).
struct HeartbeatLog: Codable, Equatable {
    var beats = 0
    var delivered = 0
    var last: Date?
    var maxGap: TimeInterval = 0
    var startedAt: Date?

    /// One heartbeat attempt; `delivered` = LifeOS answered.
    mutating func beat(at now: Date, delivered ok: Bool = true) {
        if let last { maxGap = max(maxGap, now.timeIntervalSince(last)) } else { startedAt = now }
        last = now
        beats += 1
        if ok { delivered += 1 }
    }

    /// A heartbeat ran well past its interval (iOS held the app back).
    func wasLate(tolerance: TimeInterval = LiveActivityPolicy.heartbeat * 2) -> Bool { maxGap > tolerance }
    /// Late enough that LifeOS would have called it lost (it heals on the next beat).
    var wouldLookLost: Bool { maxGap > LiveActivityPolicy.serverLostAfter }
}
