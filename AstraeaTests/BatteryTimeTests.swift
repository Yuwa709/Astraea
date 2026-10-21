import XCTest
@testable import Astraea

/// Time until full and until empty: the parsing of the Mac's draw, the
/// estimate made from it, and what the two cards say in every state.
final class BatteryTimeTests: XCTestCase {

    /// Captured 2026-10-07 on AC, fully charged: the keys the estimate reads.
    private var onCharger: [String: Any] {
        ["CurrentCapacity": NSNumber(value: 100),
         "AppleRawCurrentCapacity": NSNumber(value: 4642),
         "AppleRawMaxCapacity": NSNumber(value: 4642),
         "Voltage": NSNumber(value: 13303),
         "Amperage": NSNumber(value: 0),
         "ExternalConnected": NSNumber(value: 1),
         "IsCharging": NSNumber(value: 0),
         "FullyCharged": NSNumber(value: 1),
         "AvgTimeToFull": NSNumber(value: 65535),
         "PowerTelemetryData": ["SystemLoad": NSNumber(value: 9209),
                                "SystemPowerIn": NSNumber(value: 9209),
                                "BatteryPower": NSNumber(value: 0)] as [String: Any]]
    }

    private func parse(_ registry: [String: Any],
                       powerSource: [String: Any] = [:]) -> BatterySnapshot {
        BatteryService.snapshot(registry: registry, powerSource: powerSource, adapter: nil,
                                isLowPowerMode: false, now: Date(timeIntervalSince1970: 0))
    }

    // MARK: - Parsing

    func testSystemLoadIsReadInWatts() {
        XCTAssertEqual(parse(onCharger).systemLoadWatts ?? 0, 9.209, accuracy: 1e-9, "mW in the registry")
    }

    /// macOS 27 moved the capacities into `BatteryData` and dropped the
    /// temperature. Captured 2026-10-07 on 27.0.1.
    func testMacOS27ReadsTheCapacitiesFromBatteryData() {
        var registry = onCharger
        for key in ["AppleRawCurrentCapacity", "AppleRawMaxCapacity"] { registry[key] = nil }
        registry["CycleCount"] = NSNumber(value: 88)
        registry["BatteryData"] = ["RemainingCapacity": NSNumber(value: 4642),
                                   "FullChargeCapacity": NSNumber(value: 4642),
                                   "DesignCapacity": NSNumber(value: 4629),
                                   "NominalChargeCapacity": NSNumber(value: 4769)] as [String: Any]
        let s = parse(registry)
        XCTAssertEqual(s.rawCurrentCapacityMilliampHours, 4642)
        XCTAssertEqual(s.rawMaxCapacityMilliampHours, 4642)
        XCTAssertEqual(s.designCapacityMilliampHours, 4629)
        XCTAssertEqual(s.nominalCapacityMilliampHours, 4769)
        XCTAssertEqual(s.displayHealthPercent, 100, "4642 of 4629 design, clamped for display")
        XCTAssertNil(s.temperatureCelsius, "not published on 27")
    }

    /// Where both exist, the top-level key wins: 14...26 read as before.
    func testTheTopLevelKeyWinsOverBatteryData() {
        var registry = onCharger
        registry["BatteryData"] = ["RemainingCapacity": NSNumber(value: 1)] as [String: Any]
        XCTAssertEqual(parse(registry).rawCurrentCapacityMilliampHours, 4642)
    }

    func testAMacWithoutTelemetryHasNoSystemLoad() {
        var registry = onCharger
        registry["PowerTelemetryData"] = nil
        XCTAssertNil(parse(registry).systemLoadWatts)
        registry["PowerTelemetryData"] = "not a dictionary"
        XCTAssertNil(parse(registry).systemLoadWatts)
    }

    /// Off the charger a zero is not a reading: it falls through to the
    /// estimate, the way "still calculating" (-1) does.
    func testAZeroTimeToEmptyOnBatteryIsNotAReading() {
        var registry = onCharger
        registry["ExternalConnected"] = NSNumber(value: 0)
        XCTAssertNil(parse(registry, powerSource: ["Time to Empty": NSNumber(value: 0)]).timeToEmptyMinutes)
        XCTAssertNil(parse(registry, powerSource: ["Time to Empty": NSNumber(value: -1)]).timeToEmptyMinutes)
        XCTAssertEqual(parse(registry, powerSource: ["Time to Empty": NSNumber(value: 312)]).timeToEmptyMinutes, 312)
    }

    // MARK: - The estimate

    /// 4642 mAh at 13.303 V is 61.75 Wh; at 9.209 W that lasts 6.7 hours.
    func testTheEstimateIsEnergyOverDraw() {
        XCTAssertEqual(BatterySnapshot.estimatedMinutesToEmpty(milliampHours: 4642, millivolts: 13303,
                                                               watts: 9.209), 402)
    }

    func testTheEstimateRefusesWhatItCannotDivide() {
        XCTAssertNil(BatterySnapshot.estimatedMinutesToEmpty(milliampHours: nil, millivolts: 13303, watts: 9))
        XCTAssertNil(BatterySnapshot.estimatedMinutesToEmpty(milliampHours: 0, millivolts: 13303, watts: 9))
        XCTAssertNil(BatterySnapshot.estimatedMinutesToEmpty(milliampHours: 4642, millivolts: nil, watts: 9))
        XCTAssertNil(BatterySnapshot.estimatedMinutesToEmpty(milliampHours: 4642, millivolts: 13303, watts: nil))
        XCTAssertNil(BatterySnapshot.estimatedMinutesToEmpty(milliampHours: 4642, millivolts: 13303, watts: 0.2),
                     "a glitch-low draw would promise days")
    }

