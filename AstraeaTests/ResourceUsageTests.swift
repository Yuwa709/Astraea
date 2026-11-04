import XCTest
import SwiftUI
@testable import Astraea

/// The resource page: which processes belong to which app, how CPU time
/// becomes a percentage, how the list ranks, and when sampling runs.
@MainActor
final class ResourceUsageTests: XCTestCase {

    private let chrome = ResourceApp(pid: 100, bundleID: "com.google.Chrome", name: "Google Chrome",
                                     bundlePath: "/Applications/Google Chrome.app", canQuit: true)
    private let terminal = ResourceApp(pid: 200, bundleID: "com.apple.Terminal", name: "Terminal",
                                       bundlePath: "/System/Applications/Utilities/Terminal.app", canQuit: true)

    private func process(_ pid: pid_t, parent: pid_t = 1, start: UInt64 = 10, cpu: UInt64 = 0,
                         footprint: UInt64 = 0, energy: UInt64 = 0,
                         appPath: String? = nil) -> ResourceProcess {
        ResourceProcess(pid: pid, parent: parent, start: start, cpuTime: cpu,
                        footprint: footprint, energy: energy, appPath: appPath)
    }

    // MARK: - Attribution

    func testHelpersInsideTheBundleBelongToTheApp() {
        let helper = process(101, parent: 1, appPath: "/Applications/Google Chrome.app")
        let owners = ResourceAttribution.owners(
            processes: [process(100, appPath: chrome.bundlePath), helper], apps: [chrome])
        XCTAssertEqual(owners[100], 100)
        XCTAssertEqual(owners[101], 100, "a helper launched by launchd still sits in the bundle")
    }

    func testDescendantsBelongToTheAppThatSpawnedThem() {
        let shell = process(201, parent: 200)
        let build = process(202, parent: 201)
        let owners = ResourceAttribution.owners(
            processes: [process(200, appPath: terminal.bundlePath), shell, build], apps: [terminal])
        XCTAssertEqual(owners[202], 200)
    }

    func testUnrelatedDaemonsBelongToNobody() {
        let daemon = process(50, parent: 1)
        let webContent = process(51, parent: 1, appPath: nil)
        let owners = ResourceAttribution.owners(processes: [daemon, webContent], apps: [chrome])
        XCTAssertNil(owners[50])
        XCTAssertNil(owners[51], "no stated relationship, so no guess")
    }

    func testTwoInstancesOfOneBundleLeaveHelpersToTheParentChain() {
        let second = ResourceApp(pid: 110, bundleID: chrome.bundleID, name: chrome.name,
                                 bundlePath: chrome.bundlePath, canQuit: true)
        let orphan = process(111, parent: 1, appPath: chrome.bundlePath)
        let child = process(112, parent: 110, appPath: chrome.bundlePath)
        let owners = ResourceAttribution.owners(processes: [orphan, child], apps: [chrome, second])
        XCTAssertNil(owners[111], "ambiguous between the two instances")
        XCTAssertEqual(owners[112], 110)
    }

    func testAParentCycleEnds() {
        let a = process(300, parent: 301)
        let b = process(301, parent: 300)
        XCTAssertTrue(ResourceAttribution.owners(processes: [a, b], apps: [chrome]).isEmpty)
    }

    // MARK: - CPU

    func testFirstSampleHasNoCPU() {
        var tracker = ResourceCPUTracker()
        XCTAssertNil(tracker.advance([process(1, cpu: 500)], nowNanos: 1_000, nowAbsolute: 1_000))
    }

    func testCPUIsTimeOverWallTimeAndCanExceedOneCore() {
        var tracker = ResourceCPUTracker()
        _ = tracker.advance([process(1, cpu: 0)], nowNanos: 0, nowAbsolute: 100)
        let rates = tracker.advance([process(1, cpu: 3_000_000_000)],
                                    nowNanos: 2_000_000_000, nowAbsolute: 200)
        XCTAssertEqual(rates?[1]?.cpuPercent ?? 0, 150, accuracy: 1e-9,
                       "1.5 cores busy reads 150%, unclamped")
    }

