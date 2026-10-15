import XCTest
@testable import PopNotch

/// Subscriber accounting for the stats page's two services.
///
/// The services are *counted*, not boolean, so several owners can share one
/// service without one's disappearance stopping sampling for the others. That
/// only holds if every `start()` is matched by exactly one `stop()`, so this
/// pins the balance: five open/close cycles must leave every count exactly
/// where it started, on each of the paths that reach the page.
@MainActor
final class StatsSubscriberBalanceTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suite = "com.techie.PopNotch.statsbalance"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func makeServices() -> (SystemStatsService, BatteryService) {
        (SystemStatsService(), BatteryService())
    }

    private func makeCoordinator(registerModule: Bool)
    -> (NotchCoordinator, SystemStatsService, BatteryService) {
        let (stats, battery) = makeServices()
        let coordinator = NotchCoordinator(
            settings: SettingsStore(defaults: defaults),
            arbiter: NotchArbiter(),
            statsPage: NotchCoordinator.StatsPageServices(
                stats: stats, battery: battery))
        if registerModule {
            coordinator.register(SystemStatsModule(service: stats))
            coordinator.start()
        }
        return (coordinator, stats, battery)
    }

    /// Navigating to the page and back, five times.
    func testNavigateCyclesLeaveEveryCountWhereItStarted() {
        let (coordinator, stats, battery) = makeCoordinator(registerModule: false)
        let base = [stats.subscribers, battery.subscribers]

        for cycle in 1...5 {
            coordinator.navigate(to: .systemStats)
            XCTAssertEqual([stats.subscribers, battery.subscribers],
                           [base[0] + 1, base[1] + 1],
                           "the open page holds one stats and one battery (cycle \(cycle))")
            coordinator.navigate(to: .standby)
            XCTAssertEqual([stats.subscribers, battery.subscribers], base,
                           "counts must return to baseline after cycle \(cycle)")
        }
    }

    /// The path the app actually takes: expand, open the page, back, collapse.
    func testPinNavigateCollapseCyclesLeaveEveryCountWhereItStarted() {
        let (coordinator, stats, battery) = makeCoordinator(registerModule: false)
        let base = [stats.subscribers, battery.subscribers]

        for cycle in 1...5 {
            coordinator.setPinned(true)
            coordinator.navigate(to: .systemStats)
            coordinator.navigate(to: .standby)
            coordinator.setPinned(false)
            XCTAssertEqual([stats.subscribers, battery.subscribers], base,
                           "counts must return to baseline after cycle \(cycle)")
        }
    }

    /// With the module registered and the panel created, the arbiter's
    /// visibility callbacks could drive `SystemStatsService` as well. They do
    /// not: stats draws nothing in the collapsed panel and has no row in the
    /// open stack, so it is never visible and its baseline is zero. This was
    /// one — an always-on subscriber for a compact view that is never drawn,
    /// sampling every two seconds for the life of the process (2026-09-13).
    func testRegisteredModuleHoldsNoSubscriberAtRest() {
        let (coordinator, stats, battery) = makeCoordinator(registerModule: true)
        let base = [stats.subscribers, battery.subscribers]
        XCTAssertEqual(base, [0, 0], "nothing of system stats is on screen, so nothing samples")

        for cycle in 1...5 {
            coordinator.setPinned(true)
            coordinator.navigate(to: .systemStats)
            coordinator.navigate(to: .standby)
            coordinator.setPinned(false)
            XCTAssertEqual([stats.subscribers, battery.subscribers], base,
                           "counts must return to baseline after cycle \(cycle)")
        }
    }

    /// An unmatched `stop()` must not push a count negative, which would make
    /// the next `start()` fail to restart sampling.
    func testExtraStopsCannotDriveCountsNegative() {
        let (stats, battery) = makeServices()

        // Two surplus stops on each, from a standing count of zero.
        stats.stop();   stats.stop()
        battery.stop(); battery.stop()
        XCTAssertEqual([stats.subscribers, battery.subscribers], [0, 0],
                       "a stop below zero must clamp, not go negative")

        // A start afterwards must still register.
        stats.start()
        battery.start()
        XCTAssertEqual([stats.subscribers, battery.subscribers], [1, 1],
                       "start must still count after surplus stops")
        stats.stop()
        battery.stop()
    }
}
