import XCTest
@testable import PopNotch

/// The open panel's live poll: three properties, one clock, hard rule 9.
///
/// What is testable here is the lifecycle — the clock exists only between
/// `didBecomeVisible` and `didResignVisible` and stops for display sleep —
/// and the parse. The Apple Event itself is not exercised: the tick reaches
/// `SpotifyAdapter.refreshLive()` only when a real `SpotifyAdapter` owns the
/// notch, and none does under XCTest.
@MainActor
final class LiveSyncTests: XCTestCase {

    // MARK: - Parse

    func testParsesThreeLines() {
        let live = SpotifyAdapter.parseLive("12.5\nfalse\ntrue")
        XCTAssertEqual(live?.position, 12.5)
        XCTAssertEqual(live?.shuffling, false)
        XCTAssertEqual(live?.repeating, true)
    }

    /// AppleScript renders reals with the locale's decimal separator.
    func testAcceptsCommaDecimal() {
        XCTAssertEqual(SpotifyAdapter.parseLive("12,5\ntrue\nfalse")?.position, 12.5)
    }

    func testToleratesWhitespace() {
        XCTAssertEqual(SpotifyAdapter.parseLive(" 3.0 \n true \n false ")?.shuffling, true)
    }

    /// Anything short or malformed is nil — the caller keeps the last state it
    /// actually read rather than inventing a position or a mode.
    func testRejectsMalformedOutput() {
        for bad in ["stopped", "", "12.5\nfalse", "abc\ntrue\nfalse",
                    "12.5\nyes\nno", "12.5\ntrue\n", "missing value\ntrue\nfalse"] {
            XCTAssertNil(SpotifyAdapter.parseLive(bad), "\(bad.debugDescription) must not parse")
        }
    }

    // MARK: - Lifecycle (hard rule 9)

    func testIntervalIsTwoSeconds() {
        XCTAssertEqual(MediaModule.liveSyncInterval, 2)
    }

    func testNotSyncingBeforeVisible() {
        let module = MediaModule(sources: [StubMediaSource(id: "spotify", running: true)])
        XCTAssertFalse(module.isLiveSyncing)
    }

    func testBecomingVisibleStartsTheClock() {
        let module = MediaModule(sources: [StubMediaSource(id: "spotify", running: true)])
        module.didBecomeVisible()
        XCTAssertTrue(module.isLiveSyncing)
        module.didResignVisible()
    }

    func testResigningVisibleStopsTheClock() {
        let module = MediaModule(sources: [StubMediaSource(id: "spotify", running: true)])
        module.didBecomeVisible()
        module.didResignVisible()
        XCTAssertFalse(module.isLiveSyncing, "nothing polls while the panel is closed")
    }

    /// Five open/close cycles must leave exactly nothing running — the
    /// balance failure hard rule 9 exists to catch.
    func testRepeatedCyclesLeaveNothingRunning() {
        let module = MediaModule(sources: [StubMediaSource(id: "spotify", running: true)])
        for _ in 0..<5 {
            module.didBecomeVisible()
            XCTAssertTrue(module.isLiveSyncing)
            module.didResignVisible()
            XCTAssertFalse(module.isLiveSyncing)
        }
    }

    func testBecomingVisibleTwiceDoesNotStackTimers() {
        let module = MediaModule(sources: [StubMediaSource(id: "spotify", running: true)])
        module.didBecomeVisible()
        module.didBecomeVisible()
        XCTAssertTrue(module.isLiveSyncing)
        module.didResignVisible()
        XCTAssertFalse(module.isLiveSyncing, "one resign must undo any number of becomes")
    }

    /// The clause the spec did not name but the rule does: a pinned-open panel
    /// under a sleeping display must not keep waking Spotify every two seconds.
    func testDisplaySleepStopsTheClockAndWakeRestartsIt() {
        let module = MediaModule(sources: [StubMediaSource(id: "spotify", running: true)])
        module.didBecomeVisible()
        XCTAssertTrue(module.isLiveSyncing)

        let center = NSWorkspace.shared.notificationCenter
        center.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        XCTAssertFalse(module.isLiveSyncing, "asleep: stopped even though still visible")

        center.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        XCTAssertTrue(module.isLiveSyncing, "awake and still visible: running again")

        module.didResignVisible()
        XCTAssertFalse(module.isLiveSyncing)
    }

    /// Waking must not start a clock the panel never asked for.
    func testWakeAloneDoesNotStartTheClock() {
        let module = MediaModule(sources: [StubMediaSource(id: "spotify", running: true)])
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        XCTAssertFalse(module.isLiveSyncing)
    }
}