    func testPowerIsEnergyOverWallTime() {
        var tracker = ResourceCPUTracker()
        _ = tracker.advance([process(1, energy: 1_000)], nowNanos: 0, nowAbsolute: 100)
        let rates = tracker.advance([process(1, energy: 3_000_001_000)],
                                    nowNanos: 2_000_000_000, nowAbsolute: 200)
        XCTAssertEqual(rates?[1]?.watts ?? 0, 1.5, accuracy: 1e-9, "3 J over 2 s is 1.5 W")
    }

    func testAProcessBornDuringTheIntervalCountsAllItsTime() {
        var tracker = ResourceCPUTracker()
        _ = tracker.advance([], nowNanos: 0, nowAbsolute: 100)
        let rates = tracker.advance([process(7, start: 150, cpu: 500_000_000, energy: 250_000_000)],
                                    nowNanos: 1_000_000_000, nowAbsolute: 200)
        XCTAssertEqual(rates?[7]?.cpuPercent ?? 0, 50, accuracy: 1e-9)
        XCTAssertEqual(rates?[7]?.watts ?? 0, 0.25, accuracy: 1e-9)
    }

    func testAReusedPIDOrResetCounterGetsNoFigure() {
        var tracker = ResourceCPUTracker()
        _ = tracker.advance([process(1, start: 10, cpu: 900), process(2, start: 10, cpu: 900)],
                            nowNanos: 0, nowAbsolute: 100)
        // PID 1 reused by a process that started before the last sample
        // could see it (a racy read); PID 2's counter went backwards.
        let rates = tracker.advance([process(1, start: 50, cpu: 10), process(2, start: 10, cpu: 5)],
                                    nowNanos: 1_000, nowAbsolute: 200)
        XCTAssertNil(rates?[1])
        XCTAssertNil(rates?[2])
    }

    // MARK: - Aggregation and ranking

    func testAggregationSumsAnAppsProcesses() {
        let processes = [
            process(100, footprint: 1_000, appPath: chrome.bundlePath),
            process(101, footprint: 2_000, appPath: chrome.bundlePath),
            process(200, footprint: 500, appPath: terminal.bundlePath),
            process(9, footprint: 99_999),
        ]
        let rows = ResourceRanking.aggregate(processes: processes, apps: [chrome, terminal],
                                             rates: [100: .init(cpuPercent: 10, watts: 0.5),
                                                     101: .init(cpuPercent: 32, watts: 1),
                                                     200: .init(cpuPercent: 5, watts: 0.1)])
        let chromeRow = rows.first { $0.id == 100 }
        XCTAssertEqual(chromeRow?.memoryBytes, 3_000)
        XCTAssertEqual(chromeRow?.processCount, 2)
        XCTAssertEqual(chromeRow?.cpuPercent ?? 0, 42, accuracy: 1e-9)
        XCTAssertEqual(chromeRow?.watts ?? 0, 1.5, accuracy: 1e-9)
        XCTAssertEqual(rows.count, 2, "the daemon joins no row")
    }

    func testBeforeTheSecondSampleRatesAreUnknownNotZero() {
        let rows = ResourceRanking.aggregate(processes: [process(100, appPath: chrome.bundlePath)],
                                             apps: [chrome], rates: nil)
        XCTAssertNil(rows.first?.cpuPercent)
        XCTAssertNil(rows.first?.watts)
    }

    func testAnAppWithNoReadableProcessIsLeftOut() {
        XCTAssertTrue(ResourceRanking.aggregate(processes: [], apps: [chrome], rates: [:]).isEmpty)
    }

    func testRankingFollowsTheMetric() {
        let a = ResourceAppUsage(app: chrome, cpuPercent: 5, watts: 2, memoryBytes: 4_000, processCount: 1)
        let b = ResourceAppUsage(app: terminal, cpuPercent: 27, watts: 0.3, memoryBytes: 1_000, processCount: 1)
        XCTAssertEqual(ResourceRanking.ranked([a, b], by: .energy).map(\.id), [100, 200])
        XCTAssertEqual(ResourceRanking.ranked([a, b], by: .cpu).map(\.id), [200, 100])
        XCTAssertEqual(ResourceRanking.ranked([a, b], by: .memory).map(\.id), [100, 200])
    }

    // MARK: - Smoothing

