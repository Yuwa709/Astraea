import XCTest
import Observation
@testable import Astraea

/// Face Unlock, phase 5: the lock-screen overlay's state mapping, its
/// controller's show/hide rules, and the fail-soft SkyLight path. No window
/// is created and SkyLight is never called.
@MainActor
final class LockScreenOverlayTests: XCTestCase {

    private typealias Mapping = LockScreenOverlayMapping

    private static let allStatuses: [FaceUnlockStatus] = [
        .disabled, .sessionLocked, .noStoredPassword, .pausedAfterRejections, .faceDataNotReady,
        .noEnrolledFace, .enrolledFacesNeedRecapture, .accessibilityNeeded, .cameraNotYetRequested,
        .cameraNotAuthorized, .passwordRejected, .ready, .scanning, .typingPassword, .verifying,
    ]

    private static let allOutcomes: [FaceUnlockOutcome] = [
        .unlocked, .unlockedUnconfirmed, .verificationInconclusive, .scanCapReached,
        .livenessDenied(.glossGlare), .livenessDenied(.deviceDetected),
        .passwordRejected, .aborted, .abortedPartway, .failed("camera"),
    ]

    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private func phase(_ status: FaceUnlockStatus, _ outcome: FaceUnlockOutcome? = nil,
                       ago: TimeInterval = 0.5, consumed: Date? = nil) -> LockScreenOverlayPhase? {
        let outcomeAt = outcome == nil ? nil : now.addingTimeInterval(-ago)
        return Mapping.phase(status: status, outcome: outcome, outcomeAt: outcomeAt,
                             consumedOutcomeAt: consumed, now: now)
    }

    // MARK: - Mapping

    func testEveryStatusWithoutAnOutcome() {
        for status in Self.allStatuses {
            let expected: LockScreenOverlayPhase? = switch status {
            case .scanning: .scanning
            case .typingPassword, .verifying: .matched
            default: nil
            }
            XCTAssertEqual(phase(status), expected, "\(status)")
        }
    }

    func testInProgressStatusesWinOverAnyOutcome() {
        for outcome in Self.allOutcomes {
            XCTAssertEqual(phase(.scanning, outcome), .scanning, "\(outcome)")
            XCTAssertEqual(phase(.typingPassword, outcome), .matched, "\(outcome)")
            XCTAssertEqual(phase(.verifying, outcome), .matched, "\(outcome)")
        }
    }

    func testFreshOutcomesAfterAnAttempt() {
        for outcome in Self.allOutcomes {
            let expected: LockScreenOverlayPhase? = switch outcome {
            case .scanCapReached, .livenessDenied, .passwordRejected, .abortedPartway, .failed: .failed
            case .unlocked, .unlockedUnconfirmed, .aborted, .verificationInconclusive: nil
            }
            XCTAssertEqual(phase(.ready, outcome), expected, "\(outcome)")
            XCTAssertEqual(phase(.passwordRejected, outcome), expected, "\(outcome)")
        }
    }

    func testConsumedOutcomeShowsNothing() {
        let outcomeAt = now.addingTimeInterval(-0.5)
        XCTAssertNil(phase(.ready, .scanCapReached, ago: 0.5, consumed: outcomeAt))
    }

    func testFailureHoldExpiresTwoSecondsAfterTheOutcome() {
        XCTAssertEqual(phase(.ready, .passwordRejected, ago: 1.9), .failed)
        XCTAssertNil(phase(.ready, .passwordRejected, ago: 2.0))
        XCTAssertNil(phase(.ready, .passwordRejected, ago: 600), "an old failure never comes back")
        XCTAssertEqual(Mapping.failureHoldRemaining(outcomeAt: now, now: now), 2)
        XCTAssertEqual(Mapping.failureHoldRemaining(outcomeAt: now.addingTimeInterval(-5), now: now), 0)
        XCTAssertEqual(Mapping.failureHoldRemaining(outcomeAt: now.addingTimeInterval(5), now: now), 2,
                       "a clock step backwards holds at most the full hold")
    }

    func testOverlayFrameAddsAWingEachSideFlushWithTheTop() {
        let notch = NSRect(x: 600, y: 950, width: 180, height: 32)
        let frame = LockScreenScanLayout.overlayFrame(notchRect: notch, wingWidth: 50)
        XCTAssertEqual(frame, NSRect(x: 550, y: 950, width: 280, height: 32))
        let layout = LockScreenScanLayout(notchRect: notch, wingWidth: 50)
        XCTAssertEqual(layout.totalWidth, frame.width)
        XCTAssertEqual(layout.height, notch.height)
    }

