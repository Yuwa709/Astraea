import Foundation

/// One sample of the machine's state. Every field is optional: a stat that
/// cannot be read is hidden rather than shown as zero, which would be a lie.
struct SystemStats: Equatable {
    var cpuFraction: Double?
    var memoryFraction: Double?
    var diskFreeBytes: Int64?
    var diskTotalBytes: Int64?
    var gpuFraction: Double?
    var battery: BatterySample?

    static let empty = SystemStats()
}

struct BatterySample: Equatable {
    /// 0...1
    var charge: Double
    var isCharging: Bool
    var isPluggedIn: Bool
}

/// Raw CPU tick counters, summed across cores.
///
/// Absolute values are meaningless — they are monotonic counters since boot.
/// Only the difference between two samples says anything about load.
struct CPUTicks: Equatable {
    var user: UInt64 = 0
    var system: UInt64 = 0
    var idle: UInt64 = 0
    var nice: UInt64 = 0

    var busy: UInt64 { user &+ system &+ nice }
    var total: UInt64 { busy &+ idle }
}

enum CPUUsage {
    /// Busy fraction between two samples, or nil when the pair says nothing.
    ///
    /// Returns nil rather than 0 when no time elapsed: a caller that has only
    /// sampled once must show "unknown", not "idle".
    static func fraction(from previous: CPUTicks, to current: CPUTicks) -> Double? {
        let elapsed = current.total &- previous.total
        guard elapsed > 0 else { return nil }
        let busy = current.busy &- previous.busy
        return min(1, max(0, Double(busy) / Double(elapsed)))
    }
}

enum MemoryUsage {
    /// Fraction of physical memory genuinely committed.
    ///
    /// Deliberately excludes inactive and purgeable pages. macOS aggressively
    /// caches into them, so counting them as "used" makes a healthy machine
    /// look like it is at 95% — alarming and useless, which is why the
    /// roadmap asks for pressure rather than raw used.
    static func fraction(
        activePages: UInt64,
        wiredPages: UInt64,
        compressedPages: UInt64,
        pageSize: UInt64,
        physicalMemory: UInt64
    ) -> Double? {
        guard physicalMemory > 0, pageSize > 0 else { return nil }
        let used = (activePages &+ wiredPages &+ compressedPages) &* pageSize
        return min(1, max(0, Double(used) / Double(physicalMemory)))
    }
}
