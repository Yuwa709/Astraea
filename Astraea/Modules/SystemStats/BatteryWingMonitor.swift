import Foundation
import IOKit.ps
import Observation
import os

/// The battery figures the collapsed wings show: charge on the right, a
/// time on the left — until full on the charger, until empty off it.
///
/// Push-driven, never polled. The wings are not "visible" to the arbiter —
/// collapsed content must never need a timer (hard rule 9) — so this does
/// not share `BatteryService`'s 5-second sampler. It subscribes to the
/// power-source change notification instead. Measured 2026-10-21: it fires
/// on plug and unplug at once, and otherwise exactly when the battery
/// gauge republishes its registry entry, every 35-60 s — so each one reads
/// a fresh registry. Between those, nothing runs.
///
/// Two sources, on the owner's call (2026-10-21), matching the stats page:
/// - **Time to full is Apple's**, the gauge's `AvgTimeToFull` from the
///   registry. IOPS's own time to full stayed at "calculating" for minutes
///   after plug-in while the gauge already had a figure.
/// - **Time to empty is Astraea's own**, the stats page's "At current use"
///   estimate, so it is there from the moment of unplugging instead of
///   waiting on macOS.
/// IOPS supplies the charge percentage (what the menu bar shows) and the
/// power source, which flips the instant the cable moves.
@MainActor
@Observable
final class BatteryWingMonitor {

    struct Reading: Equatable {
        /// 0...100.
        var percentage: Int
        var isCharging: Bool
        var isOnAC: Bool
        var isFullyCharged: Bool = false
        /// Astraea's estimate. Nil on the charger, and when no load reading
        /// can be had to divide by.
        var minutesToEmpty: Int?
        /// The gauge's figure. Nil off the charger, and while the gauge has
        /// none (its "not applicable" sentinel).
        var minutesToFull: Int? = nil

        /// The time the left wing shows: full on the charger, empty off it.
        var wingMinutes: Int? { isOnAC ? minutesToFull : minutesToEmpty }

        /// Whether the left wing shows anything. Only a full battery on the
        /// charger leaves it blank; any other missing time holds a placeholder
        /// so the wing does not vanish while a figure is on its way.
        var wingShowsTime: Bool { !(isOnAC && isFullyCharged && minutesToFull == nil) }
    }

    @ObservationIgnored
    private static let logger = Logger(subsystem: "com.techie.Astraea", category: "BatteryWing")

    /// Nil while stopped, and on a Mac with no internal battery.
    private(set) var reading: Reading?

    /// Fired when `reading` appears or disappears — what decides whether the
    /// module offers wings at all. Value changes within a reading are
    /// observed by the wing views themselves.
    @ObservationIgnored var onPresenceChange: (() -> Void)?

    @ObservationIgnored private var source: CFRunLoopSource?

    var isRunning: Bool { source != nil }

    deinit {
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
    }