    // MARK: - SkyLight, fail soft

    func testSkyLightWithNoSymbolsResolvesToNil() {
        XCTAssertNil(SkyLightAPI(resolve: { _ in nil }))
    }

    func testSkyLightWithOneMissingSymbolResolvesToNil() {
        for missing in SkyLightAPI.symbolNames {
            let api = SkyLightAPI { name in name == missing ? nil : UnsafeMutableRawPointer(bitPattern: 0x1000) }
            XCTAssertNil(api, missing)
        }
    }

    func testRealPresenterWithoutSkyLightShowsNothing() {
        var screenAsked = false
        let presenter = LockScreenScanPresenter(loadSkyLight: { nil }, findScreen: { screenAsked = true; return nil })
        XCTAssertFalse(presenter.present(.scanning, reduceMotion: false))
        XCTAssertFalse(presenter.isPresented)
        XCTAssertFalse(screenAsked, "SkyLight is checked before anything else")
        presenter.update(.matched)
        presenter.dismiss(animated: false, reason: "test")
        XCTAssertFalse(presenter.isPresented)
    }

    func testControllerWithoutSkyLightShowsNothingAndDoesNotCrash() async {
        let source = FakeOverlaySource()
        let events = FakeLockEvents()
        let presenter = LockScreenScanPresenter(loadSkyLight: { nil }, findScreen: { nil })
        let controller = LockScreenOverlayController(
            source: source, presenter: presenter, lockGuard: FakeLockGuard(.locked),
            killEvents: events, clock: FakeFaceUnlockClock(), reduceMotion: { false })
        source.status = .scanning
        await settle()
        XCTAssertNil(controller.shownPhase)
        XCTAssertFalse(presenter.isPresented)
        source.status = .ready
        await settle()
        XCTAssertTrue(events.isStarted, "armed while Face Unlock is on")
        source.status = .disabled
        await settle()
        XCTAssertFalse(events.isStarted, "no kill-switch observers once Face Unlock is off")
    }

    // MARK: - Controller

    private struct Harness {
        let source: FakeOverlaySource
        let presenter: FakeOverlayPresenter
        let lockGuard: FakeLockGuard
        let events: FakeLockEvents
        let clock: FakeFaceUnlockClock
        let controller: LockScreenOverlayController
    }

    private func makeHarness(status: FaceUnlockStatus = .ready, outcome: FaceUnlockOutcome? = nil,
                             outcomeAt: Date? = nil, reduceMotion: Bool = false,
                             now: Date? = nil) -> Harness {
        let source = FakeOverlaySource()
        source.status = status
        source.lastOutcome = outcome
        source.lastOutcomeAt = outcomeAt
        let presenter = FakeOverlayPresenter()
        let lockGuard = FakeLockGuard(.locked)
        let events = FakeLockEvents()
        let clock = FakeFaceUnlockClock()
        // Failure holds stay pending until a test releases them.
        clock.holdSleep = { _ in true }
        let controller = LockScreenOverlayController(
            source: source, presenter: presenter, lockGuard: lockGuard,
            killEvents: events, clock: clock, now: now.map { fixed in { fixed } },
            reduceMotion: { reduceMotion })
        return Harness(source: source, presenter: presenter, lockGuard: lockGuard,
                       events: events, clock: clock, controller: controller)
    }

    /// Lets the observation re-registration task run.
    private func settle() async {
        for _ in 0..<10 { await Task.yield() }
    }

    func testShowsOnScanningAndUpdatesToMatchedInPlace() async {
        let h = makeHarness(reduceMotion: true)
        XCTAssertTrue(h.presenter.presented.isEmpty)
        h.source.status = .scanning
        await settle()
        XCTAssertEqual(h.presenter.presented.map(\.phase), [.scanning])
        XCTAssertEqual(h.presenter.presented.first?.reduceMotion, true)
        XCTAssertTrue(h.events.isStarted)
        h.source.status = .typingPassword
        await settle()
        h.source.status = .verifying
        await settle()
        XCTAssertEqual(h.presenter.presented.count, 1, "the window is not rebuilt")
        XCTAssertEqual(h.presenter.updates, [.matched])
        XCTAssertEqual(h.controller.shownPhase, .matched)
    }

