import XCTest
@testable import Astraea

/// The volume HUD: what it shows, when it yields, and where it sits.
@MainActor
final class SystemHUDTests: XCTestCase {

    // MARK: - Change detection

    func testInitialReadingIsNeverAnnounced() {
        XCTAssertFalse(VolumeReading.isAnnounceable(
            from: nil, to: VolumeReading(level: 0.5, isMuted: false)))
    }

    func testOneSystemStepIsAnnounced() {
        XCTAssertTrue(VolumeReading.isAnnounceable(
            from: VolumeReading(level: 0.5, isMuted: false),
            to: VolumeReading(level: 0.5 + 1.0 / 16, isMuted: false)))
    }

    func testUnchangedRepostIsNotAnnounced() {
        let reading = VolumeReading(level: 0.4375, isMuted: false)
        XCTAssertFalse(VolumeReading.isAnnounceable(from: reading, to: reading))
    }

    func testMuteToggleIsAnnounced() {
        XCTAssertTrue(VolumeReading.isAnnounceable(
            from: VolumeReading(level: 0.5, isMuted: false),
            to: VolumeReading(level: 0.5, isMuted: true)))
    }

    func testMutedReadsEmpty() {
        XCTAssertEqual(VolumeReading(level: 0.75, isMuted: true).displayLevel, 0)
        XCTAssertEqual(VolumeReading(level: 0.75, isMuted: false).displayLevel, 0.75)
    }

    func testSymbolTracksLevel() {
        XCTAssertEqual(SystemHUDView.symbol(kind: .volume, level: 0.8, isMuted: true), "speaker.slash.fill")
        XCTAssertEqual(SystemHUDView.symbol(kind: .volume, level: 0, isMuted: false), "speaker.slash.fill")
        XCTAssertEqual(SystemHUDView.symbol(kind: .volume, level: 0.1, isMuted: false), "speaker.wave.1.fill")
        XCTAssertEqual(SystemHUDView.symbol(kind: .volume, level: 0.5, isMuted: false), "speaker.wave.2.fill")
        XCTAssertEqual(SystemHUDView.symbol(kind: .volume, level: 1, isMuted: false), "speaker.wave.3.fill")
    }

    // MARK: - Panel state

    func testHUDOutranksPeekAndWings() {
        XCTAssertEqual(NotchCoordinator.state(expand: false, isPeeking: true,
                                              hasWings: true, hasHUD: true), .hud)
        XCTAssertEqual(NotchCoordinator.state(expand: false, isPeeking: false,
                                              hasWings: false, hasHUD: true), .hud)
    }

    func testExpandedOutranksHUD() {
        XCTAssertEqual(NotchCoordinator.state(expand: true, isPeeking: false,
                                              hasWings: false, hasHUD: true), .expanded)
    }

    func testHUDRectIsCompactWidthGrownDownward() {
        let housing = NSRect(x: 600, y: 950, width: 185, height: 32)
        let compact = NotchPanel.compactRect(housing: housing)
        let hud = NotchPanel.hudRect(housing: housing)
        XCTAssertEqual(hud.minX, compact.minX)
        XCTAssertEqual(hud.width, compact.width)
        XCTAssertEqual(hud.maxY, housing.maxY, "top stays on the screen edge")
        XCTAssertEqual(hud.height, housing.height + NotchPanel.hudStripHeight)
    }

    func testHUDRectOverBareNotchKeepsHousingWidth() {
        let housing = NSRect(x: 600, y: 950, width: 185, height: 32)
        let hud = NotchPanel.hudRect(housing: housing, overWings: false)
        XCTAssertEqual(hud.minX, housing.minX)
        XCTAssertEqual(hud.width, housing.width)
        XCTAssertEqual(hud.maxY, housing.maxY)
        XCTAssertEqual(hud.height, housing.height + NotchPanel.hudStripHeight)
    }

