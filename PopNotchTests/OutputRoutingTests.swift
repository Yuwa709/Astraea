import XCTest
import CoreAudio
import os
@testable import PopNotch

/// V2 per-app output routing: which device an owner's tap renders to, and
/// what happens as devices come and go. Fixtures and the fake HAL only — no
/// test here opens a real tap, reads a real device, or touches the real
/// settings (docs/FUTURE-audio-mixer.md, *Carried from the plan*).

private let speakers = TapHALDevice(uid: "spk", name: "Speakers", sampleRate: 48000,
                                    isStereoOut: true, isAirPlay: false, hasInputStreams: false)
private let dac = TapHALDevice(uid: "usb", name: "DAC", sampleRate: 48000,
                               isStereoOut: true, isAirPlay: false, hasInputStreams: false)
private let room = TapHALDevice(uid: "air", name: "Room", sampleRate: 48000,
                                isStereoOut: true, isAirPlay: true, hasInputStreams: false)
private let headset = TapHALDevice(uid: "set", name: "Headset", sampleRate: 48000,
                                   isStereoOut: true, isAirPlay: false, hasInputStreams: true)

// MARK: - Planning

/// The pure planner's target resolution: chosen, absent, disconnected,
/// reconnected.
final class RoutingReconcilerTests: XCTestCase {

    /// Devices "connected" for this test; a UID missing here is unplugged.
    private var connected: [TapHALDevice] = [speakers, dac, room, headset]

    private func plan(_ desires: [TapDesire], legs: [TapLegFacts] = [])
        -> (ops: [TapPlanOp], states: [String: TapRowState]) {
        TapReconciler.plan(desires: desires, legs: legs, tapsEnabled: true,
                           permissionDenied: false, legsOnDevice: { _ in 0 },
                           device: { uid in self.connected.first { $0.uid == uid } })
    }

    private func desire(position: Int = 40, own: String = "spk",
                        output: String? = "usb") -> TapDesire {
        TapDesire(key: "a", position: position, isPlaying: true, pids: [1],
                  deviceUIDs: [own], outputUID: output)
    }

    private func leg(on device: String, gain: Float = 0.4) -> TapLegFacts {
        TapLegFacts(key: "a", deviceUID: device, pids: [1], gain: gain)
    }

    func testAChosenConnectedDeviceIsWhereTheTapRenders() {
        let result = plan([desire()])
        XCTAssertEqual(result.ops, [.engage(key: "a", deviceUID: "usb", pids: [1], gain: 0.4)])
        XCTAssertEqual(result.states["a"], .engaged)
    }

    func testARouteAloneQualifiesATapAtUnity() {
        // At 100% a tap exists only to move the audio; it must not turn the
        // app down. This is also how a routed Spotify or Music is tapped.
        let result = plan([desire(position: 100)])
        XCTAssertEqual(result.ops, [.engage(key: "a", deviceUID: "usb", pids: [1], gain: 1)])
    }

    func testNoChoiceRendersOnTheOwnDevice() {
        XCTAssertEqual(plan([desire(output: nil)]).ops,
                       [.engage(key: "a", deviceUID: "spk", pids: [1], gain: 0.4)])
        XCTAssertEqual(plan([desire(position: 100, output: nil)]).ops, [],
                       "no choice and full volume: nothing for a tap to do")
    }

    func testChoosingTheDeviceTheAppAlreadyUsesAtFullVolumeBuildsNothing() {
        let result = plan([desire(position: 100, output: "spk")])
        XCTAssertEqual(result.ops, [])
        XCTAssertEqual(result.states["a"], .notTapped)
    }

    func testADisconnectedChoiceFallsBackToTheOwnDevice() {
        connected.removeAll { $0.uid == "usb" }
        XCTAssertEqual(plan([desire()]).ops,
                       [.engage(key: "a", deviceUID: "spk", pids: [1], gain: 0.4)],
                       "the volume still applies, on the app's own output")
    }

    func testADisconnectedChoiceAtFullVolumeLetsTheAppGoHome() {
        connected.removeAll { $0.uid == "usb" }
        let result = plan([desire(position: 100)], legs: [leg(on: "usb", gain: 1)])
        XCTAssertEqual(result.ops, [.disengage(key: "a", afterGrace: false)],
                       "the routed leg comes down; the app plays on its own device untapped")
        XCTAssertEqual(result.states["a"], .notTapped)
    }