    func testUnlockOutcomeDismissesWithoutAHold() async {
        let h = makeHarness(status: .verifying)
        await settle()
        XCTAssertEqual(h.controller.shownPhase, .matched)
        h.lockGuard.state = .unlocked
        h.source.lastOutcome = .unlocked
        h.source.lastOutcomeAt = Date()
        h.source.status = .ready
        await settle()
        XCTAssertNil(h.controller.shownPhase)
        XCTAssertEqual(h.presenter.dismissals.map(\.animated), [false], "off the lock screen: instant")
        XCTAssertTrue(h.events.isStarted, "still armed for the next scan")
        XCTAssertEqual(h.clock.heldCount, 0, "no hold for an unlock")
    }

    func testFailureHoldsThenHides() async {
        let h = makeHarness(status: .scanning)
        await settle()
        h.source.lastOutcome = .scanCapReached
        h.source.lastOutcomeAt = Date()
        h.source.status = .ready
        await settle()
        XCTAssertEqual(h.controller.shownPhase, .failed)
        XCTAssertEqual(h.presenter.updates, [.failed])
        XCTAssertEqual(h.clock.heldCount, 1, "one one-shot hold")
        h.clock.releaseHeldSleeps()
        await h.controller.waitForHold()
        await settle()
        XCTAssertNil(h.controller.shownPhase)
        XCTAssertEqual(h.presenter.dismissals.map(\.animated), [true], "still at the lock screen: fade")
        XCTAssertTrue(h.events.isStarted, "the kill switch still reaches the fading window")
        h.presenter.finishFade()
        XCTAssertTrue(h.events.isStarted, "Face Unlock is on: armed for the next scan")
    }

    func testANewScanCancelsTheFailureHold() async {
        let h = makeHarness(status: .scanning)
        await settle()
        h.source.lastOutcome = .passwordRejected
        h.source.lastOutcomeAt = Date()
        h.source.status = .passwordRejected
        await settle()
        XCTAssertEqual(h.clock.heldCount, 1)
        h.source.status = .scanning
        await settle()
        XCTAssertEqual(h.controller.shownPhase, .scanning)
        await settle()
        XCTAssertEqual(h.clock.heldCount, 0, "the hold was cancelled")
    }

    func testStaleOutcomeFromAnEarlierLockSessionNeverShows() async {
        // Present at launch: never shown.
        let h = makeHarness(status: .ready, outcome: .scanCapReached, outcomeAt: Date())
        await settle()
        XCTAssertTrue(h.presenter.presented.isEmpty)
        // A later scan that is cancelled (no new outcome) shows no failure.
        h.source.status = .scanning
        await settle()
        h.source.status = .ready
        await settle()
        XCTAssertNil(h.controller.shownPhase)
        XCTAssertEqual(h.presenter.updates, [], "never switched to failed")
    }

    func testOutcomeRecordedBeforeTheScanBeganIsStale() async {
        let h = makeHarness()
        await settle()
        // Recorded while the overlay was not following an attempt, then a
        // scan starts and is cancelled.
        h.source.lastOutcome = .failed("camera")
        h.source.lastOutcomeAt = Date()
        h.source.status = .scanning
        await settle()
        h.source.status = .ready
        await settle()
        XCTAssertNil(h.controller.shownPhase)
    }

    func testRefusesToShowWhenTheGateSaysUnlocked() async {
        let h = makeHarness()
        h.lockGuard.state = .unlocked
        h.source.status = .scanning
        await settle()
        XCTAssertTrue(h.presenter.presented.isEmpty)
        XCTAssertNil(h.controller.shownPhase)
    }

    func testRefusesToShowWhenTheLockStateIsUnknownOrTheDisplaySleeps() async {
        let h = makeHarness()
        h.lockGuard.state = .unknown
        h.source.status = .scanning
        await settle()
        XCTAssertTrue(h.presenter.presented.isEmpty)
        h.lockGuard.state = .locked
        h.lockGuard.displayAsleep = true
        h.source.status = .typingPassword
        await settle()
        XCTAssertTrue(h.presenter.presented.isEmpty)
    }