    private func usage(_ app: ResourceApp, cpu: Double? = nil, watts: Double? = nil,
                       memory: UInt64 = 0) -> ResourceAppUsage {
        ResourceAppUsage(app: app, cpuPercent: cpu, watts: watts, memoryBytes: memory, processCount: 1)
    }

    private func app(_ pid: pid_t) -> ResourceApp {
        ResourceApp(pid: pid, bundleID: "test.\(pid)", name: "App \(pid)", bundlePath: nil, canQuit: true)
    }

    func testSmoothingFollowsItsTimeConstants() {
        var smoother = ResourceSmoother()
        _ = smoother.smooth([usage(chrome, cpu: 0, watts: 0, memory: 100)], at: 0)
        let row = smoother.smooth([usage(chrome, cpu: 100, watts: 1, memory: 900)], at: 10).first
        XCTAssertEqual(row?.cpuPercent ?? 0, 100 * (1 - exp(-1)), accuracy: 1e-9, "one 10 s time constant")
        XCTAssertEqual(row?.watts ?? 0, 1 - exp(-0.5), accuracy: 1e-9, "half of energy's 20 s")
        XCTAssertEqual(row?.memoryBytes, 900, "memory is not smoothed")
    }

    func testSmoothingSeedsAFirstFigureAndForgetsExitedApps() {
        var smoother = ResourceSmoother()
        XCTAssertEqual(smoother.smooth([usage(chrome, cpu: 40)], at: 0).first?.cpuPercent, 40)
        _ = smoother.smooth([], at: 2)
        XCTAssertEqual(smoother.smooth([usage(chrome, cpu: 8)], at: 4).first?.cpuPercent, 8,
                       "a PID that left starts over")
    }

    // MARK: - Stable ordering

    private func order(_ rows: [ResourceAppUsage]) -> [pid_t] { rows.map(\.id) }

    func testTheFirstArrangementIsAPlainRanking() {
        var stabilizer = ResourceRankStabilizer()
        let rows = [usage(app(1), cpu: 1), usage(app(2), cpu: 9)]
        XCTAssertEqual(order(stabilizer.arrange(rows, by: .cpu, at: 0)), [2, 1])
    }

    func testOrderHoldsBetweenEvaluations() {
        var stabilizer = ResourceRankStabilizer()
        _ = stabilizer.arrange([usage(app(1), cpu: 50), usage(app(2), cpu: 10)], by: .cpu, at: 0)
        let swapped = [usage(app(1), cpu: 10), usage(app(2), cpu: 50)]
        XCTAssertEqual(order(stabilizer.arrange(swapped, by: .cpu, at: 2)), [1, 2])
        XCTAssertEqual(order(stabilizer.arrange(swapped, by: .cpu, at: 4)), [1, 2], "under 5 s")
    }

    func testALeadMustHoldForTwoEvaluations() {
        var stabilizer = ResourceRankStabilizer()
        _ = stabilizer.arrange([usage(app(1), cpu: 50), usage(app(2), cpu: 10)], by: .cpu, at: 0)
        let swapped = [usage(app(1), cpu: 10), usage(app(2), cpu: 50)]
        XCTAssertEqual(order(stabilizer.arrange(swapped, by: .cpu, at: 5)), [1, 2], "first evaluation")
        XCTAssertEqual(order(stabilizer.arrange(swapped, by: .cpu, at: 10)), [2, 1], "second")
    }

    func testAFlickeringLeadMovesNothing() {
        var stabilizer = ResourceRankStabilizer()
        _ = stabilizer.arrange([usage(app(1), cpu: 50), usage(app(2), cpu: 10)], by: .cpu, at: 0)
        _ = stabilizer.arrange([usage(app(1), cpu: 10), usage(app(2), cpu: 50)], by: .cpu, at: 5)
        _ = stabilizer.arrange([usage(app(1), cpu: 50), usage(app(2), cpu: 10)], by: .cpu, at: 10)
        let rows = stabilizer.arrange([usage(app(1), cpu: 10), usage(app(2), cpu: 50)], by: .cpu, at: 15)
        XCTAssertEqual(order(rows), [1, 2])
    }

