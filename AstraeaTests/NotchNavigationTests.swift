import XCTest
@testable import Astraea

/// Panel navigation: the coordinator's destination state and its resets.
/// Runs against a scratch UserDefaults suite so no real preference moves.
@MainActor
final class NotchNavigationTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suite = "com.techie.Astraea.navtests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func makeCoordinator(clipboardEnabled: Bool = true)
        -> (NotchCoordinator, ClipboardModule) {
        let arbiter = NotchArbiter()
        let coordinator = NotchCoordinator(
            settings: SettingsStore(defaults: defaults), arbiter: arbiter)
        let clipboard = ClipboardModule(service: ClipboardService())
        coordinator.register(clipboard, enabledByDefault: clipboardEnabled)
        return (coordinator, clipboard)
    }

    func testStartsOnStandby() {
        let (coordinator, _) = makeCoordinator()
        XCTAssertEqual(coordinator.destination, .standby,
                       "the panel always opens on the arbitrated default")
    }

    func testNavigateReachesTheClipboardScreen() {
        let (coordinator, _) = makeCoordinator()
        coordinator.navigate(to: .clipboard)
        XCTAssertEqual(coordinator.destination, .clipboard)
    }

    func testNavigateBackReturnsToStandby() {
        let (coordinator, _) = makeCoordinator()
        coordinator.navigate(to: .clipboard)
        coordinator.navigate(to: .standby)
        XCTAssertEqual(coordinator.destination, .standby)
    }

    func testDisablingTheModuleUnderTheScreenSendsYouHome() {
        // Settings can pull the feature out from under the open screen; the
        // panel must not be left showing a screen whose feature is off.
        let (coordinator, _) = makeCoordinator()
        coordinator.navigate(to: .clipboard)
        coordinator.setEnabled(false, for: "clipboard")
        XCTAssertEqual(coordinator.destination, .standby)
    }

    func testDisablingSomeOtherModuleDoesNotNavigate() {
        let (coordinator, _) = makeCoordinator()
        coordinator.navigate(to: .clipboard)
        coordinator.setEnabled(false, for: "system-stats")
        XCTAssertEqual(coordinator.destination, .clipboard,
                       "an unrelated toggle must not yank the user off their screen")
    }

    // MARK: - A second screen

    func testEachScreenMapsToItsOwnModule() {
        XCTAssertEqual(NotchCoordinator.Destination.clipboard.moduleID, "clipboard")
        XCTAssertEqual(NotchCoordinator.Destination.fileShelf.moduleID, "file-shelf")
        XCTAssertNil(NotchCoordinator.Destination.standby.moduleID,
                     "standby is the arbitrated default, not a module's screen")
    }

    func testNavigatingToTheShelf() {
        let (coordinator, _) = makeCoordinator()
        coordinator.navigate(to: .fileShelf)
        XCTAssertEqual(coordinator.destination, .fileShelf)
    }

    func testDisablingTheShelfUnderItsScreenSendsYouHome() {
        let arbiter = NotchArbiter()
        let coordinator = NotchCoordinator(
            settings: SettingsStore(defaults: defaults), arbiter: arbiter)
        coordinator.register(FileShelfModule(service: FileShelfService()), enabledByDefault: true)
        coordinator.navigate(to: .fileShelf)
        coordinator.setEnabled(false, for: "file-shelf")
        XCTAssertEqual(coordinator.destination, .standby)
    }

    func testDisablingOneScreensModuleLeavesTheOtherScreenAlone() {
        let (coordinator, _) = makeCoordinator()
        coordinator.register(FileShelfModule(service: FileShelfService()), enabledByDefault: true)
        coordinator.navigate(to: .fileShelf)
        coordinator.setEnabled(false, for: "clipboard")
        XCTAssertEqual(coordinator.destination, .fileShelf,
                       "an unrelated module's toggle must not close your screen")
    }

    // MARK: - A file drag opens to the shelf

    private func makeCoordinatorWithShelf(enabled: Bool) -> NotchCoordinator {
        let coordinator = NotchCoordinator(
            settings: SettingsStore(defaults: defaults), arbiter: NotchArbiter())
        coordinator.register(FileShelfModule(service: FileShelfService()),
                             enabledByDefault: enabled)
        return coordinator
    }

    func testFileDragOpensToTheShelf() {
        // Opening to home would be useless: there is nowhere on it to drop.
        let coordinator = makeCoordinatorWithShelf(enabled: true)
        coordinator.fileDragChanged(true)
        XCTAssertEqual(coordinator.destination, .fileShelf)
    }

    func testFileDragDoesNotNavigateWhenTheShelfIsOff() {
        let coordinator = makeCoordinatorWithShelf(enabled: false)
        coordinator.fileDragChanged(true)
        XCTAssertEqual(coordinator.destination, .standby,
                       "a disabled feature must never be navigated to")
    }

    func testFileDragWithNoShelfModuleRegisteredIsHarmless() {
        let (coordinator, _) = makeCoordinator()
        coordinator.fileDragChanged(true)
        XCTAssertEqual(coordinator.destination, .standby)
    }

    func testDragLeavingBeforeThePanelOpensResetsTheDestination() {
        // Otherwise the next plain hover would open to the shelf, having
        // inherited a destination set for a screen nobody ever saw.
        let coordinator = makeCoordinatorWithShelf(enabled: true)
        coordinator.fileDragChanged(true)
        XCTAssertEqual(coordinator.destination, .fileShelf)
        coordinator.fileDragChanged(false)
        XCTAssertEqual(coordinator.destination, .standby)
    }

    func testDragExitDoesNotDisturbAScreenTheUserNavigatedTo() {
        // A stray drag ending must not yank someone off the clipboard screen
        // they opened by hand.
        let (coordinator, _) = makeCoordinator()
        coordinator.navigate(to: .clipboard)
        coordinator.fileDragChanged(false)
        XCTAssertEqual(coordinator.destination, .standby,
                       "reset only applies while collapsed, which this is")
    }

    func testPlainHoverStillOpensHome() {
        // The non-drag path is untouched: no destination is chosen for it.
        let coordinator = makeCoordinatorWithShelf(enabled: true)
        XCTAssertEqual(coordinator.destination, .standby)
    }

    // MARK: - The stats door

    /// The stats page's services, wired the way AppDelegate wires them.
    private func makeStatsCoordinator(statsEnabled: Bool = true)
        -> (NotchCoordinator, BatteryService, SystemStatsService) {
        let stats = SystemStatsService()
        let battery = BatteryService()
        let coordinator = NotchCoordinator(
            settings: SettingsStore(defaults: defaults),
            arbiter: NotchArbiter(),
            statsPage: .init(stats: stats, battery: battery))
        coordinator.register(SystemStatsModule(service: stats),
                             enabledByDefault: statsEnabled)
        return (coordinator, battery, stats)
    }

    func testNavigateReachesTheStatsPage() {
        let (coordinator, _, _) = makeStatsCoordinator()
        coordinator.navigate(to: .systemStats)
        XCTAssertEqual(coordinator.destination, .systemStats)
    }

    func testStatsDestinationMapsToTheSystemStatsModule() {
        XCTAssertEqual(NotchCoordinator.Destination.systemStats.moduleID, "system-stats")
    }

    func testDisablingSystemStatsUnderTheStatsPageSendsYouHome() {
        let (coordinator, _, _) = makeStatsCoordinator()
        coordinator.navigate(to: .systemStats)
        coordinator.setEnabled(false, for: "system-stats")
        XCTAssertEqual(coordinator.destination, .standby)
    }

    // MARK: - The stats door's sampling lifecycle

    /// Hard rule 9, as an assertion rather than a comment: nothing polls
    /// until the page is open, and nothing is left polling once it closes.
    func testNoTimersUntilTheStatsPageOpens() {
        let (_, battery, stats) = makeStatsCoordinator()
        XCTAssertFalse(battery.isSampling, "battery must not poll before the page opens")
        XCTAssertEqual(stats.subscribers, 0, "stats must not poll before the page opens")
    }

    func testOpeningTheStatsPageStartsSamplingAndClosingStopsIt() {
        let (coordinator, battery, stats) = makeStatsCoordinator()

        coordinator.navigate(to: .systemStats)
        XCTAssertTrue(battery.isSampling)
        XCTAssertEqual(stats.subscribers, 1)

        coordinator.navigate(to: .standby)
        XCTAssertFalse(battery.isSampling, "battery still polling after the door closed")
        XCTAssertEqual(stats.subscribers, 0, "stats still polling after the door closed")
    }

    /// Leaving straight for another door, not via standby, must still stop
    /// the sampling — the lifecycle hangs off the destination itself.
    func testLeavingTheStatsPageForAnotherDoorStopsSampling() {
        let (coordinator, battery, stats) = makeStatsCoordinator()
        coordinator.register(ClipboardModule(service: ClipboardService()))

        coordinator.navigate(to: .systemStats)
        coordinator.navigate(to: .clipboard)
        XCTAssertFalse(battery.isSampling)
        XCTAssertEqual(stats.subscribers, 0)
    }

    /// Disabling the module while the page is open closes it, and closing it
    /// must take the timers down too.
    func testDisablingTheModuleStopsSampling() {
        let (coordinator, battery, stats) = makeStatsCoordinator()
        coordinator.navigate(to: .systemStats)
        coordinator.setEnabled(false, for: "system-stats")
        XCTAssertFalse(battery.isSampling)
        XCTAssertEqual(stats.subscribers, 0)
    }

    /// Navigating to the page twice must not leave an unbalanced subscriber
    /// count keeping a timer alive after one close.
    func testRepeatedNavigationKeepsSubscribersBalanced() {
        let (coordinator, battery, stats) = makeStatsCoordinator()
        coordinator.navigate(to: .systemStats)
        coordinator.navigate(to: .systemStats)   // no-op, guarded
        coordinator.navigate(to: .standby)
        XCTAssertFalse(battery.isSampling)
        XCTAssertEqual(stats.subscribers, 0)
    }

    // MARK: - The stats row's removal from the expanded stack

    /// System stats contributes no expanded row any more: its numbers live on
    /// the stats page. The compact view and the service lifecycle are
    /// deliberately untouched, so this asserts the narrow thing that changed.
    func testSystemStatsContributesNoExpandedRow() {
        let module = SystemStatsModule(service: SystemStatsService())
        XCTAssertFalse(module.hasExpandedContent,
                       "the CPU/MEM/GPU/BATT/DISK row no longer joins the stack")
    }

    /// The view itself is kept, not deleted — it is simply not stacked.
    func testTheStatsExpandedViewStillExists() {
        let module = SystemStatsModule(service: SystemStatsService())
        XCTAssertNotNil(module.makeExpandedView(),
                        "SystemStatsExpandedView is retained for reuse")
    }

    /// Removing the row left the compact view and standby membership alone.
    /// The compact view is not currently drawn — the collapsed panel shows
    /// only wings — but it is kept, and still builds.
    func testSystemStatsStillContributesItsCompactView() {
        let module = SystemStatsModule(service: SystemStatsService())
        XCTAssertNotNil(module.makeCompactView())
        XCTAssertTrue(module.wantsCompactDisplay,
                      "still an always-on standby module; only the expanded row went")
    }

    /// And it must still drive the shared service on visibility, balanced,
    /// should it become visible again. Today it never is: no expanded row,
    /// no wings.
    func testSystemStatsStillStartsAndStopsItsService() {
        let service = SystemStatsService()
        let module = SystemStatsModule(service: service)
        module.didBecomeVisible()
        module.didResignVisible()
        // No crash and no leaked subscriber: a second resign must not
        // underflow the count into keeping a timer alive.
        module.didResignVisible()
    }

    // MARK: - The mixer door

    /// Wired the way AppDelegate wires it: the coordinator holds the service
    /// (the stats-page pattern) and the module holds it too, for the toggle.
    /// The stub source keeps real Core Audio listeners out of the tests.
    private func makeMixerCoordinator(enabled: Bool = true)
        -> (NotchCoordinator, AppVolumeService, StubAudioProcessSource) {
        let source = StubAudioProcessSource()
        let service = AppVolumeService(source: source,
                                       resolve: { _ in nil },
                                       isAppRunning: { _ in false })
        let coordinator = NotchCoordinator(
            settings: SettingsStore(defaults: defaults),
            arbiter: NotchArbiter(),
            appVolume: service)
        coordinator.register(AppVolumeModule(service: service),
                             enabledByDefault: enabled)
        return (coordinator, service, source)
    }

    func testAppVolumeDestinationMapsToItsModule() {
        XCTAssertEqual(NotchCoordinator.Destination.appVolume.moduleID, "app-volume")
    }

    func testNavigateReachesTheMixerPage() {
        let (coordinator, _, _) = makeMixerCoordinator()
        coordinator.navigate(to: .appVolume)
        XCTAssertEqual(coordinator.destination, .appVolume)
    }

    func testDisablingAppVolumeUnderItsPageSendsYouHome() {
        let (coordinator, _, _) = makeMixerCoordinator()
        coordinator.navigate(to: .appVolume)
        coordinator.setEnabled(false, for: "app-volume")
        XCTAssertEqual(coordinator.destination, .standby)
    }

    /// The module's toggle is the single point where watching starts and
    /// stops — the replacement for Phase 3's #if DEBUG gate. Off means no
    /// listeners registered and nothing logged.
    func testTheToggleStartsAndStopsTheWatching() {
        let (coordinator, _, source) = makeMixerCoordinator(enabled: true)
        XCTAssertTrue(source.isRunning, "registering enabled starts watching")
        coordinator.setEnabled(false, for: "app-volume")
        XCTAssertFalse(source.isRunning, "toggling off stops it")
        coordinator.setEnabled(true, for: "app-volume")
        XCTAssertTrue(source.isRunning)
    }

    func testRegisteringDisabledStartsNothing() {
        let (_, _, source) = makeMixerCoordinator(enabled: false)
        XCTAssertFalse(source.isRunning,
                       "off by default must mean no listeners at all")
    }

    /// Opening the page re-prunes the session rows, so an app that quit
    /// since the last audio event is not still listed. The quit fires no
    /// Core Audio notification when the app held no process objects.
    func testOpeningTheMixerPageRefreshesItsRows() {
        let source = StubAudioProcessSource()
        var running: Set<String> = ["app.a"]
        let owner = AudioOwner(key: "app.a", name: "Alpha",
                               kind: .app, resolution: .ownApp)
        let service = AppVolumeService(source: source,
                                       resolve: { _ in .shown(owner) },
                                       isAppRunning: { running.contains($0) })
        let coordinator = NotchCoordinator(
            settings: SettingsStore(defaults: defaults),
            arbiter: NotchArbiter(),
            appVolume: service)
        coordinator.register(AppVolumeModule(service: service), enabledByDefault: true)

        source.publish([AudioProcessSnapshot(objectID: 1, pid: 10, bundleID: nil,
                                          isRunningOutput: true)])
        source.quietly([])      // the app quits; no notification arrives
        running = []
        XCTAssertFalse(service.mixerRows.isEmpty, "stale before the page opens")
        coordinator.navigate(to: .appVolume)
        XCTAssertTrue(service.mixerRows.isEmpty, "opening the page pruned it")
    }
}
