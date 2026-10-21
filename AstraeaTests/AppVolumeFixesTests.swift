import XCTest
import CoreAudio
@testable import Astraea

/// The 2026-10-13 review fixes to the tap engine, its planner and its render
/// path, against the fake HAL and synthesized buffers. No test here opens a
/// real tap or aggregate.
@MainActor
final class AppVolumeEngineFixesTests: XCTestCase {

    private var hal: FakeTapHAL!
    private var engine: TapEngine!
    private var pending: [(delay: TimeInterval, block: () -> Void)] = []
    private var states: [String: TapRowState] = [:]
    /// The engine's clock, moved by hand.
    private var clock: TimeInterval = 1000

    private let deviceBusy = OSStatus(kAudioHardwareUnspecifiedError)

    override func setUp() {
        super.setUp()
        hal = FakeTapHAL()
        hal.processObjects[45] = 903
        pending = []
        states = [:]
        clock = 1000
        engine = TapEngine(hal: hal, queue: nil,
                           now: { [weak self] in self?.clock ?? 0 },
                           schedule: { [weak self] delay, block in
                               self?.pending.append((delay, block))
                               return {}
                           },
                           notify: { block in block() })
        engine.onStatesChange = { [weak self] in self?.states = $0 }
        engine.setTapsEnabled(true, probing: false)
        hal.calls = []
        hal.watchHistory = []
    }

    private func firePending() {
        while !pending.isEmpty { pending.removeFirst().block() }
    }

    private func fireNext() {
        guard !pending.isEmpty else { return }
        pending.removeFirst().block()
    }

    private func desire(_ key: String = "a", position: Int = 50, playing: Bool = true,
                        pids: [pid_t] = [42], devices: [String] = ["spk"]) -> TapDesire {
        TapDesire(key: key, position: position, isPlaying: playing, pids: pids, deviceUIDs: devices)
    }

    private func mappingRow(_ render: TapRenderState, count: Int) -> [Int32] {
        (0..<count).map { render.mapping[count * TapRenderState.maxLegs + $0] }
    }

    // MARK: - Finding 1: a start failure is not a denial by itself

    func testAStartFailureWithAPassingProbeMarksOnlyThatDeviceInert() {
        hal.failingStarts["usb"] = deviceBusy
        engine.apply(desires: [desire("b", pids: [43]), desire("a", devices: ["usb"])])
        XCTAssertTrue(hal.calls.contains(.makeProbeTap), "the failure is disambiguated by the probe")
        XCTAssertEqual(states["a"], .inert(reason: "output couldn't start"))
        XCTAssertEqual(states["b"], .engaged, "the other device's leg is untouched")
        XCTAssertFalse(hal.calls.contains(.destroyAggregate(102)), "nothing on the speakers comes down")
        XCTAssertNotEqual(states["b"], .inert(reason: "permission needed"))
    }

    func testADeviceThatWillNotStartIsNotRetriedAtPointerRate() {
        hal.failingStarts["usb"] = deviceBusy
        engine.apply(desires: [desire(devices: ["usb"])])
        hal.calls = []
        for position in [45, 40, 35, 30] {
            engine.apply(desires: [desire(position: position, devices: ["usb"])])
        }
        XCTAssertEqual(hal.calls, [], "a drag does not rebuild, restart or re-probe the failing device")
        XCTAssertEqual(states["a"], .inert(reason: "output couldn't start"))

        clock += 3
        hal.failingStarts = [:]
        engine.apply(desires: [desire(position: 30, devices: ["usb"])])
        XCTAssertTrue(hal.calls.contains(.makeAggregate(device: "usb", taps: 1)),
                      "after the cooldown the next reconcile tries again")
        XCTAssertEqual(states["a"], .engaged)
    }

    // MARK: - Finding 7: a move that cannot be built keeps the old leg

