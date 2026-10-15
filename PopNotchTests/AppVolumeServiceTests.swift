import XCTest
import CoreAudio
import os
@testable import PopNotch

/// Mixer-row rules, from fixtures only, on the stub source the resolver
/// tests already own. Owners and pids are arbitrary test values; nothing
/// here inspects a real process.
@MainActor
final class AppVolumeServiceTests: XCTestCase {

    private var source = StubAudioProcessSource()
    private var running: Set<String> = []

    override func setUp() {
        super.setUp()
        source = StubAudioProcessSource()
        running = []
    }

    private func owner(_ key: String, _ name: String,
                       kind: AudioOwnerKind = .app) -> AudioOwner {
        AudioOwner(key: key, name: name, kind: kind, resolution: .ownApp)
    }

    private func service(_ map: [pid_t: AudioOwnerResult]) -> AppVolumeService {
        let service = AppVolumeService(source: source,
                                       resolve: { map[$0.pid] },
                                       isAppRunning: { [weak self] in
                                           self?.running.contains($0) ?? false
                                       },
                                       logger: Logger(OSLog.disabled))
        service.startWatching()
        return service
    }

    private func proc(_ object: AudioObjectID, _ pid: pid_t,
                      playing: Bool) -> AudioProcessSnapshot {
        AudioProcessSnapshot(objectID: object, pid: pid, bundleID: nil,
                             isRunningOutput: playing)
    }

    func testPlayingAppMakesAPlayingRow() {
        let a = owner("app.a", "Alpha")
        let sut = service([10: .shown(a)])
        source.publish([proc(1, 10, playing: true)])
        XCTAssertEqual(sut.mixerRows,
                       [MixerRow(owner: a, pids: [10], isPlaying: true, neverTapReason: nil)])
    }

    func testPauseKeepsTheRowWhileTheProcessStaysConnected() {
        // Paused apps keep their process objects (measured 2026-09-18), so
        // no app-running check is needed for this case.
        let a = owner("app.a", "Alpha")
        let sut = service([10: .shown(a)])
        source.publish([proc(1, 10, playing: true)])
        source.publish([proc(1, 10, playing: false)])
        XCTAssertEqual(sut.mixerRows,
                       [MixerRow(owner: a, pids: [10], isPlaying: false, neverTapReason: nil)])
    }

    func testARowOutlivesItsProcessesWhileTheAppRuns() {
        // Chrome's audio helper quits about a minute after playback stops
        // while Chrome itself keeps running; the row must stay.
        let a = owner("app.a", "Alpha")
        running = ["app.a"]
        let sut = service([10: .shown(a)])
        source.publish([proc(1, 10, playing: true)])
        source.publish([])
        XCTAssertEqual(sut.mixerRows,
                       [MixerRow(owner: a, pids: [], isPlaying: false, neverTapReason: nil)])
    }

    func testAQuitAppLosesItsRow() {
        let a = owner("app.a", "Alpha")
        let sut = service([10: .shown(a)])
        source.publish([proc(1, 10, playing: true)])
        source.publish([])   // objects gone, and `running` never contained it
        XCTAssertTrue(sut.mixerRows.isEmpty)
    }

    func testWebContentGoesWithItsProcess() {
        // No app to check for web content: the process leaving is the end.
        let web = owner(AudioOwnerResolver.webContentKey,
                        AudioOwnerResolver.webContentName, kind: .webContent)
        let sut = service([20: .shown(web)])
        source.publish([proc(2, 20, playing: true)])
        source.publish([])
        XCTAssertTrue(sut.mixerRows.isEmpty)
    }

    func testNeverTapAppsCarryTheirReason() {
        let mixer = owner("com.finetuneapp.FineTune", "FineTune")
        let sut = service([30: .shown(mixer)])
        source.publish([proc(3, 30, playing: true)])
        XCTAssertEqual(sut.mixerRows.first?.neverTapReason, "audio mixer")
    }

    func testHiddenProcessesNeverReachTheMixer() {
        let sut = service([40: .hidden(.systemAgent, name: "agent")])
        source.publish([proc(4, 40, playing: true)])
        XCTAssertTrue(sut.mixerRows.isEmpty)
        XCTAssertEqual(sut.hiddenCount, 1)
    }

    func testRowsSortByName() {
        let b = owner("app.b", "Bravo"), a = owner("app.a", "alpha")
        let sut = service([10: .shown(b), 11: .shown(a)])
        source.publish([proc(1, 10, playing: true), proc(2, 11, playing: true)])
        XCTAssertEqual(sut.mixerRows.map(\.owner.name), ["alpha", "Bravo"],
                       "case-insensitive, like the log's rows")
    }

