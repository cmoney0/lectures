import Foundation

// Compiled into the app, the widget extension AND the unit tests (no UI, no
// ActivityKit) so the Live Activity timing rules are tested on their own.
//
// Bug 2026-11-11 (Colby): the Lock Screen said "Recording stopped" while the
// app was still recording. The Live Activity went stale 90 s after the app's
// last refresh, and iOS doesn't promise a backgrounded app's Live Activity
// refreshes land on time with the phone locked - one late refresh looked like
// a crash. Crash alerts are the CrashWatchdog notification's job (scheduled
// locally, not throttled); the Live Activity only goes stale after a long
// silence and then says "no signal" instead of claiming it stopped.

enum LiveActivityPolicy {
    /// How often the recorder refreshes the Live Activity + crash notification.
    static let heartbeat: TimeInterval = 20
    /// The "Lectures stopped recording" notification fires this long after the
    /// last heartbeat (each heartbeat pushes it out again).
    static let crashNotificationAfter: TimeInterval = 75
    /// The Live Activity shows "no signal" only after this much silence.
    static let staleAfter: TimeInterval = 15 * 60
    /// The old window that caused the bug (kept for the regression test).
    static let legacyStaleAfter: TimeInterval = 90

    /// No stale date while paused (a paused app may be suspended - that's fine).
    static func staleDate(now: Date, paused: Bool, window: TimeInterval = staleAfter) -> Date? {
        paused ? nil : now.addingTimeInterval(window)
    }

    /// Would the Live Activity show stale at `now`, given the last refresh that landed?
    static func isStale(now: Date, lastRefresh: Date, paused: Bool, window: TimeInterval = staleAfter) -> Bool {
        guard let stale = staleDate(now: lastRefresh, paused: paused, window: window) else { return false }
        return now >= stale
    }

    /// Heartbeats that can be missed in a row before the Live Activity goes stale.
    static var missableHeartbeats: Int { Int(staleAfter / heartbeat) - 1 }
}

/// What the Lock Screen / Dynamic Island shows.
enum LiveActivityMode: Equatable {
    case recording, paused, noSignal

    init(paused: Bool, stale: Bool) {
        self = stale ? .noSignal : (paused ? .paused : .recording)
    }

    var label: String {
        switch self {
        case .recording: "Recording lecture"
        case .paused: "Paused"
        case .noSignal: "No signal from Lectures"
        }
    }

    var lockScreenText: String {
        self == .noSignal ? "No signal - open Lectures to check" : label
    }

    /// Pause / Stop only make sense while the app is answering.
    var showsControls: Bool { self != .noSignal }
}

/// Tracks the gaps between heartbeats during one recording (Settings > Diagnostics).
struct HeartbeatLog: Codable, Equatable {
    var beats = 0
    var last: Date?
    var maxGap: TimeInterval = 0
    var startedAt: Date?

    mutating func beat(at now: Date) {
        if let last { maxGap = max(maxGap, now.timeIntervalSince(last)) } else { startedAt = now }
        last = now
        beats += 1
    }

    /// A late heartbeat (well past the interval) - what iOS throttling looks like.
    func wasLate(tolerance: TimeInterval = LiveActivityPolicy.heartbeat * 2) -> Bool { maxGap > tolerance }
}
