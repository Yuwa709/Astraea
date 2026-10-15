import XCTest
@testable import PopNotch

/// The IOKit and Mach calls need real hardware and cannot be asserted on, but
/// the arithmetic they feed can. These cover the two calculations most likely
/// to be quietly wrong: tick diffing and what counts as "used" memory.
final class SystemStatsTests: XCTestCase {

    // MARK: - CPU tick diffing

    func testCPUFractionFromTickDifference() {
        let before = CPUTicks(user: 100, system: 50, idle: 850, nice: 0)
        let after = CPUTicks(user: 200, system: 100, idle: 1700, nice: 0)
        // 150 busy of 1000 elapsed
        XCTAssertEqual(CPUUsage.fraction(from: before, to: after) ?? -1, 0.15, accuracy: 0.0001)
    }

    func testCPUFractionCountsNiceAsBusy() {
        let before = CPUTicks()
        let after = CPUTicks(user: 0, system: 0, idle: 900, nice: 100)
        XCTAssertEqual(CPUUsage.fraction(from: before, to: after) ?? -1, 0.10, accuracy: 0.0001)
    }

    func testCPUFractionIsNilWhenNoTimeElapsed() {
        let ticks = CPUTicks(user: 10, system: 10, idle: 10, nice: 10)
        XCTAssertNil(CPUUsage.fraction(from: ticks, to: ticks),
                     "a single sample means unknown, not idle")
    }

    func testCPUFractionIsNilWhenCountersGoBackwards() {
        // Counters are monotonic, so this only happens if a sample is bogus.
        // It must not produce a wild number.
        let before = CPUTicks(user: 500, system: 0, idle: 500, nice: 0)
        let after = CPUTicks(user: 100, system: 0, idle: 100, nice: 0)
        let fraction = CPUUsage.fraction(from: before, to: after)
        if let fraction {
            XCTAssertTrue((0...1).contains(fraction), "must stay in range, got \(fraction)")
        }
    }

    func testCPUFractionClampsToFullyBusy() {
        let before = CPUTicks()
        let after = CPUTicks(user: 1000, system: 0, idle: 0, nice: 0)
        XCTAssertEqual(CPUUsage.fraction(from: before, to: after) ?? -1, 1.0, accuracy: 0.0001)
    }

    // MARK: - Memory

    func testMemoryFractionCountsActiveWiredAndCompressed() {
        // 4 GB physical, 4 KB pages: 262144 pages total.
        let fraction = MemoryUsage.fraction(
            activePages: 131_072,      // 512 MB
            wiredPages: 65_536,        // 256 MB
            compressedPages: 65_536,   // 256 MB
            pageSize: 4096,
            physicalMemory: 4 * 1024 * 1024 * 1024
        )
        XCTAssertEqual(fraction ?? -1, 0.25, accuracy: 0.0001)
    }

    func testMemoryFractionIgnoresInactiveAndPurgeable() {
        // Inactive/purgeable pages are simply not parameters: macOS caches
        // into them, and counting them would make a healthy machine read as
        // nearly full. This test pins that intent.
        let fraction = MemoryUsage.fraction(
            activePages: 0, wiredPages: 0, compressedPages: 0,
            pageSize: 4096, physicalMemory: 4 * 1024 * 1024 * 1024
        )
        XCTAssertEqual(fraction ?? -1, 0, accuracy: 0.0001)
    }

    func testMemoryFractionIsNilWithoutPhysicalMemory() {
        XCTAssertNil(MemoryUsage.fraction(
            activePages: 1, wiredPages: 1, compressedPages: 1,
            pageSize: 4096, physicalMemory: 0
        ))
    }

    func testMemoryFractionClampsAtFull() {
        let fraction = MemoryUsage.fraction(
            activePages: 1_000_000, wiredPages: 0, compressedPages: 0,
            pageSize: 4096, physicalMemory: 1024 * 1024
        )
        XCTAssertEqual(fraction ?? -1, 1.0, accuracy: 0.0001)
    }

    // MARK: - Missing stats stay missing

    func testEmptyStatsReportNothingRatherThanZero() {
        let stats = SystemStats.empty
        XCTAssertNil(stats.cpuFraction)
        XCTAssertNil(stats.gpuFraction)
        XCTAssertNil(stats.battery)
    }
}
