import XCTest
@testable import Astraea

/// Parsing, against fixtures rather than a battery.
///
/// Values in `live` are the real AppleSmartBattery dump from this machine
/// (M4 MacBook Air, macOS 26.5.2, captured 2026-09-01), so the expectations
/// below are observations, not documentation. Everything else is a
/// degradation case: keys missing, dictionaries empty, no battery at all.
@MainActor
final class BatteryServiceTests: XCTestCase {

    /// The observed registry, trimmed to the keys the service reads.
    private var live: [String: Any] {
        [
            "CurrentCapacity": NSNumber(value: 36),
            "AppleRawCurrentCapacity": NSNumber(value: 1614),
            "AppleRawMaxCapacity": NSNumber(value: 4610),
            "DesignCapacity": NSNumber(value: 4629),
            "NominalChargeCapacity": NSNumber(value: 4737),
            "CycleCount": NSNumber(value: 77),
            "Temperature": NSNumber(value: 3035),
            "Voltage": NSNumber(value: 11312),
            "Amperage": NSNumber(value: -743),
            "IsCharging": NSNumber(value: 0),
            "FullyCharged": NSNumber(value: 0),
            "ExternalConnected": NSNumber(value: 0),
            "AvgTimeToFull": NSNumber(value: 65535),
            "TimeRemaining": NSNumber(value: 143),
        ]
    }

    private var livePowerSource: [String: Any] {
        ["Time to Empty": NSNumber(value: 126),
         "Type": "InternalBattery",
         "BatteryHealth": "Good"]
    }

    private func snapshot(registry: [String: Any]? = nil,
                          powerSource: [String: Any]? = nil,
                          adapter: [String: Any]? = nil,
                          lowPower: Bool = false) -> BatterySnapshot {
        BatteryService.snapshot(registry: registry ?? live,
                                powerSource: powerSource ?? livePowerSource,
                                adapter: adapter,
                                isLowPowerMode: lowPower,
                                now: Date(timeIntervalSince1970: 1_000_000))
    }

    // MARK: - Units and spelling

    func testParsesTheObservedRegistry() {
        let s = snapshot()
        XCTAssertEqual(s.percentage, 36)
        XCTAssertEqual(s.cycleCount, 77)
        XCTAssertEqual(s.temperatureCelsius ?? 0, 30.35, accuracy: 0.001, "centi-°C")
        XCTAssertEqual(s.voltageMillivolts, 11312)
        XCTAssertEqual(s.amperageMilliamps, -743, "signed; negative is discharging")
        XCTAssertEqual(s.watts ?? 0, 8.40, accuracy: 0.01, "|V x A|")
        XCTAssertEqual(s.isCharging, false)
        XCTAssertEqual(s.isExternalConnected, false)
    }

    /// The percentage is `CurrentCapacity` verbatim. Deriving it from the
    /// raw pair gives 1614/4610 = 35.0%, a point off what the system says.
    func testPercentageComesFromCurrentCapacityAndNotTheRawRatio() {
        let s = snapshot()
        XCTAssertEqual(s.percentage, 36)
        let rawRatio = Double(s.rawCurrentCapacityMilliampHours ?? 0)
            / Double(s.rawMaxCapacityMilliampHours ?? 1) * 100
        XCTAssertEqual(rawRatio, 35.0, accuracy: 0.1)
        XCTAssertNotEqual(s.percentage, Int(rawRatio.rounded()),
                          "the raw ratio disagrees; percentage must not be derived from it")
    }

    /// `MaxCapacity` is the constant 100 on Apple Silicon. Health must come
    /// from the raw figure over design capacity, not from it.
    func testHealthIgnoresMaxCapacityAndUsesRawOverDesign() {
        var registry = live
        registry["MaxCapacity"] = NSNumber(value: 100)
        let s = snapshot(registry: registry)
        XCTAssertEqual(s.healthPercent ?? 0, 99.59, accuracy: 0.01)
    }

    /// Stored unclamped, clamped only for display: a pack above design
    /// capacity is a real reading, but "102%" reads as a bug to a user.
    func testHealthIsStoredUnclampedAndClampedForDisplay() {
        var registry = live
        registry["AppleRawMaxCapacity"] = NSNumber(value: 4737) // the nominal figure
        let s = snapshot(registry: registry)
        XCTAssertEqual(s.healthPercent ?? 0, 102.33, accuracy: 0.01, "stored raw")
        XCTAssertEqual(s.displayHealthPercent ?? 0, 100, accuracy: 0.001, "clamped")
    }

    func test65535MapsToNil() {
        XCTAssertNil(snapshot().timeToFullMinutes, "AvgTimeToFull 65535 is a sentinel")
        var registry = live
        registry["AvgTimeToFull"] = NSNumber(value: 42)
        XCTAssertEqual(snapshot(registry: registry).timeToFullMinutes, 42)
    }

