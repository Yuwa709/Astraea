import XCTest
@testable import PopNotch

/// These create and release real power-management assertions. That is the
/// point: the failure this feature must never have is a leaked assertion, and
/// only the real IOKit call can prove it is released.
@MainActor
final class CaffeinateServiceTests: XCTestCase {

    func testStartsInactive() {
        XCTAssertFalse(CaffeinateService().isActive, "must never hold the Mac awake unasked")
    }

    func testAcquireThenReleaseFlipsState() {
        let service = CaffeinateService()
        service.acquire()
        XCTAssertTrue(service.isActive)
        service.release()
        XCTAssertFalse(service.isActive)
    }

    func testToggleRoundTrips() {
        let service = CaffeinateService()
        service.toggle()
        XCTAssertTrue(service.isActive)
        service.toggle()
        XCTAssertFalse(service.isActive)
    }

    func testAcquireIsIdempotent() {
        // A second acquire must not overwrite the stored id and orphan the
        // first assertion — that is exactly how a leak would happen.
        let service = CaffeinateService()
        service.acquire()
        service.acquire()
        XCTAssertTrue(service.isActive)
        service.release()
        XCTAssertFalse(service.isActive, "one release must clear one assertion")
    }

    func testReleaseWithoutAcquireIsSafe() {
        let service = CaffeinateService()
        service.release()
        XCTAssertFalse(service.isActive)
    }

    func testDoubleReleaseIsSafe() {
        let service = CaffeinateService()
        service.acquire()
        service.release()
        service.release()
        XCTAssertFalse(service.isActive)
    }

    func testNoTimerKeepsItOn() {
        // No auto-off: the assertion outlives any plausible timer tick.
        let service = CaffeinateService()
        service.acquire()
        let deadline = Date().addingTimeInterval(1.2)
        while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertTrue(service.isActive, "it stays on until toggled off")
        service.release()
    }
}