    func testASmallLeadNeverSwaps() {
        var stabilizer = ResourceRankStabilizer()
        _ = stabilizer.arrange([usage(app(1), cpu: 20), usage(app(2), cpu: 10)], by: .cpu, at: 0)
        let close = [usage(app(1), cpu: 20), usage(app(2), cpu: 21.5)]
        for time in stride(from: 5.0, through: 60, by: 5) {
            XCTAssertEqual(order(stabilizer.arrange(close, by: .cpu, at: time)), [1, 2],
                           "7.5% ahead is inside the 12% margin")
        }
    }

    func testASustainedLeadClimbsAllTheWayInOneStep() {
        var stabilizer = ResourceRankStabilizer()
        let start = [usage(app(1), cpu: 30), usage(app(2), cpu: 20), usage(app(3), cpu: 10)]
        _ = stabilizer.arrange(start, by: .cpu, at: 0)
        let surge = [usage(app(1), cpu: 30), usage(app(2), cpu: 20), usage(app(3), cpu: 90)]
        _ = stabilizer.arrange(surge, by: .cpu, at: 5)
        XCTAssertEqual(order(stabilizer.arrange(surge, by: .cpu, at: 10)), [3, 1, 2])
    }

    func testANewAppJoinsAtTheBottomAndThenClimbs() {
        var stabilizer = ResourceRankStabilizer()
        _ = stabilizer.arrange([usage(app(1), cpu: 30), usage(app(2), cpu: 20)], by: .cpu, at: 0)
        let launched = [usage(app(1), cpu: 30), usage(app(2), cpu: 20), usage(app(3), cpu: 80)]
        XCTAssertEqual(order(stabilizer.arrange(launched, by: .cpu, at: 2)), [1, 2, 3])
        XCTAssertEqual(order(stabilizer.arrange(launched, by: .cpu, at: 5)), [1, 2, 3])
        XCTAssertEqual(order(stabilizer.arrange(launched, by: .cpu, at: 10)), [3, 1, 2])
    }

    func testExitedAppsLeaveAndTheRestKeepTheirPlaces() {
        var stabilizer = ResourceRankStabilizer()
        _ = stabilizer.arrange([usage(app(1), cpu: 30), usage(app(2), cpu: 20), usage(app(3), cpu: 10)],
                               by: .cpu, at: 0)
        let rows = stabilizer.arrange([usage(app(1), cpu: 30), usage(app(3), cpu: 10)], by: .cpu, at: 1)
        XCTAssertEqual(order(rows), [1, 3])
    }

    func testSwitchingMetricOrResettingRanksAfresh() {
        var stabilizer = ResourceRankStabilizer()
        let rows = [usage(app(1), cpu: 50, memory: 1), usage(app(2), cpu: 10, memory: 900_000_000)]
        _ = stabilizer.arrange(rows, by: .cpu, at: 0)
        XCTAssertEqual(order(stabilizer.arrange(rows, by: .memory, at: 1)), [2, 1])
        stabilizer.reset()
        XCTAssertEqual(order(stabilizer.arrange(rows, by: .memory, at: 2)), [2, 1])
        let flipped = [usage(app(1), cpu: 50, memory: 900_000_000), usage(app(2), cpu: 10, memory: 1)]
        stabilizer.reset()
        XCTAssertEqual(order(stabilizer.arrange(flipped, by: .memory, at: 3)), [1, 2])
    }

    // MARK: - Formatting

    func testFormatting() {
        XCTAssertEqual(ResourceFormat.cpu(nil), "—")
        XCTAssertEqual(ResourceFormat.cpu(4.24), "4.2%")
        XCTAssertEqual(ResourceFormat.cpu(42.4), "42%")
        XCTAssertEqual(ResourceFormat.cpu(212), "212%")
        XCTAssertEqual(ResourceFormat.power(nil), "—")
        XCTAssertEqual(ResourceFormat.power(0.0853), "85 mW")
        XCTAssertEqual(ResourceFormat.power(1.24), "1.2 W")
        XCTAssertEqual(ResourceFormat.memory(420 * 1_048_576), "420 MB")
        XCTAssertEqual(ResourceFormat.memory(UInt64(1.6 * 1_073_741_824)), "1.6 GB")
    }

