import XCTest
import IOKit.ps
@testable import Astraea

/// The wing's reading: IOPS for charge and power source, the registry for
/// charging state and Apple's time to full, Astraea's estimate for time to
/// empty.
final class BatteryWingMonitorTests: XCTestCase {

    private func powerSource(current: Int = 87, max: Int = 100,
                             onAC: Bool = false,
                             charging: Bool = false,
                             toEmpty: Int = 222,
                             toFull: Int = -1) -> [String: Any] {
        [
            kIOPSCurrentCapacityKey: NSNumber(value: current),
            kIOPSMaxCapacityKey: NSNumber(value: max),
            kIOPSPowerSourceStateKey: onAC ? kIOPSACPowerValue : kIOPSBatteryPowerValue,
            kIOPSIsChargingKey: NSNumber(value: charging),
            kIOPSTimeToEmptyKey: NSNumber(value: toEmpty),
            kIOPSTimeToFullChargeKey: NSNumber(value: toFull)
        ]
    }

    private func battery(charging: Bool? = nil, full: Bool? = nil,
                         toFull: Int? = nil) -> BatterySnapshot {
        var snapshot = BatterySnapshot()
        snapshot.isCharging = charging
        snapshot.isFullyCharged = full
        snapshot.timeToFullMinutes = toFull
        return snapshot
    }

    private func reading(_ source: [String: Any], _ battery: BatterySnapshot = BatterySnapshot(),
                         estimate: Int? = nil) -> BatteryWingMonitor.Reading? {
        BatteryWingMonitor.reading(powerSource: source, battery: battery,
                                   estimatedMinutesToEmpty: estimate)
    }

    func testOffTheChargerTimeToEmptyIsOurEstimateNotMacOS() {
        let r = reading(powerSource(toEmpty: 222), estimate: 400)
        XCTAssertEqual(r?.percentage, 87)
        XCTAssertEqual(r?.minutesToEmpty, 400, "IOPS's 222 is never shown")
        XCTAssertEqual(r?.wingMinutes, 400)
    }

    func testOnTheChargerTimeToFullIsTheGaugesNotIOPS() {
        let r = reading(powerSource(onAC: true, charging: false, toFull: -1),
                        battery(charging: true, toFull: 178), estimate: 400)
        XCTAssertEqual(r?.minutesToFull, 178)
        XCTAssertEqual(r?.wingMinutes, 178)
        XCTAssertNil(r?.minutesToEmpty, "no estimate on the charger")
        XCTAssertEqual(r?.isCharging, true, "the registry's flag wins over a lagging IOPS")
    }

    func testTheWingSwitchesWithThePowerSource() {
        let gauge = battery(toFull: 120)
        XCTAssertEqual(reading(powerSource(onAC: true), gauge, estimate: 300)?.wingMinutes, 120)
        XCTAssertEqual(reading(powerSource(onAC: false), gauge, estimate: 300)?.wingMinutes, 300)
    }

    func testAMissingTimeHoldsAPlaceholderUnlessFull() {
        let charging = reading(powerSource(onAC: true), battery(charging: true))
        XCTAssertNil(charging?.wingMinutes)
        XCTAssertEqual(charging?.wingShowsTime, true)
        let full = reading(powerSource(current: 100, onAC: true), battery(charging: false, full: true))
        XCTAssertEqual(full?.wingShowsTime, false, "a full battery on the charger leaves the wing blank")
        let unplugged = reading(powerSource(), estimate: nil)
        XCTAssertEqual(unplugged?.wingShowsTime, true)
    }

    func testIOPSFlagsAreTheFallbackForARegistryWithoutThem() {
        XCTAssertEqual(reading(powerSource(onAC: true, charging: true))?.isCharging, true)
    }

    func testPercentageScalesByMaxCapacity() {
        XCTAssertEqual(reading(powerSource(current: 1614, max: 4610))?.percentage, 35)
    }

    func testMissingOrZeroCapacityIsNoReading() {
        XCTAssertNil(reading([:]))
        XCTAssertNil(reading(powerSource(max: 0)))
    }

    func testEstimateRoundsToFiveMinutesPastAnHour() {
        XCTAssertEqual(BatteryWingMonitor.roundedEstimate(568), 570)
        XCTAssertEqual(BatteryWingMonitor.roundedEstimate(47), 47)
    }

    func testTimeFormat() {
        XCTAssertEqual(BatteryWingTimeLeft.format(222), "3:42")
        XCTAssertEqual(BatteryWingTimeLeft.format(5), "0:05")
    }
}