    func testAReconnectedChoiceMovesTheLegBack() {
        // After the fallback, the leg is on the own device. The device
        // returning is a move: one engage, make-before-break.
        let result = plan([desire()], legs: [leg(on: "spk")])
        XCTAssertEqual(result.ops, [.engage(key: "a", deviceUID: "usb", pids: [1], gain: 0.4)])
    }

    func testTheGatesApplyToTheTargetNotTheOwnDevice() {
        XCTAssertEqual(plan([desire(output: "air")]).states["a"], .inert(reason: "AirPlay output"),
                       "routing to AirPlay is refused like playing on it")
        XCTAssertEqual(plan([desire(output: "set")]).states["a"],
                       .inert(reason: "output has a microphone"))
        XCTAssertEqual(plan([desire(own: "air", output: "usb")]).ops,
                       [.engage(key: "a", deviceUID: "usb", pids: [1], gain: 0.4)],
                       "an app on AirPlay can be routed to a device the IOProc can write")
    }

    func testTargetResolution() {
        let lookup: (String) -> TapHALDevice? = { uid in [speakers, dac].first { $0.uid == uid } }
        XCTAssertEqual(TapReconciler.target(chosen: "usb", own: "spk", device: lookup), "usb")
        XCTAssertEqual(TapReconciler.target(chosen: nil, own: "spk", device: lookup), "spk")
        XCTAssertEqual(TapReconciler.target(chosen: "gone", own: "spk", device: lookup), "spk")
        XCTAssertEqual(TapReconciler.target(chosen: "spk", own: "spk", device: lookup), "spk")
    }
}

// MARK: - The engine, against the fake HAL

/// Routing through the whole engine lifecycle: create and destroy, not just
/// reads. Everything runs synchronously; delayed work is fired by hand.
@MainActor
final class RoutingEngineTests: XCTestCase {

    private var hal: FakeTapHAL!
    private var engine: TapEngine!
    private var pending: [(delay: TimeInterval, block: () -> Void)] = []
    private var states: [String: TapRowState] = [:]
    private var publishedDevices: [[TapHALDevice]] = []

    override func setUp() {
        super.setUp()
        hal = FakeTapHAL()
        pending = []
        states = [:]
        publishedDevices = []
        engine = TapEngine(hal: hal, queue: nil,
                           rampDelay: 0.12, crossDeviceHandover: 1.0,
                           schedule: { [weak self] delay, block in
                               self?.pending.append((delay, block))
                               return {}
                           },
                           notify: { block in block() })
        engine.onStatesChange = { [weak self] in self?.states = $0 }
        engine.onOutputDevicesChange = { [weak self] in self?.publishedDevices.append($0) }
        engine.setTapsEnabled(true, probing: false)
        engine.refreshOutputDevices()
        hal.calls = []
    }

    private func firePending() {
        while !pending.isEmpty { pending.removeFirst().block() }
    }

    private func fireNext() {
        guard !pending.isEmpty else { return }
        pending.removeFirst().block()
    }

    private func desire(_ key: String = "com.example.app", position: Int = 50,
                        pids: [pid_t] = [42], own: String = "spk",
                        output: String? = "usb") -> TapDesire {
        TapDesire(key: key, position: position, isPlaying: true, pids: pids,
                  deviceUIDs: [own], outputUID: output)
    }

    private func target(_ aggregate: AudioObjectID, slot: Int = 0) -> Float? {
        hal.renders[aggregate]?.targets[slot]
    }

    func testTwoOwnersRoutedToOneDeviceShareItsAggregate() {
        engine.apply(desires: [desire("a", position: 100, pids: [42]),
                               desire("b", position: 100, pids: [43])])
        XCTAssertEqual(hal.calls, [
            .makeTap(pids: [900]),
            .makeAggregate(device: "usb", taps: 1),
            .installIOProc(102),
            .start(102),
            .makeTap(pids: [901]),
            .setTapList(uids: 2, aggregate: 102),
        ], "the second owner joins the first one's aggregate by live edit; nothing is built on the speakers")
        XCTAssertEqual(states["a"], .engaged)
        XCTAssertEqual(states["b"], .engaged)
        XCTAssertEqual(target(102, slot: 0), 1, "routed at 100%: moved, not turned down")
        XCTAssertEqual(target(102, slot: 1), 1)
    }