    func testAMoveOntoADeviceThatWillNotStartKeepsTheOldLeg() {
        engine.apply(desires: [desire()])                          // 101 on 102 (spk)
        hal.failingStarts["usb"] = deviceBusy
        hal.calls = []
        engine.apply(desires: [desire(devices: ["usb"])])
        XCTAssertFalse(hal.calls.contains(.destroyAggregate(102)), "the old path is not torn down")
        XCTAssertEqual(pending.count, 0, "and not retired: no hold, fade or removal is scheduled")
        XCTAssertEqual(hal.renders[102]?.targets[0], 0.5, "the app stays at its level, never at full")
        XCTAssertEqual(states["a"], .inert(reason: "output couldn't start"))

        hal.calls = []
        engine.apply(desires: [desire(position: 30, devices: ["usb"])])
        XCTAssertEqual(hal.calls, [], "and the failing move is not retried during a drag")
    }

    func testAMoveWhoseProcessVanishedKeepsTheOldLegAndDoesNotRetry() {
        engine.apply(desires: [desire()])
        hal.calls = []
        engine.apply(desires: [desire(pids: [99], devices: ["usb"])])
        XCTAssertEqual(pending.count, 0, "the old leg is not retired before the new one exists")
        XCTAssertFalse(hal.calls.contains(.destroyAggregate(102)))
        let lookups = hal.processObjectLookups
        for position in [45, 40, 35] {
            engine.apply(desires: [desire(position: position, pids: [99], devices: ["usb"])])
        }
        XCTAssertEqual(hal.processObjectLookups, lookups, "remembered: no lookups at pointer rate")
    }

    // MARK: - Findings 2 and 12: a pid change is make-before-break, crossfaded

    func testAPidChangeCrossfadesFromTheOldLegToTheNewOne() throws {
        engine.apply(desires: [desire()])                          // slot 0
        let render = try XCTUnwrap(hal.renders[102])
        hal.calls = []
        engine.apply(desires: [desire(pids: [44])])
        XCTAssertEqual(hal.calls, [.makeTap(pids: [902]), .setTapList(uids: 2, aggregate: 102)])
        XCTAssertEqual(render.current[1], 0, "the new leg ramps in from silence")
        XCTAssertEqual(render.targets[1], 0.5)
        XCTAssertEqual(render.targets[0], 0, "the old leg fades out")
        XCTAssertEqual(render.handoverSlots[0], 1,
                       "but only once the new stream has arrived, which the IO thread decides")
        XCTAssertEqual(pending.map(\.delay), [0.12])
        firePending()
        XCTAssertEqual(Array(hal.calls.suffix(2)), [.setTapList(uids: 1, aggregate: 102), .destroyTap(101)])
        XCTAssertEqual(render.handoverSlots[0], -1, "a released slot carries no handover")
        XCTAssertEqual(states["a"], .engaged)
    }

    func testAPidChangeThatCannotBeTappedLeavesTheOldLegAlone() {
        engine.apply(desires: [desire()])
        hal.calls = []
        engine.apply(desires: [desire(pids: [99])])
        XCTAssertEqual(hal.calls, [], "no tap, and nothing torn down")
        XCTAssertEqual(pending.count, 0)
        XCTAssertEqual(hal.renders[102]?.targets[0], 0.5)
    }

    func testAMovedLegOpensAtItsPredecessorsGainNotAtUnity() {
        engine.apply(desires: [desire()])
        engine.apply(desires: [desire(devices: ["usb"])])          // 104 on usb
        XCTAssertEqual(hal.renders[104]?.current[0], 0.5)
    }

    func testPreparingASlotTakesItsStartGain() {
        let render = TapRenderState(sampleRate: 48000)
        render.prepareSlot(1, targetGain: 0.3, startGain: 0.6)
        XCTAssertEqual(render.current[1], 0.6)
        XCTAssertEqual(render.handoverSlots[1], -1)
    }

    // MARK: - Finding 3: no mapping row is rewritten while it may be on show

