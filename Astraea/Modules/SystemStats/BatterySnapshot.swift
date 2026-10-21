import Foundation

/// One reading of the battery, as the stats page shows it.
///
/// Every field is optional except `timestamp` and `isLowPowerMode`: a value
/// that cannot be read is nil, never a zero standing in for one. Zeroes are
/// indistinguishable from real readings — a battery genuinely can sit at 0 mA
/// — so a missing key must not produce one.
///
/// Live state only, never persisted: the charge history that once wrote
/// these to disk was removed on 2026-10-07.
struct BatterySnapshot: Equatable {

    var timestamp: Date = .distantPast

    // MARK: Charge

    /// Charge percentage, 0...100, read from `CurrentCapacity`.
    ///
    /// **Used directly, never divided.** On Apple Silicon `CurrentCapacity`
    /// already *is* the percentage and `MaxCapacity` is the constant 100 —
    /// the pre-Apple-Silicon `current / max` formula is a trap that happens
    /// to look right. Dividing the raw pair is wrong too: measured
    /// 2026-09-01, 1614/4610 = 35.0% while the system reported 36%.
    var percentage: Int?

    /// Raw charge in mAh (`AppleRawCurrentCapacity`): what is left in the
    /// pack, and the energy the time-to-empty estimate divides. Never used
    /// to derive `percentage`.
    var rawCurrentCapacityMilliampHours: Int?
    /// Raw full-charge capacity in mAh (`AppleRawMaxCapacity`).
    var rawMaxCapacityMilliampHours: Int?
    /// Factory capacity in mAh (`DesignCapacity`).
    var designCapacityMilliampHours: Int?
    /// The gauge's other full-charge figure (`NominalChargeCapacity`). Runs
    /// optimistic — 4737 against a 4629 design capacity, i.e. 102% — which
    /// is why health below is derived from the raw figure instead. Stored so
    /// a later screen can show both without another migration.
    var nominalCapacityMilliampHours: Int?

    var cycleCount: Int?

    /// Battery health as a percentage of design capacity, **unclamped**.
    ///
    /// Stored raw so the number keeps its meaning: a pack that measures
    /// above 100% of design is a real observation about the cell, not an
    /// error, and clamping it here would erase that. Display goes through
    /// `displayHealthPercent`,
    /// which clamps — a "102% degraded" figure reads as a bug to a user.
    var healthPercent: Double?

    /// Health for showing to a person: never above 100.
    var displayHealthPercent: Double? {
        healthPercent.map { min(100, $0) }
    }

    /// macOS's own one-word verdict on the pack, from the IOPS power-source
    /// description's `BatteryHealth` — read "Good" on the captured hardware.
    ///
    /// Stored and displayed verbatim. The capacity percentage above is a
    /// ratio this app computes; this is the system's judgement, and the two
    /// are deliberately kept apart so no screen implies Astraea decided
    /// whether a battery is healthy.
    var iopsBatteryHealth: String?

    /// The IOPS `BatteryHealthCondition`, e.g. "Service Battery". Empty on a
    /// pack with nothing to report, which is stored as nil rather than as an
    /// empty string so a view can test one thing.
    var iopsBatteryCondition: String?

    /// What the system says about the pack, if it says anything.
    var conditionDescription: String? {
        iopsBatteryCondition ?? iopsBatteryHealth
    }

    // MARK: Power

    /// Battery temperature in °C, from `Temperature` (centi-°C).
    var temperatureCelsius: Double?
    /// Pack voltage in millivolts.
    var voltageMillivolts: Int?
    /// Pack current in milliamps. **Signed**: negative is discharging.
    var amperageMilliamps: Int?

    /// Instantaneous power draw in watts, |V x A|. Derived, not read.
    var watts: Double? {
        guard let voltageMillivolts, let amperageMilliamps else { return nil }
        return abs(Double(voltageMillivolts) * Double(amperageMilliamps)) / 1_000_000
    }

    /// What the whole Mac is drawing right now, in watts, from the
    /// registry's `PowerTelemetryData.SystemLoad` (milliwatts). Reported on
    /// the charger too, where the pack's own current reads 0, so the Power
    /// card has a real number there. Captured 2026-10-07, on AC and fully
    /// charged:
    /// `SystemLoad = 9209`, equal to `SystemVoltageIn 20281 mV x
    /// SystemCurrentIn 454 mA`, so the unit is mW.
    var systemLoadWatts: Double?