    func testRefreshRowsPrunesWithoutAnEvent() {
        // The page-open path: the app quit, but its exit fired no Core Audio
        // notification because nothing else changed.
        let a = owner("app.a", "Alpha")
        running = ["app.a"]
        let sut = service([10: .shown(a)])
        source.publish([proc(1, 10, playing: true)])
        source.quietly([])             // silently — no onChange
        running = []
        XCTAssertFalse(sut.mixerRows.isEmpty, "stale until someone asks")
        sut.refreshRows()
        XCTAssertTrue(sut.mixerRows.isEmpty)
    }

    func testStopWatchingClearsEverything() {
        let a = owner("app.a", "Alpha")
        let sut = service([10: .shown(a)])
        source.publish([proc(1, 10, playing: true)])
        sut.stopWatching()
        XCTAssertTrue(sut.mixerRows.isEmpty)
        XCTAssertTrue(sut.rows.isEmpty)
        XCTAssertFalse(source.isRunning)
    }

    func testRowChangeCallbackFiresOnlyOnChange() {
        let a = owner("app.a", "Alpha")
        let sut = service([10: .shown(a)])
        var fired = 0
        sut.onRowsChange = { fired += 1 }
        source.publish([proc(1, 10, playing: true)])
        XCTAssertEqual(fired, 1)
        source.publish([proc(1, 10, playing: true)])
        XCTAssertEqual(fired, 1, "an identical update must not re-measure the panel")
    }

    /// Opening the page reads the current volume for Spotify's and Music's
    /// rows — their own slider or a phone may have moved it — and for no
    /// other row, which has nothing to read until the tap engine.
    func testOpeningThePageReadsOnlyScriptedPlayers() {
        let a = owner("app.a", "Alpha"), b = owner("app.b", "Bravo")
        let sut = service([10: .shown(a), 11: .shown(b)])
        let players = StubPlayerVolumes()
        players.handled = ["app.a"]
        sut.playerVolumes = players
        source.publish([proc(1, 10, playing: true), proc(2, 11, playing: true)])
        sut.pageDidOpen()
        XCTAssertEqual(players.refreshed, ["app.a"])
    }

    func testListHeightStopsGrowingAtEightRows() {
        XCTAssertEqual(AppVolumePageView.listHeight(rowCount: 3), 132)
        XCTAssertEqual(AppVolumePageView.listHeight(rowCount: 8),
                       AppVolumePageView.listHeight(rowCount: 30),
                       "past eight rows the list scrolls instead of growing")
    }

    // MARK: - Phase 6: another mixer running

    func testTheWarningIsAbsentWhenNoOtherMixerRuns() {
        XCTAssertNil(AppVolumeService.mixerConflictWarning(names: []))
    }

    func testTheWarningSaysWhatIsWrongWithTheSpectrum() {
        let warning = AppVolumeService.mixerConflictWarning(names: ["FineTune"])
        XCTAssertEqual(warning, "FineTune is running. The spectrum may be inaccurate: it re-renders other apps' audio, and the visualiser counts that copy as well as the original.")
    }

    func testTheWarningNamesEveryRunningMixer() {
        let warning = AppVolumeService.mixerConflictWarning(names: ["FineTune", "Sapphire"])
        XCTAssertEqual(warning?.hasPrefix("FineTune and Sapphire are running."), true)
    }

    func testRunningAppsResolveToMixerNames() {
        let sut = service([:])
        sut.applyRunningBundleIDs(["com.apple.Safari", "com.finetuneapp.FineTune"])
        XCTAssertEqual(sut.conflictingMixers, ["FineTune"])
        sut.applyRunningBundleIDs(["com.apple.Safari"])
        XCTAssertEqual(sut.conflictingMixers, [], "quitting it clears the warning")
    }

    func testEveryMixerInTheNeverTapSetIsAlsoNamed() {
        for (bundleID, name) in NeverTapSet.mixerNames {
            XCTAssertEqual(NeverTapSet.reason(for: bundleID), "audio mixer")
            XCTAssertEqual(NeverTapSet.mixerName(forBundleID: bundleID), name)
        }
    }

    func testTheWarningCostsARowRatherThanPanelHeight() {
        XCTAssertEqual(AppVolumePageView.listHeight(rowCount: 30, warningShown: true),
                       AppVolumePageView.listHeight(rowCount: 7),
                       "with the banner up the list shows seven rows, not eight")
        XCTAssertLessThan(AppVolumePageView.listHeight(rowCount: 30, warningShown: true),
                          AppVolumePageView.listHeight(rowCount: 30))
    }
}

/// Stands in for the media module's scripted volumes: records which rows
/// were read, sends no Apple Event.
@MainActor
final class StubPlayerVolumes: ScriptedPlayerVolumes {
    var handled: Set<String> = []
    private(set) var refreshed: [String] = []

    func handlesVolume(for bundleID: String) -> Bool { handled.contains(bundleID) }
    func volume(for bundleID: String) -> Int? { nil }
    func refreshVolume(for bundleID: String) { refreshed.append(bundleID) }
    func beginVolumeEdit(for bundleID: String) {}
    func setVolume(_ value: Int, for bundleID: String) {}
    func endVolumeEdit(for bundleID: String) {}
}