    /// A morph runs in a window that reaches both frames, and never in
    /// one stretched from another screen.
    func testMorphCanvasCoversBothFramesOnTheSameEdge() {
        let housing = NSRect(x: 600, y: 950, width: 185, height: 32)
        let compact = NotchPanel.compactRect(housing: housing)
        let open = NotchPanel.expandedRect(housing: housing, contentSize: CGSize(width: 500, height: 300))
        let canvas = NotchPanel.morphCanvas(current: compact, reach: open)
        XCTAssertEqual(canvas, compact.union(open))
        XCTAssertEqual(canvas?.maxY, housing.maxY, "top stays on the screen edge")
        let elsewhere = NSRect(x: -1500, y: 300, width: 293, height: 42)
        XCTAssertNil(NotchPanel.morphCanvas(current: elsewhere, reach: open),
                     "another screen: nothing to morph from, snap")
    }

    func testMorphMotionPerTransition() {
        XCTAssertEqual(NotchPanel.morphMotion(from: .peek, to: .expanded, reduceMotion: false), .open)
        XCTAssertEqual(NotchPanel.morphMotion(from: .expanded, to: .expanded, reduceMotion: false), .collapse,
                       "a page switch takes the tidy curve, no bounce")
        XCTAssertEqual(NotchPanel.morphMotion(from: .compact, to: .peek, reduceMotion: false), .peek)
        XCTAssertEqual(NotchPanel.morphMotion(from: .compact, to: .hud, reduceMotion: false), .collapse,
                       "the HUD takes no bounce")
        XCTAssertEqual(NotchPanel.morphMotion(from: .expanded, to: .compact, reduceMotion: true), .snap)
    }

    // MARK: - Volume keys

    func testHUDKeyDecoding() {
        func data1(_ code: Int, _ state: Int, repeat r: Bool = false) -> Int {
            (code << 16) | (state << 8) | (r ? 1 : 0)
        }
        XCTAssertEqual(HUDKeyEvent.decode(subtype: 8, data1: data1(0, 0xA)),
                       HUDKeyEvent(key: .volumeUp, isDown: true))
        XCTAssertEqual(HUDKeyEvent.decode(subtype: 8, data1: data1(1, 0xA, repeat: true)),
                       HUDKeyEvent(key: .volumeDown, isDown: true, isRepeat: true), "auto-repeat is still held")
        XCTAssertEqual(HUDKeyEvent.decode(subtype: 8, data1: data1(7, 0xB)),
                       HUDKeyEvent(key: .mute, isDown: false))
        XCTAssertEqual(HUDKeyEvent.decode(subtype: 8, data1: data1(2, 0xA)),
                       HUDKeyEvent(key: .brightnessUp, isDown: true))
        XCTAssertEqual(HUDKeyEvent.decode(subtype: 8, data1: data1(3, 0xB)),
                       HUDKeyEvent(key: .brightnessDown, isDown: false))
        XCTAssertNil(HUDKeyEvent.decode(subtype: 8, data1: data1(16, 0xA)), "play/pause is not ours")
        XCTAssertNil(HUDKeyEvent.decode(subtype: 8, data1: data1(21, 0xA)), "keyboard backlight is not ours")
        XCTAssertNil(HUDKeyEvent.decode(subtype: 7, data1: data1(0, 0xA)), "wrong subtype")
    }

    // MARK: - Steps

    func testStepsLandOnSixteenths() {
        XCTAssertEqual(HUDStep.next(0.6875, up: true, fine: false), 0.75, accuracy: 1e-9)
        XCTAssertEqual(HUDStep.next(0.6875, up: false, fine: false), 0.625, accuracy: 1e-9)
        XCTAssertEqual(HUDStep.next(0.70, up: true, fine: false), 0.75, accuracy: 1e-9,
                       "between marks, up lands on the next mark")
        XCTAssertEqual(HUDStep.next(0.70, up: false, fine: false), 0.6875, accuracy: 1e-9)
        XCTAssertEqual(HUDStep.next(0.6875 + 1e-7, up: false, fine: false), 0.625, accuracy: 1e-9,
                       "float noise above a mark is still that mark")
    }

    func testFineStepIsAQuarter() {
        XCTAssertEqual(HUDStep.next(0.5, up: true, fine: true), 0.5 + 1.0 / 64, accuracy: 1e-9)
        XCTAssertEqual(HUDStep.next(0.5, up: false, fine: true), 0.5 - 1.0 / 64, accuracy: 1e-9)
    }

