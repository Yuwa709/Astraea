import Foundation
import IOKit
import IOKit.ps
import AppKit
import Observation
import os

/// Samples the machine on a timer and publishes one struct.
///
/// All IOKit and Mach interop lives here; views never call it directly, per
/// the roadmap's "do not scatter IOKit calls through views".
///
/// The timer exists only while `start()` has been called more times than
/// `stop()`, and is suspended while the display sleeps. Hard rule 9: this app
/// runs for days, and this is the one component that would otherwise poll
/// forever.
@MainActor
@Observable
final class SystemStatsService {

    @ObservationIgnored
    private static let logger = Logger(subsystem: "com.techie.PopNotch", category: "SystemStats")

    /// Two seconds keeps idle CPU inside the performance budget while still
    /// feeling live. Diffed counters mean a longer interval is more accurate,
    /// not less.
    @ObservationIgnored
    static let interval: TimeInterval = 2

    /// A tenth of the interval, so the wake-up can coalesce with others.
    @ObservationIgnored
    static let tolerance: TimeInterval = 0.2

    /// Free disk space moves slowly, and the "important usage" query is the
    /// most expensive read here, so it is taken when the page opens and then
    /// at most this often rather than every tick.
    @ObservationIgnored
    nonisolated static let diskInterval: TimeInterval = 30

    private(set) var stats: SystemStats = .empty

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var previousTicks: CPUTicks?
    /// The last disk reading and when it was taken. Cleared when sampling
    /// stops, so every page open reads afresh.
    @ObservationIgnored private var lastDisk: (free: Int64?, total: Int64?, at: Date)?
    @ObservationIgnored private(set) var subscribers = 0
    @ObservationIgnored private var displayAsleep = false

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

    /// Counted, so several modules can share one service without one's
    /// disappearance stopping sampling for the others.
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
        updateTimer()
        Self.logger.notice("Display asleep; sampling suspended")
    }

    @objc private func displayDidWake() {
        displayAsleep = false
        updateTimer()
        Self.logger.notice("Display awake; sampling resumed")
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
            // Sampling must not stall while a menu is open.
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            Self.logger.notice("Sampling started (\(self.subscribers, privacy: .public) subscribers)")
        } else {
            timer?.invalidate()
            timer = nil
            previousTicks = nil
            lastDisk = nil
            Self.logger.notice("Sampling stopped")
        }
    }

    // MARK: - Sampling

    private func sample() {
        var next = SystemStats()

        if let ticks = Self.readCPUTicks() {
            if let previous = previousTicks {
                next.cpuFraction = CPUUsage.fraction(from: previous, to: ticks)
            }
            previousTicks = ticks
        }

        next.memoryFraction = Self.readMemoryFraction()
        let now = Date()
        if Self.diskReadIsDue(lastReadAt: lastDisk?.at, now: now) {
            let disk = Self.readDisk()
            lastDisk = (disk.free, disk.total, now)
        }
        next.diskFreeBytes = lastDisk?.free
        next.diskTotalBytes = lastDisk?.total
        next.gpuFraction = Self.readGPUFraction()
        // `battery` is deliberately left nil. The only views that read it
        // (`SystemStatsCompactView`, `SystemStatsExpandedView`) are no longer
        // drawn, and the stats page reads `BatteryService` instead — so a
        // second power-source query every tick bought nothing on screen.
        // `readBattery()` is kept for when either view returns.

        stats = next
    }

    /// Whether the disk is due a fresh read: the first sample of a page
    /// open, and then once every `diskInterval`.
    nonisolated static func diskReadIsDue(lastReadAt: Date?, now: Date) -> Bool {
        guard let lastReadAt else { return true }
        return now.timeIntervalSince(lastReadAt) >= diskInterval
    }

    // MARK: - CPU

    private static func readCPUTicks() -> CPUTicks? {
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        var cpuCount: natural_t = 0

        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                         &cpuCount, &info, &infoCount)
        guard result == KERN_SUCCESS, let info else {
            logger.error("host_processor_info failed (\(result, privacy: .public))")
            return nil
        }
        defer {
            vm_deallocate(mach_task_self_,
                          vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
        }

        var ticks = CPUTicks()
        for core in 0..<Int(cpuCount) {
            let base = Int(CPU_STATE_MAX) * core
            ticks.user &+= UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
            ticks.system &+= UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
            ticks.idle &+= UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
            ticks.nice &+= UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
        }
        return ticks
    }

    // MARK: - Memory

    private static func readMemoryFraction() -> Double? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )

        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            logger.error("host_statistics64 failed (\(result, privacy: .public))")
            return nil
        }

        return MemoryUsage.fraction(
            activePages: UInt64(stats.active_count),
            wiredPages: UInt64(stats.wire_count),
            compressedPages: UInt64(stats.compressor_page_count),
            pageSize: UInt64(vm_kernel_page_size),
            physicalMemory: ProcessInfo.processInfo.physicalMemory
        )
    }

    // MARK: - Disk

    /// Uses "important usage" capacity, which is what the user can actually
    /// reclaim. It will not match Finder exactly, because of APFS snapshots
    /// and purgeable space. Expected, not a bug.
    private static func readDisk() -> (free: Int64?, total: Int64?) {
        let url = URL(fileURLWithPath: "/")
        do {
            let values = try url.resourceValues(forKeys: [
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeTotalCapacityKey
            ])
            let total = values.volumeTotalCapacity.map(Int64.init)
            return (values.volumeAvailableCapacityForImportantUsage, total)
        } catch {
            logger.error("Disk capacity unavailable: \(error.localizedDescription, privacy: .public)")
            return (nil, nil)
        }
    }

    // MARK: - GPU

    /// Undocumented IOKit keys that differ across silicon. Every step guards,
    /// and failure hides the stat rather than reporting a false zero.
    private static func readGPUFraction() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOAccelerator"),
                                           &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }

            // The one property, not the whole entry: copying every property
            // of the accelerator to read a single key was most of this
            // read's cost. A Create call, so the result is +1 and taken
            // retained; nil when the key is absent.
            guard let property = IORegistryEntryCreateCFProperty(
                      service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                      .takeRetainedValue(),
                  let performance = property as? [String: Any],
                  let utilization = performance["Device Utilization %"] as? Int
            else { continue }

            return min(1, max(0, Double(utilization) / 100))
        }
        return nil
    }

    // MARK: - Battery

    private static func readBattery() -> BatterySample? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any],
                  let current = description[kIOPSCurrentCapacityKey as String] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey as String] as? Int,
                  maximum > 0
            else { continue }

            let state = description[kIOPSPowerSourceStateKey as String] as? String
            return BatterySample(
                charge: min(1, max(0, Double(current) / Double(maximum))),
                isCharging: description[kIOPSIsChargingKey as String] as? Bool ?? false,
                isPluggedIn: state == (kIOPSACPowerValue as String)
            )
        }
        return nil
    }
}
