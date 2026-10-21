import Foundation
import IOKit
import IOKit.ps
import AppKit
import Observation
import os

/// Reads the battery and publishes one `BatterySnapshot`.
///
/// Sampling is subscriber-counted and display-sleep aware, matching
/// `SystemStatsService` — hard rule 9: nothing polls while nobody is looking.
///
/// The parsing is a pure static function taking dictionaries, so every
/// degradation path is testable without a battery: missing keys, an empty
/// `AdapterDetails`, a machine with no battery at all.
@MainActor
@Observable
final class BatteryService {

    @ObservationIgnored
    private static let logger = Logger(subsystem: "com.techie.Astraea", category: "Battery")

    /// Five seconds, the floor this task set. Battery state changes on the
    /// order of minutes; anything faster spends power to measure power.
    @ObservationIgnored
    static let interval: TimeInterval = 5

    /// A tenth of the interval: battery state is not time-critical, and
    /// letting the wake-up coalesce with others is free power.
    @ObservationIgnored
    static let tolerance: TimeInterval = 0.5

    private(set) var snapshot: BatterySnapshot?

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private(set) var subscribers = 0
    @ObservationIgnored private var displayAsleep = false

    /// Whether a timer is currently scheduled.
    ///
    /// Exposed so "nothing polls while nobody is looking" is something a test
    /// can assert rather than something a comment claims.
    var isSampling: Bool { timer != nil }

