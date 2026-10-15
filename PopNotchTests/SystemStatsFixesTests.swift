import XCTest
@testable import PopNotch

/// A Mac with no battery, and a zero time-to-full while charging.
final class BatteryEdgeCaseTests: XCTestCase {

    private func parse(_ registry: [String: Any]) -> BatterySnapshot {
        BatteryService.snapshot(registry: registry, powerSource: [:], adapter: nil,
                                isLowPowerMode: false, now: Date(timeIntervalSince1970: 0))
    }

    // MARK: - No battery

    func testNoRegistryAndNoPowerSourceMeansNoBattery() {
        XCTAssertFalse(BatteryService.hasBattery(registry: [:], powerSource: [:]))
    }

    func testEitherSourceMeansABattery() {
        XCTAssertTrue(BatteryService.hasBattery(
            registry: ["CurrentCapacity": NSNumber(value: 50)], powerSource: [:]))
        XCTAssertTrue(BatteryService.hasBattery(
            registry: [:], powerSource: ["Type": "InternalBattery"]))
    }

    /// What the page shows once the service publishes nil for a Mac with no
    /// battery: the "Battery unavailable" branches, not "On battery".
    func testNoBatteryReadsAsUnavailableOnTheCards() {
        XCTAssertEqual(BatteryTime.untilFull(nil).detail, "Battery unavailable")
        XCTAssertEqual(BatteryTime.untilEmpty(nil).detail, "Battery unavailable")
    }

    // MARK: - AvgTimeToFull = 0

    func testZeroTimeToFullWhileChargingIsNotAReading() {
        let snapshot = parse(["CurrentCapacity": NSNumber(value: 80),
                              "ExternalConnected": NSNumber(value: 1),
                              "IsCharging": NSNumber(value: 1),
                              "FullyCharged": NSNumber(value: 0),
                              "AvgTimeToFull": NSNumber(value: 0)])
        XCTAssertNil(snapshot.timeToFullMinutes)
        XCTAssertEqual(BatteryTime.untilFull(snapshot),
                       .init(value: "—", detail: "Estimating…"), "never \"0m\" while charging")
    }

    func testZeroTimeToFullWhenFullReadsFull() {
        let snapshot = parse(["CurrentCapacity": NSNumber(value: 100),
                              "ExternalConnected": NSNumber(value: 1),
                              "IsCharging": NSNumber(value: 0),
                              "FullyCharged": NSNumber(value: 1),
                              "AvgTimeToFull": NSNumber(value: 0)])
        XCTAssertEqual(BatteryTime.untilFull(snapshot), .init(value: "Full", detail: "Charged"))
    }

    func testARealTimeToFullStillReads() {
        let snapshot = parse(["ExternalConnected": NSNumber(value: 1),
                              "IsCharging": NSNumber(value: 1),
                              "AvgTimeToFull": NSNumber(value: 1)])
        XCTAssertEqual(snapshot.timeToFullMinutes, 1)
    }
}

/// The disk is read on page open and then at most every 30 seconds.
final class DiskSamplingCadenceTests: XCTestCase {

    func testFirstSampleReadsTheDisk() {
        XCTAssertTrue(SystemStatsService.diskReadIsDue(lastReadAt: nil, now: Date()))
    }

    func testTicksInsideTheIntervalReuseTheLastReading() {
        let start = Date(timeIntervalSince1970: 1_000)
        for seconds in [2.0, 10, 29.9] {
            XCTAssertFalse(SystemStatsService.diskReadIsDue(
                lastReadAt: start, now: start.addingTimeInterval(seconds)))
        }
    }

    func testTheIntervalElapsingReadsAgain() {
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(SystemStatsService.diskReadIsDue(
            lastReadAt: start, now: start.addingTimeInterval(SystemStatsService.diskInterval)))
    }
}