    func testAnUnpluggedRouteFallsBackToTheOwnDeviceAndReturnsWhenItDoes() throws {
        engine.apply(desires: [desire()])                 // tap 101, aggregate 102 on usb
        hal.calls = []

        let unplugged = try XCTUnwrap(hal.unplug("usb"))
        XCTAssertEqual(hal.calls, [
            .makeTap(pids: [900]),
            .makeAggregate(device: "spk", taps: 1),
            .installIOProc(104),
            .start(104),
        ], "the fallback is built on the app's own device")
        XCTAssertEqual(target(102), 0, "the dead route fades to silence, never up to unity")
        XCTAssertEqual(pending.map(\.delay), [0.12],
                       "the fallback renders where the app plays, so nothing waits for a warm-up")
        firePending()
        XCTAssertEqual(Array(hal.calls.suffix(5)), FakeTapHAL.teardown(102, taps: [101]),
                       "the unplugged device's aggregate is torn down")
        XCTAssertEqual(states["com.example.app"], .engaged, "still turned down, on the fallback")

        hal.calls = []
        hal.plug(unplugged)
        XCTAssertEqual(hal.calls, [
            .makeTap(pids: [900]),
            .makeAggregate(device: "usb", taps: 1),
            .installIOProc(106),
            .start(106),
        ], "the returning device is routed to again, from the choice the engine still holds")
        XCTAssertEqual(pending.map(\.delay), [1.0],
                       "the fallback holds for the cross-device path's warm-up")
        XCTAssertEqual(target(104), 0.5, "and keeps playing at the user's level while it holds")
        firePending()
        XCTAssertEqual(Array(hal.calls.suffix(5)), FakeTapHAL.teardown(104, taps: [103]))
        XCTAssertEqual(states["com.example.app"], .engaged)
    }

    func testAnUnpluggedRouteAtFullVolumeLeavesNoTapAndIsRebuiltOnReturn() throws {
        engine.apply(desires: [desire(position: 100)])
        hal.calls = []
        let unplugged = try XCTUnwrap(hal.unplug("usb"))
        firePending()
        XCTAssertEqual(hal.calls, FakeTapHAL.teardown(102, taps: [101]),
                       "at 100% the fallback is no tap at all: the app plays untouched")
        XCTAssertEqual(states["com.example.app"], .notTapped)

        hal.calls = []
        hal.plug(unplugged)
        XCTAssertTrue(hal.calls.contains(.makeAggregate(device: "usb", taps: 1)))
        XCTAssertEqual(states["com.example.app"], .engaged)
    }

    func testMovingOntoARouteHoldsTheOldLegThenFadesItToSilence() {
        engine.apply(desires: [desire(output: nil)])      // volume only: 102 on spk
        hal.calls = []
        engine.apply(desires: [desire()])                 // routed: 104 on usb
        XCTAssertTrue(hal.calls.contains(.makeAggregate(device: "usb", taps: 1)))
        XCTAssertFalse(hal.calls.contains(.stop(102)), "the old path survives the new one's start")
        XCTAssertEqual(pending.map(\.delay), [1.0])
        XCTAssertEqual(target(102), 0.5, "held at its level: the new path is not yet audible")

        fireNext()                                        // the hold ends
        XCTAssertEqual(target(102), 0, "then it fades to silence: the new tap keeps the app muted")
        XCTAssertEqual(pending.map(\.delay), [0.12])
        firePending()
        XCTAssertTrue(hal.calls.contains(.destroyAggregate(102)))
        XCTAssertFalse(hal.calls.contains(.destroyAggregate(104)))
    }

    func testAnOwnDeviceMoveFadesTheOldDeviceOutWithoutWaiting() {
        // v1's move: the app itself switched output. The old aggregate would
        // otherwise play the app on the device it just left.
        engine.apply(desires: [desire(output: nil)])
        engine.apply(desires: [desire(own: "usb", output: nil)])
        XCTAssertEqual(pending.map(\.delay), [0.12], "a same-device path warms up in ~52 ms; no hold")
        XCTAssertEqual(target(102), 0)
    }