    init() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(displayDidSleep),
                           name: NSWorkspace.screensDidSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(displayDidWake),
                           name: NSWorkspace.screensDidWakeNotification, object: nil)
    }

    deinit {
        timer?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: - Lifecycle

    /// Counted, so several observers can share one service without one
    /// leaving stopping sampling for the rest.
    func start() {
        subscribers += 1
        updateTimer()
    }

    func stop() {
        subscribers = max(0, subscribers - 1)
        updateTimer()
    }

    @objc private func displayDidSleep() {
        displayAsleep = true
        Self.logger.notice("Display asleep; battery sampling suspended")
        updateTimer()
    }

    @objc private func displayDidWake() {
        displayAsleep = false
        Self.logger.notice("Display awake; battery sampling resumes if observed")
        updateTimer()
    }

    private func updateTimer() {
        let shouldRun = subscribers > 0 && !displayAsleep
        guard shouldRun != (timer != nil) else { return }

        if shouldRun {
            sample()
            let timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.sample() }
            }
            timer.tolerance = Self.tolerance
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            Self.logger.notice("Battery sampling started (\(self.subscribers, privacy: .public) subscribers)")
        } else {
            timer?.invalidate()
            timer = nil
            smoothedLoad = nil
            isFirstSampleOfSession = true
            Self.logger.notice("Battery sampling stopped")
        }
    }

    // MARK: - Sampling

    func sample() {
        let now = Date()
        let registry = Self.readRegistry()
        let powerSource = Self.readPowerSource()
        // No battery at all: publish nil, which is what the page's "Battery
        // unavailable" states key off. A snapshot of nils would read as
        // "On battery" and "Estimating…" forever instead.
        guard Self.hasBattery(registry: registry, powerSource: powerSource) else {
            if isFirstSampleOfSession || snapshot != nil {
                Self.logger.notice("No battery found; showing Battery unavailable")
            }
            isFirstSampleOfSession = false
            smoothedLoad = nil
            snapshot = nil
            return
        }
        var next = Self.snapshot(registry: registry,
                                 powerSource: powerSource,
                                 adapter: Self.readAdapter(),
                                 isLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                                 now: now)
        // Off the charger only: on it, the battery is not being used and
        // the owner wants no guess at how long it would last (2026-10-07).
        if next.isExternalConnected != true, let reading = Self.drawWatts(next) {
            let watts = Self.smoothed(previous: smoothedLoad, reading: reading, at: now)
            smoothedLoad = (watts, now)
            next.estimatedTimeToEmptyMinutes = BatterySnapshot.estimatedMinutesToEmpty(
                milliampHours: next.rawCurrentCapacityMilliampHours,
                millivolts: next.voltageMillivolts, watts: watts)
        } else {
            // A plug-in ends the average: the next unplug starts afresh.
            smoothedLoad = nil
        }
        if isFirstSampleOfSession {
            isFirstSampleOfSession = false
            Self.logFirstSample(next, telemetry: registry["PowerTelemetryData"] as? [String: Any])
        }
        snapshot = next
    }

    // MARK: - Time-to-empty estimate

    /// The load average's time constant. A 5-second reading swings with
    /// every burst of work; macOS's own estimate averages over minutes.
    /// Thirty seconds settles within the minute someone looks at the page
    /// and still follows a real change in what the Mac is doing.
    @ObservationIgnored
    nonisolated static let loadSmoothingSeconds: TimeInterval = 30

    /// The smoothed draw and when it was taken. Cleared when sampling
    /// stops: a load from the last time the page was open says nothing
    /// about now.
    @ObservationIgnored private var smoothedLoad: (watts: Double, at: Date)?
    @ObservationIgnored private var isFirstSampleOfSession = true

    /// What the Mac is drawing: the system load, else — should a Mac not
    /// report it — the pack's own discharge. Never the pack's current
    /// while charging, which is power going in, not being used.
    nonisolated static func drawWatts(_ snapshot: BatterySnapshot) -> Double? {
        if let load = snapshot.systemLoadWatts { return load }
        guard snapshot.isExternalConnected != true,
              let amperage = snapshot.amperageMilliamps, amperage < 0 else { return nil }
        return snapshot.watts
    }

    /// An exponential moving average, weighted by the real time between
    /// samples so a late timer tick counts for what it covered. The first
    /// reading of a session is taken as-is.
    nonisolated static func smoothed(previous: (watts: Double, at: Date)?,
                                     reading: Double, at now: Date) -> Double {
        guard let previous else { return reading }
        let elapsed = max(0, now.timeIntervalSince(previous.at))
        let weight = 1 - exp(-elapsed / loadSmoothingSeconds)
        return previous.watts + weight * (reading - previous.watts)
    }

    /// Once per page open, at `.notice` so it survives to be read back: the
    /// numbers the estimate came from, plus the raw telemetry that would
    /// show whether `SystemLoad` includes charging power (only a capture
    /// taken while charging can answer that).
    private static func logFirstSample(_ snapshot: BatterySnapshot, telemetry: [String: Any]?) {
        func value(_ key: String) -> String {
            (telemetry?[key] as? NSNumber).map { "\($0.intValue)" } ?? "nil"
        }
        let iops = snapshot.timeToEmptyMinutes.map(String.init) ?? "nil"
        let estimate = snapshot.estimatedTimeToEmptyMinutes.map(String.init) ?? "nil"
        let full = snapshot.timeToFullMinutes.map(String.init) ?? "nil"
        logger.notice("Battery \(snapshot.percentage ?? -1, privacy: .public)% charging=\(snapshot.isCharging == true, privacy: .public) external=\(snapshot.isExternalConnected == true, privacy: .public) mAh=\(snapshot.rawCurrentCapacityMilliampHours ?? -1, privacy: .public) mV=\(snapshot.voltageMillivolts ?? -1, privacy: .public) mA=\(snapshot.amperageMilliamps ?? 0, privacy: .public) | SystemLoad=\(value("SystemLoad"), privacy: .public) SystemPowerIn=\(value("SystemPowerIn"), privacy: .public) BatteryPower=\(value("BatteryPower"), privacy: .public) mW | toEmpty macOS=\(iops, privacy: .public) estimate=\(estimate, privacy: .public) toFull=\(full, privacy: .public) min")
    }

    // MARK: - Parsing

    /// The gauge's "not applicable" sentinel. `AvgTimeToFull` reads 65535
    /// whenever the pack is not charging; it is not a 45-day estimate.
    nonisolated static let notApplicableSentinel = 65535

    /// Every registry read goes through `NSNumber`, never `as? Bool`.
    ///
    /// These values are stored as Int32, and NSNumber bridges to `Bool` for
    /// **exactly 0 and 1 only** — measured 2026-09-01: `NSNumber(2) as? Bool`
    /// and `NSNumber(3488) as? Bool` are both nil, while 0 and 1 bridge
    /// fine. Nothing constrains a registry flag to 0/1 (`PMUConfigured`
    /// reads 3488, `NotChargingReason` 128), so a flag that ever reports 2
    /// would read as a *missing key* rather than as true, and the field
    /// would silently go nil instead of obviously wrong.
    ///
    /// Reading the number and testing `intValue != 0` has no such cliff, and
    /// keeps a genuine 0 distinguishable from an absent key — which is the
    /// whole contract of this struct's optionals.
    nonisolated private static func number(_ dictionary: [String: Any], _ key: String) -> NSNumber? {
        dictionary[key] as? NSNumber
    }

    nonisolated private static func integer(_ dictionary: [String: Any], _ key: String) -> Int? {
        number(dictionary, key)?.intValue
    }

    nonisolated private static func flag(_ dictionary: [String: Any], _ key: String) -> Bool? {
        number(dictionary, key).map { $0.intValue != 0 }
    }

    /// A duration in minutes, or nil for the sentinel and for negatives.
    nonisolated private static func minutes(_ dictionary: [String: Any], _ key: String) -> Int? {
        guard let value = integer(dictionary, key),
              value != notApplicableSentinel, value >= 0 else { return nil }
        return value
    }

    /// Whether the readings describe a battery at all. Both empty is what a
    /// Mac without one gives: no `AppleSmartBattery` service, and no internal
    /// battery among the IOPS power sources.
    nonisolated static func hasBattery(registry: [String: Any],
                                       powerSource: [String: Any]) -> Bool {
        !registry.isEmpty || !powerSource.isEmpty
    }

    /// Builds a snapshot from already-read dictionaries.
    ///
    /// Pure and `nonisolated` so the tests exercise the real parsing rather
    /// than a re-implementation of it. Any dictionary may be empty; the
    /// result is then a snapshot of nils, which is a valid reading of a
    /// machine whose battery cannot be read, not a failure.
    nonisolated static func snapshot(registry: [String: Any],
                                     powerSource: [String: Any],
                                     adapter: [String: Any]?,
                                     isLowPowerMode: Bool,
                                     now: Date) -> BatterySnapshot {
        var snapshot = BatterySnapshot()
        snapshot.timestamp = now
        snapshot.isLowPowerMode = isLowPowerMode

        // macOS 27 stopped publishing the capacity figures and the
        // temperature at the top level; the capacities now live only in the
        // nested `BatteryData` (captured 2026-10-07 on 27.0.1:
        // `RemainingCapacity = 4642`, `FullChargeCapacity = 4642`,
        // `DesignCapacity = 4629`, `NominalChargeCapacity = 4769`). The
        // top-level key is read first, so macOS 14...26 is unchanged.
        let batteryData = registry["BatteryData"] as? [String: Any] ?? [:]
        func either(_ key: String, _ nestedKey: String) -> Int? {
            integer(registry, key) ?? integer(batteryData, nestedKey)
        }
        snapshot.percentage = integer(registry, "CurrentCapacity")
        snapshot.rawCurrentCapacityMilliampHours = either("AppleRawCurrentCapacity", "RemainingCapacity")
        snapshot.rawMaxCapacityMilliampHours = either("AppleRawMaxCapacity", "FullChargeCapacity")
        snapshot.designCapacityMilliampHours = either("DesignCapacity", "DesignCapacity")
        snapshot.nominalCapacityMilliampHours = either("NominalChargeCapacity", "NominalChargeCapacity")
        snapshot.cycleCount = integer(registry, "CycleCount")

        if let rawMax = snapshot.rawMaxCapacityMilliampHours,
           let design = snapshot.designCapacityMilliampHours, design > 0 {
            snapshot.healthPercent = Double(rawMax) / Double(design) * 100
        }

        // Not published anywhere on macOS 27 — not here, not in
        // `BatteryData`, not by IOPS — so nil there. No card shows it any
        // more; kept for the macOS versions that still report it.
        if let centiCelsius = either("Temperature", "Temperature") {
            snapshot.temperatureCelsius = Double(centiCelsius) / 100
        }
        snapshot.voltageMillivolts = integer(registry, "Voltage")
        snapshot.amperageMilliamps = integer(registry, "Amperage")
        // A nested dictionary; absent on Macs that do not report it, which
        // leaves the estimate to fall back on the pack's own discharge.
        if let telemetry = registry["PowerTelemetryData"] as? [String: Any],
           let milliwatts = integer(telemetry, "SystemLoad"), milliwatts >= 0 {
            snapshot.systemLoadWatts = Double(milliwatts) / 1000
        }

        // The system's own verdict, from the power-source dictionary that
        // was already read for the time estimate — no additional query. Both
        // are shown verbatim; neither is parsed into a verdict of our own.
        snapshot.iopsBatteryHealth = (powerSource["BatteryHealth"] as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
        snapshot.iopsBatteryCondition = (powerSource["BatteryHealthCondition"] as? String)
            .flatMap { $0.isEmpty ? nil : $0 }

        snapshot.isCharging = flag(registry, "IsCharging")
        snapshot.isFullyCharged = flag(registry, "FullyCharged")
        snapshot.isExternalConnected = flag(registry, "ExternalConnected")

        // IOPS only. See BatterySnapshot.timeToEmptyMinutes for why the
        // registry's TimeRemaining is not read here or anywhere else.
        //
        // On AC, IOPS reports `Time to Empty = 0` rather than omitting it —
        // measured 2026-09-02 while charging at 73%. Zero is not a reading:
        // storing it would put "0 minutes remaining" on the screen of a
        // machine that is plugged in and filling up. Time to empty only
        // means anything while running off the battery. Off it, a zero is
        // not a reading either: a Mac with charge left is not about to die
        // this minute, and one that is has shut down before anyone reads
        // the page. It falls through to the estimate, as "calculating" does.
        if snapshot.isExternalConnected == true {
            snapshot.timeToEmptyMinutes = nil
        } else {
            snapshot.timeToEmptyMinutes = minutes(powerSource, "Time to Empty")
                .flatMap { $0 == 0 ? nil : $0 }
        }
        // Zero is not a reading here either: "0m until full" on a pack that
        // is still charging is wrong, and on a full pack the card already
        // says Full. Nil lets the card say "Estimating…" while charging,
        // exactly as it does when the key is absent.
        snapshot.timeToFullMinutes = minutes(registry, "AvgTimeToFull")
            .flatMap { $0 == 0 ? nil : $0 }

        // An absent or empty adapter dictionary is the ordinary on-battery
        // state: no error, no fallback, and deliberately no logging at any
        // level — a laptop on battery would write that line every sample for
        // as long as it ran.
        let adapterKeys = adapter ?? [:]
        if !adapterKeys.isEmpty {
            snapshot.adapterIsPresent = true
            // Only keys observed on real hardware are read. See the TODO on
            // BatterySnapshot for the ones seen but not yet modelled.
            snapshot.adapterWatts = integer(adapterKeys, "Watts")
            snapshot.adapterName = adapterKeys["Description"] as? String
        } else if let external = snapshot.isExternalConnected {
            snapshot.adapterIsPresent = external
        }

        return snapshot
    }

    // MARK: - IOKit

    private static func readRegistry() -> [String: Any] {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("AppleSmartBattery"))
        // Zero is what a machine with no battery returns. Not an error.
        guard service != 0 else { return [:] }
        defer { IOObjectRelease(service) }

        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0)
                == KERN_SUCCESS,
              let dictionary = properties?.takeRetainedValue() as? [String: Any]
        else { return [:] }
        return dictionary
    }

    private static func readPowerSource() -> [String: Any] {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return [:] }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any] else { continue }
            if description[kIOPSTypeKey as String] as? String == kIOPSInternalBatteryType {
                return description
            }
        }
        return [:]
    }

    /// Nil on battery. That is the normal case and is not logged.
    private static func readAdapter() -> [String: Any]? {
        IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any]
    }
}
