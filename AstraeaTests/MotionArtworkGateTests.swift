import XCTest
@testable import Astraea

/// The motion-artwork playback gate: hard rule 9 for the looping video.
///
/// The video itself is not exercised — `AVPlayer` needs a real asset — but
/// the view plays only while `motionArtworkMayPlay` is true, so the gate's
/// lifecycle is what keeps the decoder idle behind a closed panel.
@MainActor
final class MotionArtworkGateTests: XCTestCase {

    private func makeModule() -> MediaModule {
        MediaModule(sources: [StubMediaSource(id: "spotify", running: true)])
    }

    func testPureConditionNeedsAllThree() {
        XCTAssertTrue(MediaModule.motionArtworkShouldPlay(isVisible: true, isEnabled: true, displayAsleep: false))
        XCTAssertFalse(MediaModule.motionArtworkShouldPlay(isVisible: false, isEnabled: true, displayAsleep: false))
        XCTAssertFalse(MediaModule.motionArtworkShouldPlay(isVisible: true, isEnabled: false, displayAsleep: false))
        XCTAssertFalse(MediaModule.motionArtworkShouldPlay(isVisible: true, isEnabled: true, displayAsleep: true))
    }

    func testClosedUntilVisibleAndClosedAgainOnResign() {
        let module = makeModule()
        XCTAssertFalse(module.motionArtworkMayPlay, "nothing plays behind a closed panel")
        module.didBecomeVisible()
        XCTAssertTrue(module.motionArtworkMayPlay)
        module.didResignVisible()
        XCTAssertFalse(module.motionArtworkMayPlay)
    }

    func testDisplaySleepClosesTheGateAndWakeReopensIt() {
        let module = makeModule()
        module.didBecomeVisible()
        module.setDisplayAsleep(true)
        XCTAssertFalse(module.motionArtworkMayPlay, "asleep: closed even though still visible")
        module.setDisplayAsleep(false)
        XCTAssertTrue(module.motionArtworkMayPlay)
        module.didResignVisible()
    }

    func testDisablingClosesTheGateAndDropsTheVideo() {
        let module = makeModule()
        module.didBecomeVisible()
        module.isEnabled = false
        XCTAssertFalse(module.motionArtworkMayPlay, "a disabled module must not decode")
        XCTAssertNil(module.motionArtwork)
        module.didResignVisible()
    }

    func testNoMotionArtworkByDefault() {
        XCTAssertNil(makeModule().motionArtwork, "absent is the normal case")
    }
}