    func testTheEstimateIsCappedAtADay() {
        XCTAssertEqual(BatterySnapshot.estimatedMinutesToEmpty(milliampHours: 4642, millivolts: 13303,
                                                               watts: 1.5), 24 * 60)
    }

    /// The system load when there is one; the pack's own discharge on
    /// battery otherwise; never the pack's current while it charges.
    func testTheDrawPrefersTheSystemLoad() {
        var snapshot = BatterySnapshot()
        snapshot.voltageMillivolts = 11312
        snapshot.amperageMilliamps = -743
        snapshot.isExternalConnected = false
        XCTAssertEqual(BatteryService.drawWatts(snapshot) ?? 0, 8.405, accuracy: 0.001, "discharge fallback")

        snapshot.systemLoadWatts = 7
        XCTAssertEqual(BatteryService.drawWatts(snapshot), 7)

        snapshot.systemLoadWatts = nil
        snapshot.amperageMilliamps = 1200
        snapshot.isExternalConnected = true
        XCTAssertNil(BatteryService.drawWatts(snapshot), "charging current is power in, not use")
    }

    func testTheDrawIsSmoothedOverHalfAMinute() {
        let start = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(BatteryService.smoothed(previous: nil, reading: 20, at: start), 20,
                       "the first reading of a session is taken as-is")
        let later = start.addingTimeInterval(BatteryService.loadSmoothingSeconds)
        let smoothed = BatteryService.smoothed(previous: (10, start), reading: 20, at: later)
        XCTAssertEqual(smoothed, 10 + 10 * (1 - exp(-1)), accuracy: 1e-9, "one time constant: 63% of the way")
        XCTAssertEqual(BatteryService.smoothed(previous: (10, start), reading: 20, at: start), 10,
                       "no time elapsed, no movement")
    }

    // MARK: - The cards

    private func card(_ configure: (inout BatterySnapshot) -> Void) -> BatterySnapshot {
        var snapshot = BatterySnapshot()
        configure(&snapshot)
        return snapshot
    }

    func testUntilFull() {
        XCTAssertEqual(BatteryTime.untilFull(nil), .init(value: "—", detail: "Battery unavailable"))
        XCTAssertEqual(BatteryTime.untilFull(card {
            $0.isExternalConnected = true; $0.isCharging = true; $0.timeToFullMinutes = 47
        }), .init(value: "47m", detail: "Charging"))
        XCTAssertEqual(BatteryTime.untilFull(card {
            $0.isExternalConnected = true; $0.isCharging = true
        }), .init(value: "—", detail: "Estimating…"))
        XCTAssertEqual(BatteryTime.untilFull(card {
            $0.isExternalConnected = true; $0.isFullyCharged = true
        }), .init(value: "Full", detail: "Charged"))
        XCTAssertEqual(BatteryTime.untilFull(card {
            $0.isExternalConnected = true; $0.isCharging = false
        }), .init(value: "On hold", detail: "Plugged in, not charging"))
        XCTAssertEqual(BatteryTime.untilFull(card { $0.isExternalConnected = false }),
                       .init(value: "—", detail: "Not plugged in"))
    }

    func testUntilEmpty() {
        XCTAssertEqual(BatteryTime.untilEmpty(nil), .init(value: "—", detail: "Battery unavailable"))
        XCTAssertEqual(BatteryTime.untilEmpty(card {
            $0.isExternalConnected = false; $0.timeToEmptyMinutes = 312; $0.estimatedTimeToEmptyMinutes = 200
        }), .init(value: "5h 10m", detail: "macOS estimate"), "macOS's own figure wins on battery")
        XCTAssertEqual(BatteryTime.untilEmpty(card {
            $0.isExternalConnected = false; $0.estimatedTimeToEmptyMinutes = 200
        }), .init(value: "3h 20m", detail: "At current use"), "ours while macOS calculates")
        XCTAssertEqual(BatteryTime.untilEmpty(card {
            $0.isExternalConnected = true; $0.estimatedTimeToEmptyMinutes = 402
        }), .init(value: "On charger", detail: "Estimates once unplugged"),
            "no guess while plugged in, even one that is to hand")
        XCTAssertEqual(BatteryTime.untilEmpty(card { $0.isExternalConnected = false }),
                       .init(value: "—", detail: "Estimating…"))
    }

    func testDurationsPastAnHourRoundToFiveMinutes() {
        XCTAssertEqual(BatteryTime.formatted(0), "0m")
        XCTAssertEqual(BatteryTime.formatted(47), "47m")
        XCTAssertEqual(BatteryTime.formatted(59), "59m")
        XCTAssertEqual(BatteryTime.formatted(60), "1h")
        XCTAssertEqual(BatteryTime.formatted(118), "2h", "rounds up onto the hour")
        XCTAssertEqual(BatteryTime.formatted(123), "2h 5m")
        XCTAssertEqual(BatteryTime.formatted(402), "6h 40m")
    }
}