    /// [A, X, B] → X leaves → C joins. Before the removal lands, three
    /// buffers still mean [A, X, B]; writing [A, B, C] into that row would
    /// play B at C's gain.
    func testAJoinWaitsForTheLastRemovalToLand() throws {
        engine.apply(desires: [desire("a"), desire("x", pids: [43]), desire("b", pids: [44])])
        let render = try XCTUnwrap(hal.renders[102])
        let before = mappingRow(render, count: 3)
        XCTAssertEqual(before, [0, 1, 2])
        hal.simulatesIO = false
        engine.apply(desires: [desire("a"), desire("x", position: 100, pids: [43]), desire("b", pids: [44])])
        firePending()                                              // X removed: list of 2, not yet seen
        XCTAssertEqual(hal.tapLists[102]?.count, 2)

        hal.calls = []
        let withC = [desire("a"), desire("x", position: 100, pids: [43]), desire("b", pids: [44]),
                     desire("c", pids: [45])]
        engine.apply(desires: withC)
        XCTAssertEqual(hal.calls, [], "C does not join while the HAL may still present [A, X, B]")
        XCTAssertEqual(mappingRow(render, count: 3), before, "and the three-buffer row is untouched")
        XCTAssertEqual(pending.map(\.delay), [0.05], "one retry is armed")
        engine.apply(desires: withC)
        XCTAssertEqual(pending.count, 1, "more reconciles do not stack retries")

        hal.deliverCallback(102)                                   // the IO thread presents 2
        fireNext()
        XCTAssertEqual(hal.calls, [.makeTap(pids: [903]), .setTapList(uids: 3, aggregate: 102)])
        XCTAssertEqual(mappingRow(render, count: 3), [0, 2, 3])
    }

    func testAnEditThatIsNeverSeenToLandStopsBlockingAfterTheTimeout() {
        engine.apply(desires: [desire("a"), desire("x", pids: [43])])
        hal.simulatesIO = false
        engine.apply(desires: [desire("a"), desire("x", position: 100, pids: [43])])
        firePending()                                              // X removed, unseen
        hal.calls = []
        let withC = [desire("a"), desire("x", position: 100, pids: [43]), desire("c", pids: [45])]
        engine.apply(desires: withC)
        XCTAssertEqual(hal.calls, [])
        clock += 0.5
        fireNext()
        XCTAssertEqual(hal.calls, [], "still inside the timeout")
        clock += 1.5
        fireNext()
        XCTAssertEqual(hal.calls, [.makeTap(pids: [903]), .setTapList(uids: 2, aggregate: 102)],
                       "an aggregate whose IO never runs cannot wedge the engine")
    }

    /// A rebuild's removal of the old leg writes the row the join left on
    /// show; it waits for the join to land, then gives the crossfade its ramp.
    func testARebuildsRemovalWaitsForTheJoinToLand() {
        hal.simulatesIO = false
        engine.apply(desires: [desire()])
        engine.apply(desires: [desire(pids: [44])])               // join: list of 2, unseen
        hal.calls = []
        fireNext()                                                 // the removal, due after the fade
        XCTAssertEqual(hal.calls, [], "the old leg stays while the new stream may not be there yet")
        XCTAssertEqual(pending.map(\.delay), [0.05])
        hal.deliverCallback(102)
        fireNext()
        XCTAssertEqual(hal.calls, [], "landed: the fade gets its ramp before the removal")
        XCTAssertEqual(pending.map(\.delay), [0.12])
        fireNext()
        XCTAssertEqual(hal.calls, [.setTapList(uids: 1, aggregate: 102), .destroyTap(101)])
    }

    // MARK: - Finding 4: teardown empties the tap list first, and carries on

    func testATeardownWhoseListEditFailsStillDestroysEverything() {
        engine.apply(desires: [desire()])
        hal.tapListEditSucceeds = false
        hal.calls = []
        engine.apply(desires: [])
        firePending()
        XCTAssertEqual(hal.calls, FakeTapHAL.teardown(102, taps: [101]),
                       "every step runs even when the first fails")
    }

    // MARK: - Finding 5: a format change rebuilds before it tears down