    func testGateClosingWhileShownDismissesAtOnce() async {
        let h = makeHarness(status: .scanning)
        await settle()
        XCTAssertEqual(h.controller.shownPhase, .scanning)
        h.lockGuard.state = .unlocked
        h.source.status = .typingPassword
        await settle()
        XCTAssertNil(h.controller.shownPhase)
        XCTAssertEqual(h.presenter.dismissals.map(\.animated), [false])
    }

    func testKillSwitchDismissesInstantlyAndHoldsOffForTheAttempt() async {
        for event in [LockEvent.screenUnlocked, .sleep] {
            let h = makeHarness(status: .scanning)
            await settle()
            XCTAssertEqual(h.controller.shownPhase, .scanning)
            h.events.send(event)
            XCTAssertNil(h.controller.shownPhase, "\(event): synchronous, before any observation")
            XCTAssertEqual(h.presenter.dismissals.map(\.animated), [false], "\(event)")
            XCTAssertTrue(h.events.isStarted, "\(event): still listening, to re-arm")
            XCTAssertTrue(h.controller.isSuppressed)
            // The coordinator has not caught up yet: still no overlay.
            h.source.status = .verifying
            await settle()
            XCTAssertEqual(h.presenter.presented.count, 1, "\(event): not brought back")
            // The attempt ends, with a failure recorded in it: not shown.
            h.source.lastOutcome = .passwordRejected
            h.source.lastOutcomeAt = Date()
            h.source.status = .passwordRejected
            await settle()
            XCTAssertNil(h.controller.shownPhase, "\(event)")
            XCTAssertFalse(h.controller.isSuppressed)
            XCTAssertTrue(h.events.isStarted, "\(event): armed for the next scan")
            // The next attempt shows again.
            h.source.status = .scanning
            await settle()
            XCTAssertEqual(h.presenter.presented.count, 2, "\(event)")
        }
    }

    func testKillSwitchDuringAFailureHoldConsumesIt() async {
        let h = makeHarness(status: .scanning)
        await settle()
        h.source.lastOutcome = .scanCapReached
        h.source.lastOutcomeAt = Date()
        h.source.status = .ready
        await settle()
        XCTAssertEqual(h.controller.shownPhase, .failed)
        h.events.send(.sleep)
        XCTAssertNil(h.controller.shownPhase)
        XCTAssertFalse(h.controller.isSuppressed, "not mid-attempt")
        await settle()
        XCTAssertEqual(h.clock.heldCount, 0)
        // Any unrelated change does not resurrect the consumed failure.
        h.source.status = .passwordRejected
        await settle()
        XCTAssertNil(h.controller.shownPhase)
        XCTAssertEqual(h.presenter.presented.count, 1)
    }

    func testLockAndWakeEventsLeaveAShownOverlayAlone() async {
        let h = makeHarness(status: .scanning)
        await settle()
        h.events.send(.wake)
        h.events.send(.screenLocked)
        XCTAssertEqual(h.controller.shownPhase, .scanning)
        XCTAssertTrue(h.presenter.dismissals.isEmpty)
    }

    func testPresenterFailureLeavesNothingRunningOnceFaceUnlockIsOff() async {
        let h = makeHarness()
        h.presenter.available = false
        h.source.status = .scanning
        await settle()
        XCTAssertNil(h.controller.shownPhase)
        h.source.status = .ready
        await settle()
        XCTAssertFalse(h.controller.isSuppressed)
        h.source.status = .disabled
        await settle()
        XCTAssertFalse(h.events.isStarted)
    }

    // MARK: - Kill switch outside a presentation

    func testUnlockBeforePresentHoldsOffUntilAFreshLock() async {
        let h = makeHarness()
        h.lockGuard.state = .unknown
        h.source.status = .scanning
        await settle()
        XCTAssertTrue(h.presenter.presented.isEmpty)
        XCTAssertTrue(h.events.isStarted, "listening for the whole attempt, not only while shown")
        h.events.send(.screenUnlocked)
        XCTAssertEqual(h.controller.suppression, .unlocked)
        // The gate lags the notification and still reads locked.
        h.lockGuard.state = .locked
        h.source.status = .typingPassword
        await settle()
        XCTAssertTrue(h.presenter.presented.isEmpty, "not drawn over a Mac that just unlocked")
        h.events.send(.wake)
        XCTAssertTrue(h.presenter.presented.isEmpty, "a wake does not re-arm after an unlock")
        h.events.send(.screenLocked)
        XCTAssertFalse(h.controller.isSuppressed)
        XCTAssertEqual(h.presenter.presented.map(\.phase), [.matched])
    }