    func testTimeRemainingComesFromIOPSAndTheRegistryKeyIsIgnored() {
        let s = snapshot()
        XCTAssertEqual(s.timeToEmptyMinutes, 126, "IOPS Time to Empty")
        // The fixture's registry carries TimeRemaining = 143. Nothing may
        // surface it, including as a fallback when IOPS is silent.
        let withoutIOPS = snapshot(powerSource: [:])
        XCTAssertNil(withoutIOPS.timeToEmptyMinutes,
                     "registry TimeRemaining must never be read, not even as a fallback")
    }

    // MARK: - Booleans stored as Int32

    func testIntegerBackedBooleansParseBothWays() {
        var registry = live
        registry["IsCharging"] = NSNumber(value: 1)
        registry["ExternalConnected"] = NSNumber(value: 1)
        let s = snapshot(registry: registry)
        XCTAssertEqual(s.isCharging, true)
        XCTAssertEqual(s.isExternalConnected, true)
    }

    /// Why the parsing goes through NSNumber rather than `as? Bool`.
    ///
    /// Bridging to Bool works for exactly 0 and 1 and yields nil for every
    /// other integer, so a flag reporting anything else would read as a
    /// missing key — silently nil instead of visibly wrong. Registry flags
    /// are Int32 with no such guarantee (`PMUConfigured` reads 3488).
    func testBoolBridgingIsOnlySafeForZeroAndOne() {
        XCTAssertEqual(NSNumber(value: 0) as? Bool, false)
        XCTAssertEqual(NSNumber(value: 1) as? Bool, true)
        XCTAssertNil(NSNumber(value: 2) as? Bool, "the cliff this avoids")
        XCTAssertNil(NSNumber(value: 3488) as? Bool)

        // The NSNumber path has no cliff: any non-zero is true.
        let s = snapshot(registry: ["IsCharging": NSNumber(value: 2)])
        XCTAssertEqual(s.isCharging, true, "non-zero is true, not missing")
    }

    // MARK: - Degradation

    func testMissingKeysDegradeToNilRatherThanCrashing() {
        let s = snapshot(registry: [:], powerSource: [:])
        XCTAssertNil(s.percentage)
        XCTAssertNil(s.cycleCount)
        XCTAssertNil(s.temperatureCelsius)
        XCTAssertNil(s.voltageMillivolts)
        XCTAssertNil(s.amperageMilliamps)
        XCTAssertNil(s.watts)
        XCTAssertNil(s.healthPercent)
        XCTAssertNil(s.displayHealthPercent)
        XCTAssertNil(s.isCharging)
        XCTAssertNil(s.timeToEmptyMinutes)
        XCTAssertNil(s.timeToFullMinutes)
        XCTAssertEqual(s.isLowPowerMode, false, "always answers; never nil")
    }

    /// Wrong-typed values are missing values, not crashes.
    func testWronglyTypedValuesDegradeToNil() {
        let s = snapshot(registry: ["CurrentCapacity": "thirty-six",
                                    "Temperature": NSNull(),
                                    "Voltage": ["nested": 1]])
        XCTAssertNil(s.percentage)
        XCTAssertNil(s.temperatureCelsius)
        XCTAssertNil(s.voltageMillivolts)
    }

    func testZeroDesignCapacityDoesNotDivideByZero() {
        var registry = live
        registry["DesignCapacity"] = NSNumber(value: 0)
        XCTAssertNil(snapshot(registry: registry).healthPercent)
    }

    // MARK: - Adapter

    /// The ordinary on-battery state: `IOPSCopyExternalPowerAdapterDetails`
    /// returns nil. A valid snapshot, not an error.
    func testNilAdapterIsANormalSnapshot() {
        let s = snapshot(adapter: nil)
        XCTAssertEqual(s.adapterIsPresent, false)
        XCTAssertEqual(s.percentage, 36, "the rest of the snapshot is unaffected")
    }

    /// The empty-`AdapterDetails` fixture: the dictionary exists but holds
    /// nothing useful, which is what the hardware actually reports on
    /// battery (only `FamilyCode`, no wattage key).
    func testEmptyAdapterDetailsIsANormalSnapshot() {
        let s = snapshot(adapter: [:])
        XCTAssertEqual(s.adapterIsPresent, false)
        XCTAssertEqual(s.cycleCount, 77)
    }

    func testAdapterPresentWhenTheDictionaryHasContent() {
        // Key spelling deliberately arbitrary: nothing reads a named adapter
        // key yet, because none has been observed live. See the TODO on
        // BatterySnapshot.
        let s = snapshot(adapter: ["SomeObservedKey": NSNumber(value: 1)])
        XCTAssertEqual(s.adapterIsPresent, true)
    }