    func testAFormatChangeCarriesEveryLegsGainIntoTheReplacement() throws {
        engine.apply(desires: [desire("a"), desire("b", position: 30, pids: [43])])
        hal.calls = []
        hal.onDeviceFormatChanged?("spk")
        let build: [FakeTapHAL.Call] = [
            .makeTap(pids: [900]),
            .makeAggregate(device: "spk", taps: 1),
            .installIOProc(105),
            .start(105),
            .makeTap(pids: [901]),
            .setTapList(uids: 2, aggregate: 105),
        ]
        XCTAssertEqual(hal.calls, build, "nothing of the old aggregate comes down with the build")
        let render = try XCTUnwrap(hal.renders[105])
        XCTAssertEqual(render.current[0], 0.5)
        XCTAssertEqual(render.current[1], 0.3, accuracy: 0.0001)
        let oldRender = try XCTUnwrap(hal.renders[102])
        XCTAssertEqual(oldRender.targets[0], 0, "the replacement is live: both old legs fade to silence")
        XCTAssertEqual(oldRender.targets[1], 0)
        XCTAssertEqual(pending.map(\.delay), [0.12], "and the old aggregate folds after the ramp")
        firePending()
        XCTAssertEqual(hal.calls, build + FakeTapHAL.teardown(102, taps: [101, 103]))
        XCTAssertEqual(states["a"], .engaged)
        XCTAssertEqual(states["b"], .engaged)
    }

    /// Nothing comes down until the IO thread presents the replacement's
    /// whole tap list: the second leg joins by live edit, which can take up
    /// to ~1 s to land (M1), and the old legs keep both apps playing at
    /// their levels meanwhile.
    func testAFormatChangeKeepsTheOldAggregateUntilTheReplacementIsLive() throws {
        engine.apply(desires: [desire("a"), desire("b", position: 30, pids: [43])])
        let oldRender = try XCTUnwrap(hal.renders[102])
        hal.simulatesIO = false
        hal.calls = []
        hal.onDeviceFormatChanged?("spk")
        XCTAssertFalse(hal.calls.contains(.setTapList(uids: 0, aggregate: 102)), "the old list is not emptied")
        XCTAssertFalse(hal.calls.contains(.destroyAggregate(102)))
        XCTAssertEqual(oldRender.targets[0], 0.5, "the old legs keep rendering at their levels")
        XCTAssertEqual(oldRender.targets[1], 0.3, accuracy: 0.0001)
        XCTAssertEqual(pending.map(\.delay), [0.05], "one observation retry is armed")

        clock += 0.05
        fireNext()
        XCTAssertFalse(hal.calls.contains(.destroyAggregate(102)), "nothing presented yet: still waiting")
        XCTAssertEqual(pending.map(\.delay), [0.05])

        hal.renders[105]?.observedBufferCount.pointee = 1          // only the first leg so far
        clock += 0.05
        fireNext()
        XCTAssertFalse(hal.calls.contains(.destroyAggregate(102)), "the joining leg's stream is not there yet")
        XCTAssertEqual(oldRender.targets[1], 0.3, accuracy: 0.0001)

        hal.deliverCallback(105)                                    // both streams presented
        hal.calls = []
        clock += 0.05
        fireNext()
        XCTAssertEqual(hal.calls, [], "live: the old legs fade before anything is torn down")
        XCTAssertEqual(oldRender.targets[0], 0)
        XCTAssertEqual(oldRender.targets[1], 0)
        XCTAssertEqual(pending.map(\.delay), [0.12])
        fireNext()
        XCTAssertEqual(hal.calls, FakeTapHAL.teardown(102, taps: [101, 103]))
        XCTAssertFalse(hal.calls.contains(.destroyAggregate(105)), "the replacement stays")
        XCTAssertEqual(states["a"], .engaged)
        XCTAssertEqual(states["b"], .engaged)
    }