    func testGateRefusalIsRetriedOnWake() async {
        let h = makeHarness()
        h.lockGuard.displayAsleep = true
        h.source.status = .scanning
        await settle()
        XCTAssertTrue(h.presenter.presented.isEmpty)
        XCTAssertTrue(h.events.isStarted)
        h.events.send(.wake)
        XCTAssertTrue(h.presenter.presented.isEmpty, "still asleep: refused again")
        h.lockGuard.displayAsleep = false
        h.events.send(.wake)
        XCTAssertEqual(h.presenter.presented.map(\.phase), [.scanning])
        XCTAssertEqual(h.controller.shownPhase, .scanning)
    }

    func testGateRefusalIsRetriedOnLock() async {
        let h = makeHarness()
        h.lockGuard.state = .unlocked
        h.source.status = .scanning
        await settle()
        XCTAssertTrue(h.presenter.presented.isEmpty)
        h.lockGuard.state = .locked
        h.events.send(.screenLocked)
        XCTAssertEqual(h.presenter.presented.map(\.phase), [.scanning])
    }

    func testKillDuringAFadeOutEndsItAtOnce() async {
        let h = makeHarness(status: .scanning)
        await settle()
        h.source.status = .ready
        await settle()
        XCTAssertEqual(h.presenter.dismissals.map(\.animated), [true])
        XCTAssertTrue(h.presenter.isFadingOut)
        XCTAssertTrue(h.events.isStarted)
        h.events.send(.screenUnlocked)
        XCTAssertFalse(h.presenter.isFadingOut, "torn down at once, not left to finish")
        XCTAssertEqual(h.presenter.fadesEndedAtOnce, 1)
        XCTAssertFalse(h.controller.isSuppressed, "not mid-attempt")
        XCTAssertTrue(h.events.isStarted, "Face Unlock is on: armed for the next scan")
    }

    func testUnlockThenRelockMidScanReArms() async {
        let h = makeHarness(status: .scanning)
        await settle()
        h.events.send(.screenUnlocked)
        XCTAssertTrue(h.controller.isSuppressed)
        // Re-locked before the coordinator left the scan, but the gate
        // does not read locked yet: stays off.
        h.lockGuard.state = .unlocked
        h.events.send(.screenLocked)
        XCTAssertTrue(h.controller.isSuppressed)
        XCTAssertEqual(h.presenter.presented.count, 1)
        h.lockGuard.state = .locked
        h.events.send(.screenLocked)
        XCTAssertFalse(h.controller.isSuppressed)
        XCTAssertEqual(h.presenter.presented.map(\.phase), [.scanning, .scanning])
    }

    func testSleepOrScreensaverMidScanReArmsOnWake() async {
        let h = makeHarness(status: .scanning)
        await settle()
        h.events.send(.sleep)
        XCTAssertEqual(h.controller.suppression, .asleep)
        XCTAssertNil(h.controller.shownPhase)
        h.lockGuard.displayAsleep = true
        h.events.send(.wake)
        XCTAssertTrue(h.controller.isSuppressed, "gate closed: not re-armed")
        h.lockGuard.displayAsleep = false
        h.events.send(.wake)
        XCTAssertFalse(h.controller.isSuppressed)
        XCTAssertEqual(h.presenter.presented.count, 2)
    }

    func testUnlockOutranksALaterSleep() async {
        let h = makeHarness(status: .scanning)
        await settle()
        h.events.send(.screenUnlocked)
        h.events.send(.sleep)
        XCTAssertEqual(h.controller.suppression, .unlocked)
        h.events.send(.wake)
        XCTAssertEqual(h.presenter.presented.count, 1)
    }

    func testFailureHoldLastsTwoSecondsFromTheOutcome() async {
        let fixedNow = Date(timeIntervalSinceReferenceDate: 5_000)
        let h = makeHarness(status: .scanning, now: fixedNow)
        await settle()
        h.source.lastOutcome = .passwordRejected
        h.source.lastOutcomeAt = fixedNow.addingTimeInterval(-0.5)
        h.source.status = .passwordRejected
        await settle()
        await settle()
        XCTAssertEqual(h.controller.shownPhase, .failed)
        XCTAssertEqual(h.clock.sleeps, [1.5], "the rest of the two-second hold")
        h.clock.releaseHeldSleeps()
        await h.controller.waitForHold()
    }