    func testOutermostAppPath() {
        XCTAssertEqual(ResourceProcessReader.outermostAppPath(
            "/Applications/Google Chrome.app/Contents/Frameworks/Helper (Renderer).app/Contents/MacOS/Helper"),
            "/Applications/Google Chrome.app")
        XCTAssertNil(ResourceProcessReader.outermostAppPath("/usr/libexec/trustd"))
    }

    /// The real reader against the real machine: it finds this test process
    /// with a footprint, and the second read has CPU for it.
    func testReaderReadsThisProcess() {
        var reader = ResourceProcessReader()
        let me = ProcessInfo.processInfo.processIdentifier
        let processes = reader.readAll()
        let mine = processes.first { $0.pid == me }
        XCTAssertNotNil(mine)
        XCTAssertGreaterThan(mine?.footprint ?? 0, 0)
        XCTAssertGreaterThan(processes.count, 10)
    }

    // MARK: - Navigation and lifecycle

    func testBackFromResourceUsageReturnsToTheStatsPage() {
        XCTAssertEqual(NotchCoordinator.Destination.resourceUsage.parent, .systemStats)
        XCTAssertEqual(NotchCoordinator.Destination.systemStats.parent, .standby)
        XCTAssertEqual(NotchCoordinator.Destination.resourceUsage.moduleID, "system-stats")
    }

    func testResourceSamplingRunsOnlyWhileThePageIsOpen() {
        let suite = "ResourceUsageTests"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let stats = SystemStatsService()
        let battery = BatteryService()
        let resources = ResourceUsageService()
        let coordinator = NotchCoordinator(
            settings: SettingsStore(defaults: defaults), arbiter: NotchArbiter(),
            statsPage: .init(stats: stats, battery: battery, resources: resources))
        coordinator.register(SystemStatsModule(service: stats), enabledByDefault: true)

        coordinator.navigate(to: .systemStats)
        XCTAssertFalse(resources.isSampling, "the overview does not sample apps")
        coordinator.navigate(to: .resourceUsage)
        XCTAssertTrue(resources.isSampling)
        XCTAssertEqual(stats.subscribers, 1, "the stats services keep running across the hop")
        coordinator.navigate(to: .systemStats)
        XCTAssertFalse(resources.isSampling, "back to the overview stops the app sampler")
        XCTAssertEqual(stats.subscribers, 1)

        coordinator.navigate(to: .resourceUsage)
        coordinator.navigate(to: .standby)
        XCTAssertFalse(resources.isSampling)
        XCTAssertEqual(stats.subscribers, 0)
        XCTAssertFalse(battery.isSampling)

        coordinator.navigate(to: .resourceUsage)
        coordinator.setEnabled(false, for: "system-stats")
        XCTAssertFalse(resources.isSampling, "disabling the feature closes the page and its sampler")
    }

    func testStartIsIdempotentAndEnergyIsTheDefault() {
        let service = ResourceUsageService()
        service.metric = .memory
        service.start()
        service.start()
        XCTAssertEqual(service.metric, .energy)
        XCTAssertEqual(service.phase, .measuring)
        service.stop()
        XCTAssertFalse(service.isSampling)
        XCTAssertEqual(service.phase, .idle)
        XCTAssertTrue(service.apps.isEmpty)
    }

    func testSegmentsRunEnergyMemoryCPU() {
        XCTAssertEqual(ResourceMetric.allCases, [.energy, .memory, .cpu])
    }

    // MARK: - Fit

    private func measuredHeight<V: View>(_ view: V) -> CGFloat {
        NSHostingView(rootView: view
            .padding(.top, 32 + NotchCoordinator.Destination.systemStats.contentTopGap).padding(.horizontal, 32).padding(.bottom, 20)).fittingSize.height
    }

    func testBothStatsScreensFitThePanel() {
        let overview = SystemStatsPageView(stats: SystemStatsService(), battery: BatteryService(),
                                           onShowResources: {})
        let overviewHeight = measuredHeight(overview)
        XCTAssertLessThanOrEqual(overviewHeight, 460, "the overview fits the panel ceiling")
        let detailHeight = measuredHeight(ResourceUsagePageView(service: ResourceUsageService()))
        XCTAssertLessThanOrEqual(detailHeight, 460)
    }
}