    // MARK: State

    var isCharging: Bool?
    var isFullyCharged: Bool?
    var isExternalConnected: Bool?
    /// Not a battery-registry value: `ProcessInfo.isLowPowerModeEnabled`.
    /// Non-optional because that API always answers.
    var isLowPowerMode: Bool = false

    // MARK: Time

    /// Minutes until empty, from the IOPS power-source description's
    /// `Time to Empty` — **the only time source read**. The registry's
    /// `TimeRemaining` is deliberately never consulted, not even as a
    /// fallback: the two disagreed by 11 minutes at the same instant, and
    /// IOPS is what `pmset` and System Settings report.
    var timeToEmptyMinutes: Int?
    /// Minutes until full. Nil whenever not charging — see
    /// `BatteryService.notApplicableSentinel`.
    var timeToFullMinutes: Int?

    /// Astraea's own estimate of minutes until empty, for the minutes off
    /// the charger while macOS is still calculating. Never on the charger:
    /// there is no use to estimate. Set by `BatteryService` from a smoothed
    /// load, never by the parser — one reading is too jumpy to divide by.
    var estimatedTimeToEmptyMinutes: Int?

    /// The time to show: macOS's estimate when it has one, else ours.
    var bestTimeToEmptyMinutes: Int? {
        timeToEmptyMinutes ?? estimatedTimeToEmptyMinutes
    }

    /// The draw an estimate is computed from: below this, the division
    /// would promise days. Real Macs idle at several watts; a reading this
    /// low is a telemetry glitch, not a Mac that will run for a week.
    static let minimumEstimateWatts = 1.0
    /// Estimates are capped at a day. Past that, the number says nothing a
    /// person can act on.
    static let maximumEstimateMinutes = 24 * 60

    /// How long `milliampHours` lasts at `watts`: the charge times the pack
    /// voltage is the energy left, divided by the draw. The voltage is the
    /// present one, which sags as the pack drains, so this runs a little
    /// optimistic near full — an estimate, labelled as one.
    static func estimatedMinutesToEmpty(milliampHours: Int?, millivolts: Int?,
                                        watts: Double?) -> Int? {
        guard let milliampHours, milliampHours > 0,
              let millivolts, millivolts > 0,
              let watts, watts >= minimumEstimateWatts else { return nil }
        let wattHours = Double(milliampHours) * Double(millivolts) / 1_000_000
        let minutes = Int((wattHours / watts * 60).rounded())
        return min(minutes, maximumEstimateMinutes)
    }

    // MARK: Adapter

    /// Present only while an adapter is attached. All nil on battery, which
    /// is a normal state and not an error.
    var adapterIsPresent: Bool?

    /// Adapter rating in watts, from the observed `Watts` key.
    ///
    /// Captured live 2026-09-02 with a USB-C PD charger attached:
    /// `Watts = 75` (NSNumber), consistent with the same dictionary's
    /// `AdapterVoltage = 20000` mV x `Current = 3750` mA. Both
    /// `IOPSCopyExternalPowerAdapterDetails()` and the registry's
    /// `AdapterDetails` carry identical values; the IOPS copy is what the
    /// service reads.
    var adapterWatts: Int?

    /// The adapter's own description, from the observed `Description` key.
    /// Read as "pd charger" on the captured hardware — a category, not a
    /// product name, so it is shown as-is and never parsed.
    var adapterName: String?

    // TODO: only ONE adapter has been observed — a 75W USB-C PD charger.
    // `IsWireless` (0 here) and `AdapterPowerTier` suggest other shapes
    // exist. Before a UI relies on `adapterName` reading as a product name,
    // capture a second adapter type (MagSafe, or a lower-tier USB-C brick)
    // and confirm `Description` and `Watts` behave the same way. The other
    // keys seen live and deliberately not modelled yet: AdapterID,
    // AdapterVoltage, Current, FamilyCode, IsWireless, PMUConfiguration,
    // UsbHvcMenu, UsbHvcHvcIndex.
}