    func testAReplacementNeverSeenLiveStillRetiresTheOldAggregateAfterTheTimeout() {
        engine.apply(desires: [desire("a")])
        hal.simulatesIO = false
        hal.calls = []
        hal.onDeviceFormatChanged?("spk")
        clock += 0.5
        fireNext()
        XCTAssertFalse(hal.calls.contains(.destroyAggregate(102)), "inside the timeout it waits")
        clock += 1.5
        fireNext()
        XCTAssertEqual(Array(hal.calls.suffix(5)), FakeTapHAL.teardown(102, taps: [101]),
                       "past it the old aggregate goes anyway, so nothing leaks")
        XCTAssertEqual(pending.count, 0, "and nothing is left polling")
        XCTAssertFalse(hal.calls.contains(.destroyAggregate(104)))
        XCTAssertEqual(states["a"], .engaged)
    }

    /// A device that grew a microphone is no longer a target: no
    /// replacement is built, so there is nothing to wait for.
    func testAFormatChangeWithNoReplacementTearsTheOldAggregateDownAtOnce() {
        engine.apply(desires: [desire("a")])
        hal.devices["spk"]?.hasInputStreams = true
        hal.calls = []
        hal.onDeviceFormatChanged?("spk")
        XCTAssertEqual(hal.calls, FakeTapHAL.teardown(102, taps: [101]))
        XCTAssertEqual(pending.count, 0)
        XCTAssertEqual(states["a"], .inert(reason: "output has a microphone"))
    }

    // MARK: - A failed move off a device that is gone

    private func routed(_ output: String?, position: Int = 50) -> TapDesire {
        TapDesire(key: "a", position: position, isPlaying: true, pids: [42],
                  deviceUIDs: ["spk"], outputUID: output)
    }

    /// The routed DAC is unplugged and the fallback onto the speakers will
    /// not start. The old leg's tap would keep the app muted while it
    /// renders to a device that no longer exists, so it is retired.
    func testAFailedFallbackOffAnUnpluggedDeviceRetiresTheOldLeg() throws {
        var tapped: [pid_t] = [-1]
        engine.onTappedProcessesChange = { tapped = $0 }
        engine.apply(desires: [routed("usb")])                    // 101 on 102 (usb)
        XCTAssertEqual(tapped, [42])
        hal.failingStarts["spk"] = deviceBusy
        hal.calls = []
        _ = try XCTUnwrap(hal.unplug("usb"))
        XCTAssertTrue(hal.calls.contains(.start(104)), "the fallback was tried")
        XCTAssertFalse(hal.calls.contains(.start(102)))
        XCTAssertEqual(pending.map(\.delay), [0.12], "the old leg is retired at once, no hold")
        firePending()
        XCTAssertEqual(Array(hal.calls.suffix(5)), FakeTapHAL.teardown(102, taps: [101]),
                       "the dead device's tap leaves its list: the app is unmuted")
        XCTAssertEqual(tapped, [], "nothing taps the app any more")
        XCTAssertEqual(states["a"], .inert(reason: "output couldn't start"))
    }

    func testAFailedJoinOffAnUnpluggedDeviceRetiresTheOldLeg() throws {
        engine.apply(desires: [routed("usb"), desire("b", pids: [43])])  // a: 101/102 usb, b: 103/104 spk
        hal.tapListEditSucceeds = false
        hal.calls = []
        _ = try XCTUnwrap(hal.unplug("usb"))
        XCTAssertTrue(hal.calls.contains(.setTapList(uids: 2, aggregate: 104)),
                      "the fallback join onto the speakers was tried")
        firePending()
        XCTAssertTrue(hal.calls.contains(.destroyAggregate(102)), "the old leg and its aggregate go")
        XCTAssertTrue(hal.calls.contains(.destroyTap(101)))
        XCTAssertFalse(hal.calls.contains(.destroyAggregate(104)), "b is untouched")
        XCTAssertEqual(states["a"], .notTapped)
        XCTAssertEqual(states["b"], .engaged)
    }

