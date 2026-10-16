import XCTest
@testable import PopNotch

/// The update notice's logic, with Sparkle out of the loop: the service's
/// state is driven by the same methods its delegate callbacks call.
@MainActor
final class UpdateModuleTests: XCTestCase {

    private var service: UpdateService!
    private var module: UpdateModule!
    private var requests: [LiveActivityRequest] = []
    private var presenceChanges = 0

    override func setUp() {
        super.setUp()
        service = UpdateService(currentVersion: "1.3.0")
        module = UpdateModule(service: service)
        requests = []
        presenceChanges = 0
        module.onLiveActivityRequest = { [weak self] in self?.requests.append($0) }
        module.onPresenceChange = { [weak self] in self?.presenceChanges += 1 }
    }

    // MARK: - Nothing pending

    func testNothingPendingDrawsNothing() {
        XCTAssertNil(service.availableVersion)
        XCTAssertNil(module.makeCompactLeadingView(), "no wings without an update")
        XCTAssertNil(module.makeCompactTrailingView())
        XCTAssertFalse(module.hasExpandedContent, "the card is dropped from the stack")
        XCTAssertTrue(module.wantsCompactDisplay, "but it stays in standby, so a find can put the wings up")
    }

    // MARK: - A found update

    func testAFoundUpdatePutsTheWingsUpAndAsksForTheNotchOnce() {
        service.noteUpdateAvailable("1.4.0")

        XCTAssertEqual(service.availableVersion, "1.4.0")
        XCTAssertNotNil(module.makeCompactLeadingView())
        XCTAssertNotNil(module.makeCompactTrailingView())
        XCTAssertTrue(module.hasExpandedContent)
        XCTAssertEqual(presenceChanges, 1, "the coordinator is told to re-render the wings")
        XCTAssertEqual(requests.count, 1, "one live activity opens the notch on the notice")
        XCTAssertEqual(requests.first?.moduleID, "updates")
        XCTAssertEqual(requests.first?.priority, .standard)
        XCTAssertEqual(requests.first?.duration, UpdateModule.noticeDuration)
    }

    /// Sparkle re-reports a pending update on every scheduled cycle it finds
    /// it. The wings are already up; the notch must not pop open again.
    func testTheSameUpdateReportedAgainDoesNotReopenTheNotch() {
        service.noteUpdateAvailable("1.4.0")
        service.noteUpdateAvailable("1.4.0")
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(presenceChanges, 1)
    }

    func testANewerUpdateReplacesThePendingOneAndOpensTheNotchAgain() {
        service.noteUpdateAvailable("1.4.0")
        service.noteUpdateAvailable("1.4.1")
        XCTAssertEqual(service.availableVersion, "1.4.1")
        XCTAssertEqual(requests.count, 2)
    }

    // MARK: - Clearing

    func testAttentionClearsTheNoticeAndTheWings() {
        service.noteUpdateAvailable("1.4.0")
        service.clearAvailableUpdate(reason: "test")

        XCTAssertNil(service.availableVersion)
        XCTAssertNil(module.makeCompactLeadingView())
        XCTAssertNil(module.makeCompactTrailingView())
        XCTAssertFalse(module.hasExpandedContent)
        XCTAssertEqual(presenceChanges, 2, "arrived, then cleared")
    }

    func testClearingWithNothingPendingIsSilent() {
        service.clearAvailableUpdate(reason: "test")
        XCTAssertEqual(presenceChanges, 0)
    }

    // MARK: - The switch

    func testTheModuleSwitchIsTheAutomaticChecksSwitch() {
        XCTAssertFalse(service.automaticChecksEnabled, "nothing until the stored preference is applied")
        module.isEnabled = true
        XCTAssertTrue(service.automaticChecksEnabled,
                      "applied even though the value did not change: registration assigns the default")
        module.isEnabled = false
        XCTAssertFalse(service.automaticChecksEnabled)
    }

    func testADisabledModuleNeverAsksForTheNotch() {
        module.isEnabled = false
        service.noteUpdateAvailable("1.4.0")
        XCTAssertTrue(requests.isEmpty)
    }

    // MARK: - Arbitration

    /// A find while music plays waits its turn behind the media activity
    /// rather than cutting it off, and media interrupts a showing notice.
    func testANoticeYieldsToMedia() {
        let clock = TestClock()
        let arbiter = NotchArbiter(now: clock.read)
        let media = StubModule(id: "media", priority: .elevated)
        arbiter.register(media)
        arbiter.register(module)

        arbiter.requestLiveActivity(media.activity())
        arbiter.requestLiveActivity(LiveActivityRequest(
            moduleID: module.id, priority: module.priority, duration: UpdateModule.noticeDuration))
        XCTAssertEqual(arbiter.presentation, .liveActivity("media"), "queued behind media")

        clock.advance(by: 5)
        arbiter.tick()
        XCTAssertEqual(arbiter.presentation, .liveActivity("updates"), "its turn")

        arbiter.requestLiveActivity(media.activity())
        XCTAssertEqual(arbiter.presentation, .liveActivity("media"), "media interrupts")
    }

    func testStandbyKeepsTheModuleSoAFindCanPutTheWingsUp() {
        let arbiter = NotchArbiter()
        arbiter.register(StubModule(id: "media"))
        arbiter.register(module)
        XCTAssertEqual(arbiter.presentation, .standby(["media", "updates"]))
    }
}