    func testFlippingARouteBackInsideTheHandoverRetiresTheReplacement() {
        engine.apply(desires: [desire(output: nil)])      // 102 on spk
        engine.apply(desires: [desire()])                 // 104 on usb; spk leg holding
        hal.calls = []
        engine.apply(desires: [desire(output: nil)])      // back before the hold ends
        XCTAssertFalse(hal.calls.contains { if case .makeTap = $0 { return true }; return false },
                       "the held leg is revived, not rebuilt")
        XCTAssertEqual(target(102), 0.5)
        firePending()                                     // includes the stale hold
        XCTAssertTrue(hal.calls.contains(.destroyAggregate(104)),
                      "the usb leg must not keep rendering the app on a device nobody chose")
        XCTAssertFalse(hal.calls.contains(.destroyAggregate(102)),
                       "and the stale hold must not retire the revived leg")
        XCTAssertEqual(target(102), 0.5)
        XCTAssertEqual(states["com.example.app"], .engaged)
    }

    func testChoosingSystemDefaultAtFullVolumeFadesTheRouteToSilence() {
        engine.apply(desires: [desire(position: 100)])
        engine.apply(desires: [desire(position: 100, output: nil)])
        XCTAssertEqual(target(102), 0,
                       "the app returns on its own device, not here; this device must not jump to full")
        firePending()
        XCTAssertTrue(hal.calls.contains(.destroyAggregate(102)))
        XCTAssertEqual(states["com.example.app"], .notTapped)
    }

    func testTheDeviceListIsPublishedOnlyWhenItReallyChanges() {
        XCTAssertEqual(publishedDevices.map { $0.map(\.uid) }, [["usb", "spk"]],
                       "sorted by name: DAC, Speakers")
        hal.onDevicesChanged?()   // e.g. one of our own aggregates came or went
        XCTAssertEqual(publishedDevices.count, 1)
        _ = hal.unplug("usb")
        XCTAssertEqual(publishedDevices.last?.map(\.uid), ["spk"])
    }
}

// MARK: - The service

