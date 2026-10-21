import XCTest
@testable import Astraea

/// What runs in each panel state, end to end through the coordinator.
///
/// `NotchArbiterTests` pins the visibility mapping in isolation; this pins
/// what a battery sees. Collapsed on the wings with music playing, neither
/// the media live-sync clock nor the stats sampler may run — both did, for
/// the life of the process, while visibility meant membership of standby
/// rather than the open panel (measured 2026-09-13).
@MainActor
final class NotchVisibilityTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suite = "com.techie.Astraea.visibilitytests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private struct Harness {
        let coordinator: NotchCoordinator
        let arbiter: NotchArbiter
        let media: MediaModule
        let player: StubMediaSource
        let stats: SystemStatsService
        let battery: BatteryService
        let visualizer: AudioVisualizerService
    }

    /// Wired the way AppDelegate wires it. Needs a screen: the coordinator
    /// reports what the panel shows only once the panel exists.
    private func makeHarness(playing: Bool = true) throws -> Harness {
        guard ScreenPolicy.targetScreen() != nil else {
            throw XCTSkip("No screen: visibility is reported only once the panel exists")
        }
        let stats = SystemStatsService()
        let battery = BatteryService()
        let arbiter = NotchArbiter()
        let coordinator = NotchCoordinator(
            settings: SettingsStore(defaults: defaults),
            arbiter: arbiter,
            pinState: PinState(),
            statsPage: .init(stats: stats, battery: battery))

        let player = StubMediaSource(id: "spotify", running: true)
        // Captures through a fake, so no test here can open a real
        // system-audio tap; what the module reports is still readable as
        // `spectrumVisible`.
        let visualizer = AudioVisualizerService(makeCapture: { _, _ in FakeAudioCapture() })
        let media = MediaModule(sources: [player], visualizer: visualizer)
        media.onPresenceChange = { [weak coordinator] in coordinator?.refreshPresentation() }
        media.onContentReflow = { [weak coordinator] in coordinator?.refreshPresentation() }
        coordinator.register(media)
        coordinator.register(SystemStatsModule(service: stats))
        coordinator.start()

        let harness = Harness(coordinator: coordinator, arbiter: arbiter, media: media,
                              player: player, stats: stats, battery: battery,
                              visualizer: visualizer)
        if playing { play(on: harness) }
        return harness
    }

    /// A title with no artist: enough to have content and put the wings up,
    /// but nothing for the lyrics lookup to search, so no test reaches LRCLIB.
    /// With a duration, so the player draws its progress row and spectrum.
    private func play(on harness: Harness) {
        harness.player.publish(Self.track(duration: 200))
    }

    private static func track(duration: TimeInterval?) -> NowPlaying {
        var snapshot = NowPlaying()
        snapshot.title = "Track"
        snapshot.duration = duration
        snapshot.isPlaying = true
        return snapshot
    }

    /// The battery report's scenario.
    func testNothingPollsBehindTheCollapsedWingsWhileMusicPlays() throws {
        let h = try makeHarness()
        XCTAssertNotNil(h.media.makeCompactLeadingView(), "precondition: the wings are up")

        XCTAssertFalse(h.media.isLiveSyncing, "no live sync behind the collapsed wings")
        XCTAssertEqual(h.stats.subscribers, 0, "no stats sampling behind the collapsed wings")
        XCTAssertTrue(h.arbiter.visibleIDs.isEmpty)
    }

    func testOpeningThePanelRunsLiveSyncAndCollapsingStopsIt() throws {
        let h = try makeHarness()

        h.coordinator.setPinned(true)
        XCTAssertTrue(h.media.isLiveSyncing, "open on the player: live sync runs")
        XCTAssertEqual(h.stats.subscribers, 0, "stats has no expanded row to sample for")
        XCTAssertEqual(h.arbiter.visibleIDs, ["media"])

        h.coordinator.setPinned(false)
        XCTAssertFalse(h.media.isLiveSyncing, "collapsed again: the clock stops")
    }

    /// The page and the player are never on screen together, so their
    /// timers never run together either.
    func testTheStatsPageSwapsLiveSyncForStatsSampling() throws {
        let h = try makeHarness()
        h.coordinator.setPinned(true)

        h.coordinator.navigate(to: .systemStats)
        XCTAssertFalse(h.media.isLiveSyncing, "the stats page replaces the player")
        XCTAssertEqual(h.stats.subscribers, 1, "the page's own subscription, and only that")

        h.coordinator.navigate(to: .standby)
        XCTAssertTrue(h.media.isLiveSyncing, "Back returns to the player")
        XCTAssertEqual(h.stats.subscribers, 0)

        h.coordinator.setPinned(false)
    }

    func testRepeatedOpenCloseCyclesLeaveNothingRunning() throws {
        let h = try makeHarness()
        for cycle in 1...5 {
            h.coordinator.setPinned(true)
            h.coordinator.navigate(to: .systemStats)
            h.coordinator.navigate(to: .standby)
            h.coordinator.setPinned(false)
            XCTAssertFalse(h.media.isLiveSyncing, "live sync left running after cycle \(cycle)")
            XCTAssertEqual([h.stats.subscribers, h.battery.subscribers],
                           [0, 0], "a sampler left running after cycle \(cycle)")
            XCTAssertTrue(h.arbiter.visibleIDs.isEmpty, "a module left visible after cycle \(cycle)")
        }
    }

    /// Music starting under an open, empty panel: the presence change
    /// re-applies state, and that is what must start the clock.
    func testMusicStartingUnderTheOpenPanelStartsLiveSync() throws {
        let h = try makeHarness(playing: false)
        h.coordinator.setPinned(true)
        XCTAssertFalse(h.media.isLiveSyncing, "nothing to show yet, so not visible")

        play(on: h)
        XCTAssertTrue(h.media.isLiveSyncing)

        h.coordinator.setPinned(false)
        XCTAssertFalse(h.media.isLiveSyncing)
    }

    func testDisablingMediaWhileOpenStopsLiveSync() throws {
        let h = try makeHarness()
        h.coordinator.setPinned(true)
        XCTAssertTrue(h.media.isLiveSyncing)

        h.coordinator.setEnabled(false, for: "media")
        XCTAssertFalse(h.media.isLiveSyncing)

        h.coordinator.setPinned(false)
    }

    // MARK: - The audio visualiser's spectrum

    /// Only the player screen draws the spectrum, in its progress row.
    func testOnlyThePlayerScreenDrawsTheSpectrum() {
        XCTAssertTrue(MediaModule.drawsSpectrum(on: .player(Self.track(duration: 200))))
        XCTAssertFalse(MediaModule.drawsSpectrum(on: .fullLyrics), "the takeover replaces the player")
        XCTAssertFalse(MediaModule.drawsSpectrum(on: .permissionDenied), "the banner has no spectrum")
        XCTAssertFalse(MediaModule.drawsSpectrum(on: nil), "nothing to show, nothing drawn")
    }

    /// The progress row, and the spectrum in it, exist only with a duration.
    func testAPlayerWithoutADurationDrawsNoSpectrum() {
        XCTAssertFalse(MediaModule.drawsSpectrum(on: .player(Self.track(duration: nil))),
                       "no duration, no progress row")
        XCTAssertFalse(MediaModule.drawsSpectrum(on: .player(Self.track(duration: 0))),
                       "a zero duration draws no row either")
    }

    /// A duration arriving after the title (artwork mid-load) turns the
    /// spectrum on then, not before; losing it turns it off.
    func testSpectrumFollowsTheDurationOnAnOpenPlayer() throws {
        let h = try makeHarness(playing: false)
        h.player.publish(Self.track(duration: nil))
        h.coordinator.setPinned(true)
        XCTAssertFalse(h.visualizer.spectrumVisible, "open on the player, but no row to draw in")

        h.player.publish(Self.track(duration: 200))
        XCTAssertTrue(h.visualizer.spectrumVisible, "the duration arrived")

        h.player.publish(Self.track(duration: nil))
        XCTAssertFalse(h.visualizer.spectrumVisible, "the duration went away")

        h.coordinator.setPinned(false)
    }

    func testSpectrumIsOnScreenOnlyWhileTheOpenPanelShowsThePlayer() throws {
        let h = try makeHarness()
        XCTAssertFalse(h.visualizer.spectrumVisible, "collapsed on the wings: no spectrum")

        h.coordinator.setPinned(true)
        XCTAssertTrue(h.visualizer.spectrumVisible, "open on the player")

        h.coordinator.setPinned(false)
        XCTAssertFalse(h.visualizer.spectrumVisible, "collapsed again")
    }

    /// The regression: capture followed the panel, so it ran behind every
    /// screen that fills an open panel without drawing the spectrum.
    func testNoOtherScreenCountsAsTheSpectrum() throws {
        let h = try makeHarness()
        h.coordinator.register(ClipboardModule(service: ClipboardService()))
        h.coordinator.register(FileShelfModule(service: FileShelfService()))
        h.coordinator.setPinned(true)

        let screens: [NotchCoordinator.Destination] = [.systemStats, .clipboard, .fileShelf]
        for screen in screens {
            h.coordinator.navigate(to: screen)
            XCTAssertFalse(h.visualizer.spectrumVisible, "\(screen) draws no spectrum")
            h.coordinator.navigate(to: .standby)
            XCTAssertTrue(h.visualizer.spectrumVisible, "back on the player from \(screen)")
        }

        h.coordinator.setPinned(false)
    }

    /// The permission banner fills the player's slot and the module is
    /// visible, but there is no spectrum.
    func testPermissionBannerIsNotTheSpectrum() throws {
        let h = try makeHarness(playing: false)
        h.player.permissionDenied = true
        h.coordinator.setPinned(true)
        XCTAssertEqual(h.arbiter.visibleIDs, ["media"], "precondition: the banner is showing")
        XCTAssertFalse(h.visualizer.spectrumVisible)

        h.coordinator.setPinned(false)
    }
}