    /// The same failure with the old device still connected keeps the old
    /// leg, at its level: there it is still rendering the app.
    func testAFailedMoveOffADeviceStillConnectedKeepsTheOldLeg() {
        engine.apply(desires: [routed("usb")])                    // 101 on 102 (usb)
        hal.failingStarts["spk"] = deviceBusy
        hal.calls = []
        engine.apply(desires: [routed(nil)])                       // back to System default
        XCTAssertTrue(hal.calls.contains(.start(104)), "the move was tried")
        XCTAssertEqual(pending.count, 0, "the old leg is not retired")
        XCTAssertFalse(hal.calls.contains(.destroyAggregate(102)))
        XCTAssertEqual(hal.renders[102]?.targets[0], 0.5, "and keeps rendering at the user's level")
        XCTAssertEqual(states["a"], .inert(reason: "output couldn't start"))
    }

    // MARK: - Finding 6: an output switch in flight keeps the leg

    func testALegRidesOutAMomentWithNoOutputDevice() {
        engine.apply(desires: [desire()])
        hal.calls = []
        engine.apply(desires: [desire(devices: [])])
        XCTAssertEqual(hal.calls, [], "nothing comes down at once")
        XCTAssertEqual(pending.map(\.delay), [3.0], "the grace is armed instead")
        XCTAssertEqual(states["a"], .engaged)
        engine.apply(desires: [desire()])                          // AirPods settled on spk again
        firePending()
        XCTAssertEqual(hal.calls, [], "a settled owner keeps its leg when the stale grace fires")
        XCTAssertEqual(states["a"], .engaged)
    }

    func testALegOnTwoDevicesComesDownWhenTheGraceExpires() {
        engine.apply(desires: [desire()])
        hal.calls = []
        engine.apply(desires: [desire(devices: ["spk", "usb"])])
        XCTAssertEqual(hal.calls, [])
        firePending()
        XCTAssertEqual(hal.calls, FakeTapHAL.teardown(102, taps: [101]),
                       "still on two outputs at expiry: it comes down")
    }

    // MARK: - Finding 9: format listeners never stay on a dead object

    func testARestartDropsEveryFormatListenerBeforeReregistering() {
        engine.apply(desires: [desire()])
        XCTAssertEqual(hal.watchHistory, [["spk"]])
        engine.apply(desires: [desire(position: 40)])
        XCTAssertEqual(hal.watchHistory, [["spk"]], "a gain change does not touch the listeners")
        hal.onServiceRestarted?()
        XCTAssertEqual(hal.watchHistory, [["spk"], [], ["spk"]])
    }

    func testADeviceListChangeReresolvesTheFormatListeners() {
        engine.apply(desires: [desire()])
        hal.plug(TapHALDevice(uid: "dock", name: "Dock", sampleRate: 48000,
                              isStereoOut: true, isAirPlay: false, hasInputStreams: false))
        XCTAssertEqual(hal.watchHistory, [["spk"], ["spk"]],
                       "handed over again, so the HAL re-resolves each UID's object ID")
    }
}

// MARK: - Finding 6, planning

final class AppVolumeTransientPlanTests: XCTestCase {

    private let speakers = TapHALDevice(uid: "spk", name: "Speakers", sampleRate: 48000,
                                        isStereoOut: true, isAirPlay: false, hasInputStreams: false)

    private func plan(_ desire: TapDesire, legs: [TapLegFacts])
        -> (ops: [TapPlanOp], states: [String: TapRowState]) {
        TapReconciler.plan(desires: [desire], legs: legs, tapsEnabled: true, permissionDenied: false,
                           legsOnDevice: { _ in 0 },
                           device: { $0 == "spk" ? self.speakers : nil })
    }

    func testAGainChangeMidSwitchStillApplies() {
        let desire = TapDesire(key: "a", position: 70, isPlaying: true, pids: [1], deviceUIDs: [])
        let result = plan(desire, legs: [TapLegFacts(key: "a", deviceUID: "spk", pids: [1], gain: 0.4)])
        XCTAssertEqual(result.ops, [.setGain(key: "a", gain: 0.7), .disengage(key: "a", afterGrace: true)])
        XCTAssertEqual(result.states["a"], .engaged)
    }