/// What reaches the engine, and what a row says.
@MainActor
final class RoutingServiceTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!
    /// Strong: the service holds the store weakly.
    private var store: SettingsStore!
    private var source = StubAudioProcessSource()

    override func setUp() {
        super.setUp()
        // A scratch suite per test: the real settings are never touched.
        suiteName = "com.techie.PopNotch.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = SettingsStore(defaults: defaults)
        source = StubAudioProcessSource()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        store = nil
        defaults = nil
        super.tearDown()
    }

    private func owner(_ key: String) -> AudioOwner {
        AudioOwner(key: key, name: key, kind: .app, resolution: .ownApp)
    }

    private func service(_ map: [pid_t: AudioOwnerResult] = [:]) -> AppVolumeService {
        let service = AppVolumeService(source: source, resolve: { map[$0.pid] },
                                       isAppRunning: { _ in false },
                                       logger: Logger(OSLog.disabled))
        service.settingsStore = store
        service.startWatching()
        return service
    }

    private func row(_ key: String, neverTap: String? = nil) -> MixerRow {
        MixerRow(owner: owner(key), pids: [7], isPlaying: true, neverTapReason: neverTap,
                 deviceUIDs: ["spk"], engineState: .notTapped)
    }

    // Desires

    func testRoutedScriptedPlayersReachTheEngineAtUnity() {
        let routes = [SpotifyAdapter.bundleID: "usb"]
        let desires = AppVolumeService.desires(
            from: [row(SpotifyAdapter.bundleID), row(MusicAdapter.bundleID), row("org.chromium")],
            position: { _ in 30 },
            output: { routes[$0] })
        XCTAssertEqual(desires.map(\.key), [SpotifyAdapter.bundleID, "org.chromium"],
                       "Music, not routed, stays AppleScript's alone")
        XCTAssertEqual(desires.first?.position, 100,
                       "Spotify's volume stays its own sound volume: a tap only moves it (decision 3)")
        XCTAssertEqual(desires.first?.outputUID, "usb")
        XCTAssertEqual(desires.last?.position, 30)
    }

    func testANeverTapAppIsNeverRoutedEvenWithASavedChoice() {
        let desires = AppVolumeService.desires(
            from: [row("com.finetuneapp.FineTune", neverTap: "audio mixer")],
            position: { _ in 100 },
            output: { _ in "usb" })
        XCTAssertEqual(desires, [])
    }

    // Settings

    func testAChoiceIsSavedByUIDAndSystemDefaultIsAbsence() {
        let sut = service()
        sut.setOutput("usb", for: "org.chromium")
        XCTAssertEqual(store.settings.appVolume.outputs, ["org.chromium": "usb"])
        XCTAssertEqual(sut.output(for: "org.chromium"), "usb")
        sut.setOutput(nil, for: "org.chromium")
        XCTAssertNil(store.settings.appVolume.outputs, "System default is stored as absence")
    }

    func testAnUnpluggedChoiceIsKeptAndShownAsDisconnected() {
        let sut = service()
        sut.applyOutputDevices([dac, speakers])
        sut.setOutput("usb", for: "org.chromium")
        XCTAssertEqual(sut.route(for: "org.chromium"), .device(uid: "usb", name: "DAC"))

        sut.applyOutputDevices([speakers])
        XCTAssertEqual(sut.output(for: "org.chromium"), "usb", "the saved UID survives the unplug")
        XCTAssertEqual(sut.route(for: "org.chromium"), .disconnected(uid: "usb", name: "DAC"),
                       "named from this session's sighting, not shown as the fallback")

        sut.applyOutputDevices([dac, speakers])
        XCTAssertEqual(sut.route(for: "org.chromium"), .device(uid: "usb", name: "DAC"))
    }

    func testAChoiceNeverSeenThisSessionIsDisconnectedWithoutAName() {
        XCTAssertEqual(AppVolumeService.route(chosenUID: "usb", devices: [speakers], knownNames: [:]),
                       .disconnected(uid: "usb", name: nil))
        XCTAssertEqual(AppVolumeService.route(chosenUID: nil, devices: [speakers], knownNames: [:]),
                       .systemDefault)
    }

    // End to end, fake HAL underneath

    func testRoutingSpotifyTapsItAtUnityAndOnlyThen() {
        let spotify = owner(SpotifyAdapter.bundleID)
        store.update { $0.appVolume.tapsEnabled = true }
        let hal = FakeTapHAL()
        hal.processObjects[10] = 910
        let engine = TapEngine(hal: hal, queue: nil,
                               schedule: { _, _ in {} }, notify: { $0() })
        engine.setTapsEnabled(true, probing: false)
        let sut = service([10: .shown(spotify)])
        sut.tapEngine = engine
        source.publish([AudioProcessSnapshot(objectID: 1, pid: 10, bundleID: nil,
                                             isRunningOutput: true, outputDeviceUIDs: ["spk"])])
        XCTAssertEqual(hal.calls, [], "unrouted, Spotify is never tapped")

        sut.setOutput("usb", for: spotify.key)
        XCTAssertEqual(hal.calls, [
            .makeTap(pids: [910]),
            .makeAggregate(device: "usb", taps: 1),
            .installIOProc(102),
            .start(102),
        ])
        XCTAssertEqual(hal.renders[102]?.targets[0], 1, "unity: the slider stays AppleScript's")
    }

    // Row text

    func testCaptionsSayWhereTheAppPlays() {
        var r = row("org.chromium")
        func caption(_ route: OutputRoute, scripted: Bool = false, taps: Bool = true) -> String {
            AppVolumeService.caption(for: r, scripted: scripted, tapsEnabled: taps, route: route)
        }
        XCTAssertEqual(caption(.systemDefault), "Playing")
        XCTAssertEqual(caption(.device(uid: "usb", name: "DAC")), "Playing on DAC")
        XCTAssertEqual(caption(.disconnected(uid: "usb", name: "DAC")), "Disconnected · DAC")
        XCTAssertEqual(caption(.disconnected(uid: "usb", name: nil)), "Saved output disconnected")
        r.isPlaying = false
        XCTAssertEqual(caption(.device(uid: "usb", name: "DAC")), "Not playing · DAC")
    }

    func testAScriptedRowOnlyMentionsTapsOnceRouted() {
        let r = row(SpotifyAdapter.bundleID)
        XCTAssertEqual(AppVolumeService.caption(for: r, scripted: true, tapsEnabled: false,
                                                route: .systemDefault), "Playing",
                       "its slider works without taps")
        XCTAssertEqual(AppVolumeService.caption(for: r, scripted: true, tapsEnabled: false,
                                                route: .device(uid: "usb", name: "DAC")),
                       "Output needs taps on")
    }

    func testTheMenuExplainsDevicesItCannotRouteTo() {
        XCTAssertNil(AppVolumeService.routeUnavailableReason(dac))
        XCTAssertEqual(AppVolumeService.routeUnavailableReason(room), "AirPlay")
        XCTAssertEqual(AppVolumeService.routeUnavailableReason(headset), "has a microphone")
    }
}
