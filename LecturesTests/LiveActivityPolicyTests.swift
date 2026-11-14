import XCTest

/// Live Activity rules (bug 2026-11-11: the Lock Screen said "Recording stopped"
/// while the app was still recording, and no crash notification came).
final class LiveActivityPolicyTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: the bug

    /// The real failure: refreshes stop landing for ~2 min with the phone locked.
    func testOldRuleShowedStoppedWhileRecordingRegression() {
        XCTAssertTrue(LiveActivityPolicy.legacyIsStale(now: t0.addingTimeInterval(120), lastRefresh: t0),
                      "the old 90 s stale date flipped to 'stopped' with the app still recording")
    }

    func testAppNeverSetsAStaleDate() {
        XCTAssertNil(LiveActivityPolicy.staleDate(now: t0, paused: false))
        XCTAssertNil(LiveActivityPolicy.staleDate(now: t0, paused: true))
    }

    func testSystemStaleFlagCanNeverSayStopped() {
        // only `lost` (LifeOS's push) maps to stopped; there is no stale input at all
        XCTAssertEqual(LiveActivityMode(paused: false, lost: false), .recording)
        XCTAssertEqual(LiveActivityMode(paused: true, lost: false), .paused)
    }

    /// A whole 50-minute class where local Live Activity refreshes never land:
    /// the Lock Screen stays "Recording" because nothing local can flip it.
    func testLocalRefreshesNotLandingNeverShowStopped() {
        let state = LectureActivityAttributes.ContentState(startedAt: t0, pausedElapsed: nil, lastLine: "", lost: nil)
        for minute in stride(from: 0, through: 50, by: 1) {
            _ = minute
            XCTAssertEqual(LiveActivityMode(paused: state.pausedElapsed != nil, lost: state.lost == true), .recording)
        }
    }

    // MARK: LifeOS's dead-man switch

    func testServerCallsLostOnlyAfter75sOfSilence() {
        XCTAssertFalse(LiveActivityPolicy.serverCallsLost(now: t0.addingTimeInterval(20), lastBeat: t0, paused: false))
        XCTAssertFalse(LiveActivityPolicy.serverCallsLost(now: t0.addingTimeInterval(60), lastBeat: t0, paused: false))
        XCTAssertTrue(LiveActivityPolicy.serverCallsLost(now: t0.addingTimeInterval(80), lastBeat: t0, paused: false))
    }

    func testPausedIsNeverLost() {
        XCTAssertFalse(LiveActivityPolicy.serverCallsLost(now: t0.addingTimeInterval(3 * 3600), lastBeat: t0, paused: true))
    }

    func testOneMissedHeartbeatIsNotLost() {
        // beats at 0 and 40 (the 20 s one went missing): never more than 40 s of silence
        XCTAssertFalse(LiveActivityPolicy.serverCallsLost(now: t0.addingTimeInterval(40), lastBeat: t0, paused: false))
        XCTAssertGreaterThan(LiveActivityPolicy.serverLostAfter, LiveActivityPolicy.heartbeat * 3)
    }

    func testCrashNotificationSurvivesOneLateHeartbeat() {
        XCTAssertGreaterThan(LiveActivityPolicy.crashNotificationAfter, LiveActivityPolicy.heartbeat * 2)
    }

    func testServerMatchesTheAppsTiming() {
        // api/_lectures.js LOST_AFTER_MS = 75_000
        XCTAssertEqual(LiveActivityPolicy.serverLostAfter, 75)
    }

    // MARK: the push LifeOS sends

    /// LifeOS sends dates as seconds since 2001 (APPLE_EPOCH) - the push must decode.
    func testLifeOSStoppedPushDecodes() throws {
        let json = #"{"startedAt": 784893600, "lastLine": "", "lost": true}"#
        let state = try JSONDecoder().decode(LectureActivityAttributes.ContentState.self, from: Data(json.utf8))
        XCTAssertEqual(state.lost, true)
        XCTAssertNil(state.pausedElapsed)
        XCTAssertEqual(state.startedAt, Date(timeIntervalSinceReferenceDate: 784_893_600))
        XCTAssertEqual(LiveActivityMode(paused: state.pausedElapsed != nil, lost: state.lost == true), .stopped)
    }

    func testLifeOSHealPushDecodes() throws {
        let json = #"{"startedAt": 784893600, "lastLine": "", "lost": false}"#
        let state = try JSONDecoder().decode(LectureActivityAttributes.ContentState.self, from: Data(json.utf8))
        XCTAssertEqual(LiveActivityMode(paused: state.pausedElapsed != nil, lost: state.lost == true), .recording)
    }

    func testHealPushWhilePausedShowsPaused() throws {
        let json = #"{"startedAt": 784893600, "pausedElapsed": 0, "lastLine": "", "lost": false}"#
        let state = try JSONDecoder().decode(LectureActivityAttributes.ContentState.self, from: Data(json.utf8))
        XCTAssertEqual(LiveActivityMode(paused: state.pausedElapsed != nil, lost: state.lost == true), .paused)
    }

    func testOldStateWithoutLostStillDecodes() throws {
        let json = #"{"startedAt": 784893600, "lastLine": "hello"}"#
        let state = try JSONDecoder().decode(LectureActivityAttributes.ContentState.self, from: Data(json.utf8))
        XCTAssertNil(state.lost)
        XCTAssertEqual(LiveActivityMode(paused: false, lost: state.lost == true), .recording)
    }

    // MARK: what the Lock Screen shows

    func testOnlyStoppedSaysStopped() {
        XCTAssertFalse(LiveActivityMode.recording.lockScreenText.lowercased().contains("stopped"))
        XCTAssertFalse(LiveActivityMode.paused.lockScreenText.lowercased().contains("stopped"))
        XCTAssertTrue(LiveActivityMode.stopped.lockScreenText.contains("Recording stopped"))
    }

    func testControlsHiddenOnlyWhenStopped() {
        XCTAssertTrue(LiveActivityMode.recording.showsControls)
        XCTAssertTrue(LiveActivityMode.paused.showsControls)
        XCTAssertFalse(LiveActivityMode.stopped.showsControls)
    }

    // MARK: heartbeat log (Settings > Last recording)

    func testHeartbeatLogTracksGapsAndDelivery() {
        var log = HeartbeatLog()
        log.beat(at: t0)
        log.beat(at: t0.addingTimeInterval(20))
        log.beat(at: t0.addingTimeInterval(120), delivered: false)
        log.beat(at: t0.addingTimeInterval(140))
        XCTAssertEqual(log.beats, 4)
        XCTAssertEqual(log.delivered, 3)
        XCTAssertEqual(log.maxGap, 100)
        XCTAssertEqual(log.startedAt, t0)
        XCTAssertTrue(log.wasLate())
        XCTAssertTrue(log.wouldLookLost)
    }

    func testOnTimeHeartbeatsAreFine() {
        var log = HeartbeatLog()
        for i in 0..<150 { log.beat(at: t0.addingTimeInterval(Double(i) * 20)) }
        XCTAssertFalse(log.wasLate())
        XCTAssertFalse(log.wouldLookLost)
        XCTAssertEqual(log.delivered, 150)
    }

    func testHeartbeatLogRoundTripsThroughJSON() throws {
        var log = HeartbeatLog()
        log.beat(at: t0); log.beat(at: t0.addingTimeInterval(45), delivered: false)
        let back = try JSONDecoder().decode(HeartbeatLog.self, from: JSONEncoder().encode(log))
        XCTAssertEqual(back, log)
    }

    // MARK: tap feedback (2026-11-14)

    func testTapStepOnlyForTheTappedButton() {
        let tap: LectureTap? = LectureTap(key: "pause", step: 1)
        XCTAssertEqual(tap.step("pause"), 1)
        XCTAssertNil(tap.step("stop"))
        let none: LectureTap? = nil
        XCTAssertNil(none.step("pause"))
    }

    func testTapAnimationRunsRingOnRingAwayIdleAndIsQuick() {
        XCTAssertEqual(LectureTapAnim.plan.map(\.step), [1, 2, nil])
        XCTAssertLessThan(LectureTapAnim.totalMs, 2_000, "the pulse must feel instant, not hold Stop up")
        XCTAssertLessThan(LectureTapAnim.plan.first!.ms, 400, "the ring starts right after the bloom")
    }

    func testTapAnimationStopsWhenANewerTapReplacesIt() async {
        var seen: [Int?] = []
        await LectureTapAnim.play { step in
            seen.append(step)
            return false   // a newer tap took over
        }
        XCTAssertEqual(seen.count, 1)
    }

    func testStopShowsSavingThenSaved() {
        XCTAssertEqual(LiveActivityMode(paused: false, lost: false, stopping: true), .saving)
        XCTAssertEqual(LiveActivityMode(paused: false, lost: false, stopping: true, saved: true), .saved)
        XCTAssertTrue(LiveActivityMode.saving.showsControls, "Stop keeps its pulse while saving")
        XCTAssertFalse(LiveActivityMode.saved.showsControls)
        XCTAssertEqual(LiveActivityMode.saved.lockScreenText, "Saved - sending to Claude")
    }

    func testTapStateRoundTripsAndOldStatesStillDecode() throws {
        var state = LectureActivityAttributes.ContentState(startedAt: t0, pausedElapsed: nil, lastLine: "", lost: nil)
        state.tap = LectureTap(key: "stop", step: 0)
        state.stopping = true
        let back = try JSONDecoder().decode(LectureActivityAttributes.ContentState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(back, state)
        let old = #"{"startedAt": 784893600, "lastLine": ""}"#
        let decoded = try JSONDecoder().decode(LectureActivityAttributes.ContentState.self, from: Data(old.utf8))
        XCTAssertNil(decoded.tap)
        XCTAssertNil(decoded.stopping)
    }
}