    func testWithNoLegANoDeviceRowIsInertAndBuildsNothing() {
        let desire = TapDesire(key: "a", position: 70, isPlaying: true, pids: [1], deviceUIDs: [])
        let result = plan(desire, legs: [])
        XCTAssertEqual(result.ops, [])
        XCTAssertEqual(result.states["a"], .inert(reason: "no output device"))
    }
}

// MARK: - Finding 11: callbacks are set on the engine queue

final class AppVolumeEngineQueueTests: XCTestCase {

    private final class Box: @unchecked Sendable { var states: [String: TapRowState]? }

    @MainActor
    func testAHandlerSetFromMainIsInPlaceForWorkQueuedAfterIt() {
        let queue = DispatchQueue(label: "com.techie.Astraea.tests.tapengine")
        let hal = FakeTapHAL()
        let engine = TapEngine(hal: hal, queue: queue,
                               schedule: { _, _ in {} }, notify: { $0() })
        let box = Box()
        engine.onStatesChange = { box.states = $0 }
        engine.setTapsEnabled(true, probing: false)
        engine.apply(desires: [TapDesire(key: "a", position: 50, isPlaying: true,
                                         pids: [42], deviceUIDs: ["spk"])])
        queue.sync {}
        XCTAssertEqual(box.states?["a"], .engaged)
        engine.shutdownSync()
    }
}

// MARK: - The render path: findings 2, 3, 13 and 14

final class AppVolumeRenderFixesTests: XCTestCase {

    private let rate = 48000.0