    func testAFailureRefusedByTheGateIsConsumed() async {
        let h = makeHarness(status: .scanning)
        await settle()
        h.lockGuard.displayAsleep = true
        h.source.lastOutcome = .scanCapReached
        h.source.lastOutcomeAt = Date()
        h.source.status = .ready
        await settle()
        XCTAssertNil(h.controller.shownPhase)
        XCTAssertEqual(h.presenter.dismissals.map(\.animated), [false])
        h.lockGuard.displayAsleep = false
        h.source.status = .passwordRejected
        await settle()
        XCTAssertNil(h.controller.shownPhase, "never shown later")
        XCTAssertEqual(h.presenter.presented.count, 1)
        XCTAssertEqual(h.presenter.updates, [])
    }

    // MARK: - Kill switch armed before the scan (review L3)

    func testKillSwitchIsArmedWheneverFaceUnlockIsOn() async {
        let off = makeHarness(status: .disabled)
        await settle()
        XCTAssertFalse(off.events.isStarted, "Face Unlock off: nothing runs")
        off.source.status = .ready
        await settle()
        XCTAssertTrue(off.events.isStarted, "on and idle: already listening before any scan")
        for status in Self.allStatuses where status != .disabled {
            let h = makeHarness(status: status)
            await settle()
            XCTAssertTrue(h.events.isStarted, "\(status)")
        }
    }

    /// The unlock lands after the coordinator set `.scanning` but before the
    /// overlay's observation hop ran. The gate still reads locked (it lags
    /// an unlock), so without a live kill switch this drew over the desktop.
    func testUnlockInTheSameTurnAsScanningNeverShowsTheOverlay() async {
        for event in [LockEvent.screenUnlocked, .sleep] {
            let h = makeHarness()
            await settle()
            h.source.status = .scanning
            h.events.send(event)
            XCTAssertTrue(h.controller.isSuppressed, "\(event): caught before the first presentation")
            await settle()
            XCTAssertTrue(h.presenter.presented.isEmpty, "\(event): never shown")
            XCTAssertNil(h.controller.shownPhase, "\(event)")
            h.source.status = .verifying
            await settle()
            XCTAssertTrue(h.presenter.presented.isEmpty, "\(event): not for the rest of the attempt")
            h.source.status = .ready
            await settle()
            XCTAssertFalse(h.controller.isSuppressed, "\(event): the next attempt is armed again")
            XCTAssertTrue(h.presenter.presented.isEmpty, "\(event)")
        }
    }

    func testAnIdleUnlockOrSleepDoesNotHoldOffTheNextScan() async {
        let h = makeHarness()
        await settle()
        h.events.send(.screenUnlocked)
        h.events.send(.sleep)
        XCTAssertFalse(h.controller.isSuppressed, "no attempt in progress: nothing to hold off")
        XCTAssertTrue(h.presenter.dismissals.isEmpty)
        h.source.status = .scanning
        await settle()
        XCTAssertEqual(h.presenter.presented.map(\.phase), [.scanning])
    }

    func testDisablingWhileShownKeepsTheSwitchUntilTheFadeEnds() async {
        let h = makeHarness(status: .scanning)
        await settle()
        h.source.status = .disabled
        await settle()
        XCTAssertEqual(h.presenter.dismissals.map(\.animated), [true])
        XCTAssertTrue(h.events.isStarted, "the fading window can still be killed")
        h.presenter.finishFade()
        XCTAssertFalse(h.events.isStarted)
    }

    // MARK: - Reduce Motion (review L4, hard rule 8)

    func testReduceMotionHidesWithoutAFade() async {
        let h = makeHarness(status: .scanning, reduceMotion: true)
        await settle()
        XCTAssertEqual(h.presenter.presented.first?.reduceMotion, true)
        h.source.status = .ready
        await settle()
        XCTAssertEqual(h.presenter.dismissals.map(\.animated), [false], "instant, even at the lock screen")
        XCTAssertFalse(h.presenter.isFadingOut)
    }

