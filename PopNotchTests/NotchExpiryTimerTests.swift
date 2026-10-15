import XCTest
@testable import PopNotch

/// The coordinator's one-shot expiry timer, driven through a real
/// `NotchCoordinator` with no screen and no panel. The arbiter runs on a
/// hand-cranked clock; the timer itself is real, so durations are long
/// enough that none fires during a test unless the test means it to.
@MainActor
final class NotchExpiryTimerTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!
    private var clock: TestClock!
    private var arbiter: NotchArbiter!
    private var coordinator: NotchCoordinator!

    override func setUp() {
        super.setUp()
        suiteName = "com.techie.PopNotch.expirytests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        clock = TestClock()
        arbiter = NotchArbiter(now: clock.read)
        coordinator = NotchCoordinator(settings: SettingsStore(defaults: defaults), arbiter: arbiter)
    }

    override func tearDown() {
        coordinator.stop()
        coordinator = nil
        arbiter = nil
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func secondsUntilFire() -> TimeInterval? {
        coordinator.expiryFireDate.map { $0.timeIntervalSinceNow }
    }

    func testNoTimerAtRest() {
        coordinator.register(StubModule(id: "media", priority: .elevated))
        XCTAssertNil(coordinator.expiryFireDate, "hard rule 9: nothing scheduled while idle")
    }

    func testAnActivityHasATimerBehindIt() {
        let media = StubModule(id: "media", priority: .elevated)
        coordinator.register(media)
        coordinator.requestLiveActivity(media.activity(duration: 60))
        XCTAssertEqual(secondsUntilFire() ?? -1, 60, accuracy: 1)
    }

    /// Scenario A at the coordinator: a refresh keeps the presentation the
    /// same, and the timer must still move to the new expiry.
    func testRefreshingTheActiveActivityMovesTheTimer() {
        let media = StubModule(id: "media", priority: .elevated)
        coordinator.register(media)
        coordinator.requestLiveActivity(media.activity(duration: 60))
        coordinator.requestLiveActivity(media.activity(duration: 300))
        XCTAssertEqual(secondsUntilFire() ?? -1, 300, accuracy: 1)
    }

    /// Scenario B at the coordinator: a module preempting itself.
    func testSelfPreemptionMovesTheTimer() {
        let media = StubModule(id: "media", priority: .elevated)
        coordinator.register(media)
        coordinator.requestLiveActivity(media.activity(priority: .standard, duration: 60))
        coordinator.requestLiveActivity(media.activity(priority: .elevated, duration: 300))
        XCTAssertEqual(secondsUntilFire() ?? -1, 300, accuracy: 1)
    }

    func testTimerIsRescheduledWhenTickPromotesAQueuedRequest() {
        let a = StubModule(id: "a", priority: .standard)
        let b = StubModule(id: "b", priority: .standard)
        coordinator.register(a)
        coordinator.register(b)
        coordinator.requestLiveActivity(a.activity(duration: 60))
        coordinator.requestLiveActivity(b.activity(duration: 300))
        XCTAssertEqual(secondsUntilFire() ?? -1, 60, accuracy: 1)

        clock.advance(by: 60)
        arbiter.tick()
        XCTAssertEqual(arbiter.presentation, .liveActivity("b"))
        XCTAssertEqual(secondsUntilFire() ?? -1, 300, accuracy: 1,
                       "the promoted activity must get its own timer")

        clock.advance(by: 300)
        arbiter.tick()
        XCTAssertNil(coordinator.expiryFireDate, "and none once the notch is idle")
    }

    /// `scheduledTimer` used the default run-loop mode only, which does not
    /// run while a menu is tracking. Spinning the loop in `.eventTracking`
    /// alone proves the timer is in `.common` modes.
    func testTimerFiresWhileAMenuIsTracking() {
        let media = StubModule(id: "media", priority: .elevated)
        coordinator.register(media)
        coordinator.requestLiveActivity(media.activity(duration: 0.05))
        clock.advance(by: 1)

        let deadline = Date().addingTimeInterval(2)
        while arbiter.presentation != .standby(["media"]), Date() < deadline {
            RunLoop.main.run(mode: .eventTracking, before: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(arbiter.presentation, .standby(["media"]))
        XCTAssertNil(coordinator.expiryFireDate)
    }
}