    // MARK: - Charging, from the live AC capture

    /// Registry and IOPS values captured 2026-09-02 with a 75W USB-C PD
    /// charger attached at 73%.
    private var charging: [String: Any] {
        ["CurrentCapacity": NSNumber(value: 73),
         "AppleRawMaxCapacity": NSNumber(value: 4613),
         "DesignCapacity": NSNumber(value: 4629),
         "CycleCount": NSNumber(value: 77),
         "Voltage": NSNumber(value: 12816),
         "Amperage": NSNumber(value: 2423),
         "IsCharging": NSNumber(value: 1),
         "FullyCharged": NSNumber(value: 0),
         "ExternalConnected": NSNumber(value: 1),
         "ExternalChargeCapable": NSNumber(value: 1),
         "AvgTimeToFull": NSNumber(value: 71),
         "AvgTimeToEmpty": NSNumber(value: 65535),
         "TimeRemaining": NSNumber(value: 71)]
    }

    private var chargingPowerSource: [String: Any] {
        ["Time to Empty": NSNumber(value: 0),
         "Time to Full Charge": NSNumber(value: 71),
         "Is Charging": NSNumber(value: 1),
         "Power Source State": "AC Power",
         "Type": "InternalBattery"]
    }

    /// The observed adapter dictionary, verbatim from
    /// IOPSCopyExternalPowerAdapterDetails().
    private var liveAdapter: [String: Any] {
        ["Watts": NSNumber(value: 75),
         "Description": "pd charger",
         "AdapterVoltage": NSNumber(value: 20000),
         "Current": NSNumber(value: 3750),
         "IsWireless": NSNumber(value: 0),
         "AdapterID": NSNumber(value: 0),
         "AdapterPowerTier": NSNumber(value: 2)]
    }

    func testParsesTheChargingState() {
        let s = snapshot(registry: charging, powerSource: chargingPowerSource, adapter: liveAdapter)
        XCTAssertEqual(s.isCharging, true)
        XCTAssertEqual(s.isExternalConnected, true)
        XCTAssertEqual(s.isFullyCharged, false)
        XCTAssertEqual(s.amperageMilliamps, 2423, "positive while charging")
        XCTAssertEqual(s.watts ?? 0, 31.06, accuracy: 0.01)
        XCTAssertEqual(s.timeToFullMinutes, 71)
    }

    /// IOPS reports `Time to Empty = 0` on AC. Zero is not a reading — it
    /// would put "0 minutes remaining" on a machine that is filling up.
    func testTimeToEmptyIsNilWhileOnExternalPower() {
        let s = snapshot(registry: charging, powerSource: chargingPowerSource, adapter: liveAdapter)
        XCTAssertNil(s.timeToEmptyMinutes, "meaningless while plugged in")
        XCTAssertEqual(s.timeToFullMinutes, 71, "the useful one is still there")
    }

    /// Adapter fields come only from keys observed on hardware.
    func testAdapterFieldsPopulateFromObservedKeys() {
        let s = snapshot(registry: charging, powerSource: chargingPowerSource, adapter: liveAdapter)
        XCTAssertEqual(s.adapterIsPresent, true)
        XCTAssertEqual(s.adapterWatts, 75)
        XCTAssertEqual(s.adapterName, "pd charger")
        // Cross-check against the same dictionary's own volts x amps.
        let derived = 20000.0 * 3750.0 / 1_000_000
        XCTAssertEqual(Double(s.adapterWatts ?? 0), derived, accuracy: 0.5)
    }

    /// An adapter dictionary that lacks the keys still yields a valid
    /// snapshot — a different adapter shape must not blank the battery.
    func testAdapterWithoutWattsStillProducesASnapshot() {
        let s = snapshot(registry: charging, powerSource: chargingPowerSource,
                         adapter: ["FamilyCode": NSNumber(value: -536854518)])
        XCTAssertEqual(s.adapterIsPresent, true)
        XCTAssertNil(s.adapterWatts)
        XCTAssertNil(s.adapterName)
        XCTAssertEqual(s.percentage, 73)
    }

    /// Sampling must not run for nobody: hard rule 9.
    func testServiceDoesNotSampleUntilObservedAndStopsAfterwards() {
        let service = BatteryService()
        XCTAssertNil(service.snapshot, "no sample before anyone is watching")
        service.start()
        XCTAssertNotNil(service.snapshot, "start() samples immediately")
        service.stop()
        // Balanced start/stop leaves nothing scheduled; the snapshot stays
        // as the last reading rather than being wiped.
        XCTAssertNotNil(service.snapshot)
    }
}