    func testStepsClampAtTheEnds() {
        XCTAssertEqual(HUDStep.next(1, up: true, fine: false), 1)
        XCTAssertEqual(HUDStep.next(0, up: false, fine: false), 0)
        XCTAssertEqual(HUDStep.next(0.03, up: false, fine: false), 0)
    }

    func testRepeatedStepsSurviveHardwareRounding() {
        // Measured: a set of 0.625 reads back 0.626736, of 0.6875 reads 0.680625.
        var level = 0.6875
        for expected in [0.625, 0.5625, 0.5] {
            let readBack = level == 0.6875 ? 0.680625 : level + 0.0017
            level = HUDStep.next(HUDStep.base(reading: readBack, lastSet: level), up: false, fine: false)
            XCTAssertEqual(level, expected, accuracy: 1e-9)
        }
        XCTAssertEqual(HUDStep.next(HUDStep.base(reading: 0.680625, lastSet: 0.6875), up: true, fine: false),
                       0.75, accuracy: 1e-9)
    }

    func testAnOutsideChangeIsTheNewBase() {
        XCTAssertEqual(HUDStep.base(reading: 0.3, lastSet: 0.6875), 0.3)
        XCTAssertEqual(HUDStep.base(reading: 0.3, lastSet: nil), 0.3)
    }

    func testBrightnessSymbol() {
        XCTAssertEqual(SystemHUDView.symbol(kind: .brightness, level: 0.2, isMuted: false), "sun.min.fill")
        XCTAssertEqual(SystemHUDView.symbol(kind: .brightness, level: 0.8, isMuted: false), "sun.max.fill")
    }

    // MARK: - Arbitration

    func testEndingActiveActivityReturnsToStandby() {
        let clock = TestClock()
        let arbiter = NotchArbiter(now: clock.read)
        arbiter.register(StubModule(id: "stats"))
        arbiter.register(StubModule(id: "hud", priority: .urgent, wantsCompactDisplay: false))
        arbiter.requestLiveActivity(LiveActivityRequest(moduleID: "hud", priority: .urgent, duration: 1.5))
        XCTAssertEqual(arbiter.presentation, .liveActivity("hud"))

        arbiter.endLiveActivity(of: "hud")
        XCTAssertEqual(arbiter.presentation, .standby(["stats"]))
        XCTAssertNil(arbiter.timeUntilExpiry)
    }

    func testEndingActivityPromotesQueuedOne() {
        let clock = TestClock()
        let arbiter = NotchArbiter(now: clock.read)
        arbiter.register(StubModule(id: "hud", priority: .urgent, wantsCompactDisplay: false))
        arbiter.register(StubModule(id: "media", priority: .elevated))
        arbiter.requestLiveActivity(LiveActivityRequest(moduleID: "hud", priority: .urgent, duration: 1.5))
        arbiter.requestLiveActivity(LiveActivityRequest(moduleID: "media", priority: .elevated, duration: 4))

        arbiter.endLiveActivity(of: "hud")
        XCTAssertEqual(arbiter.presentation, .liveActivity("media"))
    }

    func testEndingAnotherModulesActivityLeavesItAlone() {
        let clock = TestClock()
        let arbiter = NotchArbiter(now: clock.read)
        arbiter.register(StubModule(id: "media", priority: .elevated))
        arbiter.register(StubModule(id: "hud", priority: .urgent, wantsCompactDisplay: false))
        arbiter.requestLiveActivity(LiveActivityRequest(moduleID: "media", priority: .elevated, duration: 4))

        arbiter.endLiveActivity(of: "hud")
        XCTAssertEqual(arbiter.presentation, .liveActivity("media"))
    }

    func testHUDModuleIsHiddenFromSettingsAndPresentsAsHUD() {
        let module = SystemHUDModule()
        XCTAssertFalse(module.showsInSettings)
        XCTAssertEqual(module.liveActivityStyle, .hud)
        XCTAssertFalse(module.wantsCompactDisplay)
    }
}