    func start() {
        guard source == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        // The source is added to the main run loop, so the callback arrives
        // on the main thread. Unretained is safe: `stop()` and `deinit`
        // remove the source before the monitor can go away.
        guard let created = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<BatteryWingMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.refresh() }
        }, context)?.takeRetainedValue() else {
            Self.logger.error("Power-source notification unavailable; battery wings stay hidden")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), created, .commonModes)
        source = created
        Self.logger.notice("Battery wing monitor started")
        refresh()
    }

    func stop() {
        guard let source else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        self.source = nil
        Self.logger.notice("Battery wing monitor stopped")
        publish(nil)
    }

    private func refresh() {
        guard let powerSource = Self.readInternalBattery() else {
            smoothedLoad = nil
            publish(nil)
            return
        }
        let now = Date()
        let battery = BatteryService.snapshot(registry: BatteryService.readRegistry(),
                                              powerSource: [:], adapter: nil,
                                              isLowPowerMode: false, now: now)
        let isOnAC = Self.isOnAC(powerSource)
        var estimate: Int?
        if isOnAC {
            // A plug-in ends the average: the next unplug starts afresh.
            smoothedLoad = nil
        } else {
            estimate = estimateMinutesToEmpty(battery, at: now)
        }
        publish(Self.reading(powerSource: powerSource, battery: battery,
                             estimatedMinutesToEmpty: estimate))
    }

    // MARK: - Time-to-empty estimate

    /// The smoothed draw behind the estimate, as `BatteryService` keeps it.
    @ObservationIgnored private var smoothedLoad: (watts: Double, at: Date)?

    /// The same computation the stats page shows as "At current use" —
    /// charge times pack voltage over the smoothed system load — so the wing
    /// and the page agree. It refreshes with each notification, every
    /// 35-60 s, where the page samples every 5 s while open.
    private func estimateMinutesToEmpty(_ battery: BatterySnapshot, at now: Date) -> Int? {
        guard let reading = BatteryService.drawWatts(battery) else { return nil }
        let watts = BatteryService.smoothed(previous: smoothedLoad, reading: reading, at: now)
        smoothedLoad = (watts, now)
        return BatterySnapshot.estimatedMinutesToEmpty(
            milliampHours: battery.rawCurrentCapacityMilliampHours,
            millivolts: battery.voltageMillivolts, watts: watts)
            .map(Self.roundedEstimate)
    }

    /// Past an hour, to the nearest five minutes, as the page rounds it,
    /// rather than claim a precision an estimate does not have.
    nonisolated static func roundedEstimate(_ minutes: Int) -> Int {
        minutes >= 60 ? Int((Double(minutes) / 5).rounded()) * 5 : minutes
    }

    private func publish(_ next: Reading?) {
        guard next != reading else { return }
        let presenceFlipped = (next == nil) != (reading == nil)
        let powerFlipped = next?.isOnAC != reading?.isOnAC
        let chargingFlipped = next?.isCharging != reading?.isCharging
        let timeArrived = (next?.wingMinutes == nil) != (reading?.wingMinutes == nil)
        reading = next
        if presenceFlipped || powerFlipped || chargingFlipped || timeArrived {
            if let next {
                Self.logger.notice("Battery wing \(next.percentage, privacy: .public)% ac=\(next.isOnAC, privacy: .public) charging=\(next.isCharging, privacy: .public) full=\(next.isFullyCharged, privacy: .public) toEmpty=\(next.minutesToEmpty ?? -1, privacy: .public)m toFull=\(next.minutesToFull ?? -1, privacy: .public)m")
            } else {
                Self.logger.notice("Battery wing cleared")
            }
        }
        if presenceFlipped { onPresenceChange?() }
    }

    // MARK: - Parsing

    nonisolated static func isOnAC(_ powerSource: [String: Any]) -> Bool {
        powerSource[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
    }

    /// Builds a reading from the IOPS description, the registry snapshot and
    /// Astraea's estimate. Pure, so the degradation paths are testable
    /// without a battery.
    ///
    /// The registry's charging flags win over IOPS's, which lagged the
    /// gauge right after plug-in (measured 2026-10-21: IOPS said not
    /// charging while the registry said charging). IOPS's are the fallback
    /// for a registry that does not report them.
    nonisolated static func reading(powerSource: [String: Any],
                                    battery: BatterySnapshot,
                                    estimatedMinutesToEmpty: Int?) -> Reading? {
        guard let current = (powerSource[kIOPSCurrentCapacityKey] as? NSNumber)?.intValue,
              let max = (powerSource[kIOPSMaxCapacityKey] as? NSNumber)?.intValue,
              max > 0 else { return nil }
        let percentage = Swift.min(100, Swift.max(0,
            Int((Double(current) / Double(max) * 100).rounded())))
        let isOnAC = isOnAC(powerSource)
        let iopsCharging = (powerSource[kIOPSIsChargingKey] as? NSNumber)?.boolValue ?? false
        let iopsCharged = (powerSource[kIOPSIsChargedKey] as? NSNumber)?.boolValue ?? false
        return Reading(percentage: percentage,
                       isCharging: battery.isCharging ?? iopsCharging,
                       isOnAC: isOnAC,
                       isFullyCharged: battery.isFullyCharged ?? iopsCharged,
                       minutesToEmpty: isOnAC ? nil : estimatedMinutesToEmpty,
                       minutesToFull: isOnAC ? battery.timeToFullMinutes : nil)
    }

    /// The internal battery's description, or nil when there is none.
    private static func readInternalBattery() -> [String: Any]? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any] else { continue }
            if description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType {
                return description
            }
        }
        return nil
    }
}