    /// One callback with `streams` as the inputs; returns the output.
    private func callback(_ state: TapRenderState, _ streams: [[Float]]) -> [Float] {
        let count = streams.first?.count ?? 0
        let inputs = AudioBufferList.allocate(maximumBuffers: max(streams.count, 1))
        let outputs = AudioBufferList.allocate(maximumBuffers: 1)
        let out = UnsafeMutablePointer<Float>.allocate(capacity: max(count, 1))
        var owned: [UnsafeMutablePointer<Float>] = []
        defer {
            owned.forEach { $0.deallocate() }
            out.deallocate()
            free(inputs.unsafeMutablePointer)
            free(outputs.unsafeMutablePointer)
        }
        for (index, samples) in streams.enumerated() {
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: samples.count)
            pointer.initialize(from: samples, count: samples.count)
            owned.append(pointer)
            inputs[index] = AudioBuffer(mNumberChannels: 2,
                                        mDataByteSize: UInt32(samples.count * 4), mData: pointer)
        }
        outputs[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(count * 4), mData: out)
        state.render(inputs: inputs, outputs: outputs)
        return Array(UnsafeBufferPointer(start: out, count: count))
    }

    private func tone(frames: Int, amplitude: Float, hz: Double = 440, offset: Int = 0) -> [Float] {
        (0..<frames * 2).map { amplitude * Float(sin(2 * .pi * hz * Double(offset + $0 / 2) / rate)) }
    }

    func testTheIOThreadReportsTheBufferCountItWasHanded() {
        let state = TapRenderState(sampleRate: rate)
        let silence = [Float](repeating: 0, count: 64)
        _ = callback(state, [silence, silence, silence])
        XCTAssertEqual(state.observedBufferCount.pointee, 3)
        _ = callback(state, [silence])
        XCTAssertEqual(state.observedBufferCount.pointee, 1)
    }

    /// The old leg holds its level until the replacement's stream has been
    /// rendered once, then the two ramps cross.
    func testAHandoverHoldsUntilTheReplacementArrives() {
        let state = TapRenderState(sampleRate: rate)
        state.prepareSlot(0, targetGain: 0.5, startGain: 0.5)
        state.setMapping(bufferCount: 1, slots: [0])
        state.prepareSlot(1, targetGain: 0.5, startGain: 0)
        state.holdUntilPresent(0, replacement: 1)
        state.setTarget(0, slot: 0)
        state.setMapping(bufferCount: 2, slots: [0, 1])
        let input = tone(frames: 512, amplitude: 0.5)

        let held = callback(state, [input])                       // the HAL still presents one stream
        XCTAssertEqual(state.current[0], 0.5, "no fade before the new stream is there")
        XCTAssertEqual(held, input.map { $0 * 0.5 })

        for _ in 0..<12 { _ = callback(state, [input, input]) }    // both, for ~130 ms
        XCTAssertEqual(state.current[0], 0)
        XCTAssertEqual(state.current[1], 0.5)
    }

    /// The vDSP ramp is the scalar per-frame ramp it replaced, to float
    /// rounding: the two accumulate the step differently, which over a
    /// 1344-frame ramp drifts by well under 1e-4 (−80 dB).
    func testTheVectorisedRampMatchesTheScalarRamp() {
        for (start, target) in [(Float(1), Float(0.3)), (0.2, 1.0), (0.5, 0.49), (0, 0.5)] {
            let state = TapRenderState(sampleRate: rate)
            state.prepareSlot(0, targetGain: target, startGain: start)
            state.setMapping(bufferCount: 1, slots: [0])
            var gain = start
            for buffer in 0..<6 {
                let input = tone(frames: 384, amplitude: 0.4, offset: buffer * 384)
                let output = callback(state, [input])
                var expected = [Float](repeating: 0, count: input.count)
                for frame in 0..<384 {
                    let delta = target - gain
                    if delta > state.slewPerFrame { gain += state.slewPerFrame }
                    else if delta < -state.slewPerFrame { gain -= state.slewPerFrame }
                    else { gain = target }
                    expected[2 * frame] = input[2 * frame] * gain
                    expected[2 * frame + 1] = input[2 * frame + 1] * gain
                }
                let worst = zip(output, expected).map { abs($0 - $1) }.max() ?? 0
                XCTAssertLessThan(worst, 1e-4, "\(start) → \(target), buffer \(buffer)")
                XCTAssertEqual(state.current[0], gain, accuracy: 1e-4)
            }
            XCTAssertEqual(state.current[0], target, "\(start) → \(target) lands exactly")
        }
    }

    /// Two loud apps at twice their volume: each leg is held at −1 dBFS by
    /// its own limiter, but together they would reach ~1.8. The bus holds
    /// the sum at full scale.
    func testTwoAppsAtTwiceTheirVolumeNeverLeaveFullScale() {
        let state = TapRenderState(sampleRate: rate)
        state.prepareSlot(0, targetGain: 2, startGain: 2)
        state.prepareSlot(1, targetGain: 2, startGain: 2)
        state.setMapping(bufferCount: 2, slots: [0, 1])
        var peak: Float = 0
        var loudest: Float = 0
        for buffer in 0..<40 {
            let input = tone(frames: 512, amplitude: 0.9, offset: buffer * 512)
            let output = callback(state, [input, input])
            peak = max(peak, output.map(abs).max() ?? 0)
            if buffer >= 20 { loudest = max(loudest, output.map(abs).max() ?? 0) }
        }
        XCTAssertLessThanOrEqual(peak, 1, "no sample past full scale, the attack included")
        XCTAssertGreaterThan(loudest, 0.9, "limited, not silenced")
    }

    /// The bus stage only runs while a leg is above unity: at or below it
    /// the sum is untouched, exactly as before.
    func testAtOrBelowUnityTheBusIsUntouched() {
        let state = TapRenderState(sampleRate: rate)
        state.prepareSlot(0, targetGain: 1)
        state.prepareSlot(1, targetGain: 1)
        state.setMapping(bufferCount: 2, slots: [0, 1])
        let input = tone(frames: 512, amplitude: 0.9)
        let output = callback(state, [input, input])
        XCTAssertEqual(output, zip(input, input).map { $0 + $1 })
        XCTAssertEqual(state.busGain.pointee, 1)
    }
}