    func testReduceMotionEndsAFailureHoldWithoutAFade() async {
        let h = makeHarness(status: .scanning, reduceMotion: true)
        await settle()
        h.source.lastOutcome = .scanCapReached
        h.source.lastOutcomeAt = Date()
        h.source.status = .ready
        await settle()
        XCTAssertEqual(h.controller.shownPhase, .failed)
        h.clock.releaseHeldSleeps()
        await h.controller.waitForHold()
        await settle()
        XCTAssertEqual(h.presenter.dismissals.map(\.animated), [false])
    }

    func testReduceMotionMakesEveryTransitionInstant() {
        XCTAssertNil(LockScreenScanMotion.phaseChange(reduceMotion: true), "no crossfade between phases")
        XCTAssertNotNil(LockScreenScanMotion.phaseChange(reduceMotion: false))
        XCTAssertNil(LockScreenScanMotion.windowFadeIn(reduceMotion: true), "the window appears at once")
        XCTAssertEqual(LockScreenScanMotion.windowFadeIn(reduceMotion: false), LockScreenScanPresenter.fadeDuration)
    }

    // MARK: - Kill-switch events

    func testScreensaverStartIsReportedAsSleep() {
        let inner = FakeLockEvents()
        let center = NotificationCenter()
        let events = LockScreenOverlayEvents(lockEvents: inner, center: center)
        var received: [LockEvent] = []
        events.onEvent = { received.append($0) }
        center.post(name: LockScreenOverlayEvents.screensaverDidStart, object: nil)
        XCTAssertEqual(received, [], "nothing observed before start")
        events.start()
        events.start()
        XCTAssertTrue(inner.isStarted)
        XCTAssertTrue(events.isObservingScreensaver)
        center.post(name: LockScreenOverlayEvents.screensaverDidStart, object: nil)
        inner.send(.wake)
        XCTAssertEqual(received, [.sleep, .wake], "once each, despite the double start")
        events.stop()
        XCTAssertFalse(inner.isStarted)
        XCTAssertFalse(events.isObservingScreensaver)
        center.post(name: LockScreenOverlayEvents.screensaverDidStart, object: nil)
        XCTAssertEqual(received, [.sleep, .wake])
    }

    // MARK: - Screen policy

    func testNotchPredicateNeedsAnInsetAndBothAuxiliaryAreas() {
        let area = NSRect(x: 0, y: 0, width: 600, height: 32)
        XCTAssertTrue(ScreenPolicy.hasNotch(topInset: 32, leftArea: area, rightArea: area))
        XCTAssertFalse(ScreenPolicy.hasNotch(topInset: 0, leftArea: area, rightArea: area))
        XCTAssertFalse(ScreenPolicy.hasNotch(topInset: 32, leftArea: nil, rightArea: area))
        XCTAssertFalse(ScreenPolicy.hasNotch(topInset: 32, leftArea: area, rightArea: nil))
    }
}

// MARK: - Fakes

@Observable
@MainActor
final class FakeOverlaySource: LockScreenOverlaySource {
    var status: FaceUnlockStatus = .ready
    var lastOutcome: FaceUnlockOutcome?
    var lastOutcomeAt: Date?
}

@MainActor
final class FakeOverlayPresenter: LockScreenOverlayPresenting {
    var available = true
    private(set) var isPresented = false
    /// An animated dismissal fades until `finishFade()`.
    private(set) var isFadingOut = false
    var onFadeOutFinished: (() -> Void)?
    private(set) var presented: [(phase: LockScreenOverlayPhase, reduceMotion: Bool)] = []
    private(set) var updates: [LockScreenOverlayPhase] = []
    private(set) var dismissals: [(animated: Bool, reason: String)] = []
    /// Fades ended early by an instant dismissal.
    private(set) var fadesEndedAtOnce = 0

    func present(_ phase: LockScreenOverlayPhase, reduceMotion: Bool) -> Bool {
        guard available else { return false }
        presented.append((phase, reduceMotion))
        isPresented = true
        return true
    }

    func update(_ phase: LockScreenOverlayPhase) { updates.append(phase) }

    func dismiss(animated: Bool, reason: String) {
        if !animated && isFadingOut {
            isFadingOut = false
            fadesEndedAtOnce += 1
        }
        guard isPresented else { return }
        dismissals.append((animated, reason))
        isPresented = false
        if animated { isFadingOut = true }
    }

    func finishFade() {
        guard isFadingOut else { return }
        isFadingOut = false
        onFadeOutFinished?()
    }
}
