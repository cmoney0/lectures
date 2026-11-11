import XCTest

/// Live Activity timing (bug 2026-11-11: Lock Screen said "Recording stopped"
/// while the app was still recording).
final class LiveActivityPolicyTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: stale date

    func testNoStaleDateWhilePaused() {
        XCTAssertNil(LiveActivityPolicy.staleDate(now: t0, paused: true))
    }

    func testStaleDateIsFifteenMinutesOutWhileRecording() {
        XCTAssertEqual(LiveActivityPolicy.staleDate(now: t0, paused: false), t0.addingTimeInterval(15 * 60))
    }

    func testPausedNeverGoesStale() {
        XCTAssertFalse(LiveActivityPolicy.isStale(now: t0.addingTimeInterval(3 * 3600), lastRefresh: t0, paused: true))
    }

    // MARK: the bug

    /// The real failure: one refresh lands ~2 min late with the phone locked.
    func testLateRefreshUsedToShowStoppedRegression() {
        let twoMinutesLater = t0.addingTimeInterval(120)
        XCTAssertTrue(LiveActivityPolicy.isStale(now: twoMinutesLater, lastRefresh: t0, paused: false,
                                                 window: LiveActivityPolicy.legacyStaleAfter),
                      "the old 90 s window shows 'stopped' after a 2-minute gap")
        XCTAssertFalse(LiveActivityPolicy.isStale(now: twoMinutesLater, lastRefresh: t0, paused: false),
                       "the new window must ride out a 2-minute gap")
    }

    func testLongLockedStretchesStayLive() {
        for gap in [60.0, 120, 300, 600, 14 * 60] {
            XCTAssertFalse(LiveActivityPolicy.isStale(now: t0.addingTimeInterval(gap), lastRefresh: t0, paused: false),
                           "\(Int(gap)) s without a refresh should not look stopped")
        }
    }

    func testRealSilenceEventuallyShowsNoSignal() {
        XCTAssertTrue(LiveActivityPolicy.isStale(now: t0.addingTimeInterval(15 * 60), lastRefresh: t0, paused: false))
        XCTAssertTrue(LiveActivityPolicy.isStale(now: t0.addingTimeInterval(3600), lastRefresh: t0, paused: false))
    }

    /// Simulates a 50-minute class where iOS delivers refreshes irregularly.
    func testIrregularRefreshesThroughAWholeClassNeverGoStale() {
        // on time for 5 min, then throttled to one every 4 min while locked, then on time again
        var refreshes: [TimeInterval] = stride(from: 0, through: 300, by: 20).map { $0 }
        refreshes += stride(from: 540, through: 2400, by: 240).map { $0 }
        refreshes += stride(from: 2420, through: 3000, by: 20).map { $0 }
        var last = t0
        var now = t0
        var index = 0
        while now <= t0.addingTimeInterval(3000) {
            while index < refreshes.count, t0.addingTimeInterval(refreshes[index]) <= now {
                last = t0.addingTimeInterval(refreshes[index]); index += 1
            }
            XCTAssertFalse(LiveActivityPolicy.isStale(now: now, lastRefresh: last, paused: false),
                           "stale at \(Int(now.timeIntervalSince(t0))) s")
            now = now.addingTimeInterval(10)
        }
    }

    // MARK: timing relationships

    func testManyHeartbeatsCanBeMissedBeforeStale() {
        XCTAssertGreaterThanOrEqual(LiveActivityPolicy.missableHeartbeats, 20)
    }

    func testCrashNotificationSurvivesOneLateHeartbeat() {
        XCTAssertGreaterThan(LiveActivityPolicy.crashNotificationAfter, LiveActivityPolicy.heartbeat * 2)
    }

    func testCrashNotificationComesLongBeforeNoSignal() {
        XCTAssertLessThan(LiveActivityPolicy.crashNotificationAfter * 4, LiveActivityPolicy.staleAfter)
    }

    // MARK: what the Lock Screen shows

    func testModes() {
        XCTAssertEqual(LiveActivityMode(paused: false, stale: false), .recording)
        XCTAssertEqual(LiveActivityMode(paused: true, stale: false), .paused)
        XCTAssertEqual(LiveActivityMode(paused: false, stale: true), .noSignal)
        XCTAssertEqual(LiveActivityMode(paused: true, stale: true), .noSignal)
    }

    func testNoSignalNeverClaimsTheRecordingStopped() {
        for mode in [LiveActivityMode.recording, .paused, .noSignal] {
            XCTAssertFalse(mode.lockScreenText.lowercased().contains("stopped"), "\(mode) says stopped")
        }
    }

    func testControlsHiddenOnlyWithoutSignal() {
        XCTAssertTrue(LiveActivityMode.recording.showsControls)
        XCTAssertTrue(LiveActivityMode.paused.showsControls)
        XCTAssertFalse(LiveActivityMode.noSignal.showsControls)
    }

    // MARK: heartbeat log (Settings > Diagnostics)

    func testHeartbeatLogTracksLongestGap() {
        var log = HeartbeatLog()
        log.beat(at: t0)
        XCTAssertEqual(log.maxGap, 0)
        log.beat(at: t0.addingTimeInterval(20))
        log.beat(at: t0.addingTimeInterval(200))
        log.beat(at: t0.addingTimeInterval(220))
        XCTAssertEqual(log.beats, 4)
        XCTAssertEqual(log.maxGap, 180)
        XCTAssertEqual(log.startedAt, t0)
        XCTAssertTrue(log.wasLate())
    }

    func testOnTimeHeartbeatsAreNotLate() {
        var log = HeartbeatLog()
        for i in 0..<30 { log.beat(at: t0.addingTimeInterval(Double(i) * 20)) }
        XCTAssertFalse(log.wasLate())
    }

    func testHeartbeatLogRoundTripsThroughJSON() throws {
        var log = HeartbeatLog()
        log.beat(at: t0); log.beat(at: t0.addingTimeInterval(45))
        let back = try JSONDecoder().decode(HeartbeatLog.self, from: JSONEncoder().encode(log))
        XCTAssertEqual(back, log)
    }
}
