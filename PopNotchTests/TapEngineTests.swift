import XCTest
import CoreAudio
@testable import PopNotch

/// Stands in for Core Audio: records every lifecycle call in order and
/// fabricates object IDs. No test here can create a real tap or aggregate
/// (docs/FUTURE-audio-mixer.md, *Carried from the plan*).
final class FakeTapHAL: TapHAL {

    enum Call: Equatable {
        case makeTap(pids: [AudioObjectID])
        case makeProbeTap
        case destroyTap(AudioObjectID)
        case makeAggregate(device: String?, taps: Int)
        case setTapList(uids: Int, aggregate: AudioObjectID)
        case destroyAggregate(AudioObjectID)
        case installIOProc(AudioObjectID)
        case destroyIOProc(AudioObjectID)
        case start(AudioObjectID)
        case stop(AudioObjectID)
    }

    var calls: [Call] = []
    var startStatus: OSStatus = noErr
    /// The probe's start, when it should differ from every other start's.
    var probeStartStatus: OSStatus?
    var tapListEditSucceeds = true
    /// Stands in for the IO thread: when true, every tap-list edit (and a
    /// new aggregate's IOProc) is seen to land at once, as if a callback
    /// had presented the new buffer count. False leaves the count where it
    /// was, as a HAL still lagging the edit would.
    var simulatesIO = true
    /// Starts that fail on one device only (hogged, unplugged mid-engage),
    /// by device UID; the probe and other devices are unaffected.
    var failingStarts: [String: OSStatus] = [:]
    /// Every set `watchDeviceFormats` was handed, in order.
    var watchHistory: [Set<String>] = []
    private var probeAggregates: Set<AudioObjectID> = []
    private var aggregateDevices: [AudioObjectID: String] = [:]
    var devices: [String: TapHALDevice] = [
        "spk": TapHALDevice(uid: "spk", name: "Speakers", sampleRate: 48000,
                            isStereoOut: true, isAirPlay: false, hasInputStreams: false),
        "usb": TapHALDevice(uid: "usb", name: "DAC", sampleRate: 48000,
                            isStereoOut: true, isAirPlay: false, hasInputStreams: false),
    ]
    var processObjects: [pid_t: AudioObjectID] = [42: 900, 43: 901, 44: 902]
    var watchedFormatUIDs: Set<String> = []
    var onServiceRestarted: (() -> Void)?
    var onDeviceFormatChanged: ((String) -> Void)?
    var onDevicesChanged: (() -> Void)?

    private var nextID: AudioObjectID = 100
    /// The tap-list contents per aggregate, for asserting membership edits.
    private(set) var tapLists: [AudioObjectID: [String]] = [:]
    /// Each aggregate's gain table, as the engine handed it to its IOProc.
    private(set) var renders: [AudioObjectID: TapRenderState] = [:]

    /// A device being unplugged, as Core Audio reports it: gone from the
    /// list, then the list-changed notification.
    func unplug(_ uid: String) -> TapHALDevice? {
        let device = devices.removeValue(forKey: uid)
        onDevicesChanged?()
        return device
    }

    func plug(_ device: TapHALDevice) {
        devices[device.uid] = device
        onDevicesChanged?()
    }

    func makeTap(processObjects objects: [AudioObjectID]) -> (tap: AudioObjectID, uid: String)? {
        calls.append(.makeTap(pids: objects))
        nextID += 1
        return (nextID, "uid-\(nextID)")
    }

    func makeProbeTap() -> (tap: AudioObjectID, uid: String)? {
        calls.append(.makeProbeTap)
        nextID += 1
        return (nextID, "probe-\(nextID)")
    }

    func destroyTap(_ tap: AudioObjectID) { calls.append(.destroyTap(tap)) }

    func makeAggregate(outputDeviceUID: String?, tapUIDs: [String]) -> AudioObjectID? {
        calls.append(.makeAggregate(device: outputDeviceUID, taps: tapUIDs.count))
        nextID += 1
        tapLists[nextID] = tapUIDs
        if let outputDeviceUID {
            aggregateDevices[nextID] = outputDeviceUID
        } else {
            probeAggregates.insert(nextID)
        }
        return nextID
    }

    func setTapList(_ uids: [String], onAggregate id: AudioObjectID) -> Bool {
        calls.append(.setTapList(uids: uids.count, aggregate: id))
        guard tapListEditSucceeds else { return false }
        tapLists[id] = uids
        if simulatesIO { renders[id]?.observedBufferCount.pointee = Int32(uids.count) }
        return true
    }

    /// An aggregate's whole teardown, as the engine makes it: the tap list
    /// emptied first (the unmute), then the reverse of creation.
    static func teardown(_ aggregate: AudioObjectID, taps: [AudioObjectID]) -> [Call] {
        [.setTapList(uids: 0, aggregate: aggregate), .stop(aggregate),
         .destroyIOProc(aggregate), .destroyAggregate(aggregate)] + taps.map { .destroyTap($0) }
    }

    /// The IO thread presenting the aggregate's current tap list.
    func deliverCallback(_ id: AudioObjectID) {
        renders[id]?.observedBufferCount.pointee = Int32(tapLists[id]?.count ?? 0)
    }

    func destroyAggregate(_ id: AudioObjectID) {
        calls.append(.destroyAggregate(id))
        tapLists[id] = nil
    }

    func installIOProc(onAggregate id: AudioObjectID, render: TapRenderState) -> AudioDeviceIOProcID? {
        calls.append(.installIOProc(id))
        renders[id] = render
        if simulatesIO { deliverCallback(id) }
        let proc: AudioDeviceIOProc = { _, _, _, _, _, _, _ in noErr }
        return proc
    }

    func destroyIOProc(_ proc: AudioDeviceIOProcID, onAggregate id: AudioObjectID) {
        calls.append(.destroyIOProc(id))
    }

    func start(_ aggregate: AudioObjectID, proc: AudioDeviceIOProcID) -> OSStatus {
        calls.append(.start(aggregate))
        if probeAggregates.contains(aggregate), let probeStartStatus { return probeStartStatus }
        if let uid = aggregateDevices[aggregate], let status = failingStarts[uid] { return status }
        return startStatus
    }

    func stop(_ aggregate: AudioObjectID, proc: AudioDeviceIOProcID) {
        calls.append(.stop(aggregate))
    }

    /// How many process-object lookups the engine made: an engage retried
    /// at pointer rate shows up here even when it fails before any call.
    var processObjectLookups = 0
    func processObject(forPID pid: pid_t) -> AudioObjectID? {
        processObjectLookups += 1
        return processObjects[pid]
    }
    func device(forUID uid: String) -> TapHALDevice? { devices[uid] }
    func outputDevices() -> [TapHALDevice] { devices.values.sorted { $0.name < $1.name } }
    func watchDeviceFormats(uids: Set<String>) {
        watchedFormatUIDs = uids
        watchHistory.append(uids)
    }
}

/// The whole engine lifecycle against the fake: everything runs
/// synchronously (no queue), and delayed work is fired by hand.
@MainActor
final class TapEngineTests: XCTestCase {

    private var hal: FakeTapHAL!
    private var engine: TapEngine!
    /// Scheduled blocks (ramp completions, grace expiries), oldest first.
    private var pending: [(delay: TimeInterval, block: () -> Void)] = []
    private var states: [String: TapRowState] = [:]

    override func setUp() {
        super.setUp()
        hal = FakeTapHAL()
        pending = []
        states = [:]
        engine = TapEngine(hal: hal, queue: nil,
                           schedule: { [weak self] delay, block in
                               self?.pending.append((delay, block))
                               return {}
                           },
                           notify: { block in block() })
        engine.onStatesChange = { [weak self] in self?.states = $0 }
        engine.setTapsEnabled(true, probing: false)
        hal.calls = []
    }

    /// Fires every scheduled block, oldest first, including ones a fired
    /// block schedules.
    private func firePending() {
        while !pending.isEmpty {
            let item = pending.removeFirst()
            item.block()
        }
    }

    private func desire(_ key: String = "com.example.app", position: Int = 50,
                        playing: Bool = true, pids: [pid_t] = [42],
                        devices: [String] = ["spk"]) -> TapDesire {
        TapDesire(key: key, position: position, isPlaying: playing,
                  pids: pids, deviceUIDs: devices)
    }

    // MARK: - Create

    func testEngageBuildsTapAggregateProcStartInThatOrder() {
        engine.apply(desires: [desire()])
        XCTAssertEqual(hal.calls, [
            .makeTap(pids: [900]),
            .makeAggregate(device: "spk", taps: 1),
            .installIOProc(102),
            .start(102),
        ])
        XCTAssertEqual(states["com.example.app"], .engaged)
        XCTAssertEqual(hal.watchedFormatUIDs, ["spk"], "format listener follows the aggregate")
    }

    func testSecondOwnerJoinsByLiveTapListEditNotARebuild() {
        engine.apply(desires: [desire()])
        hal.calls = []
        engine.apply(desires: [desire(), desire("org.other", position: 30, pids: [43])])
        XCTAssertEqual(hal.calls, [
            .makeTap(pids: [901]),
            .setTapList(uids: 2, aggregate: 102),
        ], "a joining owner must never stop, rebuild, or restart the aggregate")
    }

    func testSettingAVolumeOnANonPlayingRowBuildsNothing() {
        engine.apply(desires: [desire(playing: false)])
        XCTAssertEqual(hal.calls, [], "the position is remembered, not built")
        XCTAssertEqual(states["com.example.app"], .notTapped)
    }

    // MARK: - Destroy

    func testUnityTeardownRampsThenRemovesTheLastLegAndAggregate() {
        engine.apply(desires: [desire()])
        hal.calls = []
        engine.apply(desires: [desire(position: 100)])
        XCTAssertEqual(hal.calls, [], "removal waits for the unity ramp")
        firePending()
        XCTAssertEqual(hal.calls, [
            .setTapList(uids: 0, aggregate: 102),
            .stop(102),
            .destroyIOProc(102),
            .destroyAggregate(102),
            .destroyTap(101),
        ], "last leg: the list is emptied first (the unmute), then reverse order of creation")
    }

    func testRemovingOneOwnerKeepsTheSurvivorRunning() {
        engine.apply(desires: [desire(), desire("org.other", position: 30, pids: [43])])
        hal.calls = []
        engine.apply(desires: [desire(position: 100), desire("org.other", position: 30, pids: [43])])
        firePending()
        XCTAssertEqual(hal.calls, [
            .setTapList(uids: 1, aggregate: 102),
            .destroyTap(101),
        ], "the survivor's aggregate is never stopped or rebuilt")
    }

    func testVanishedOwnerIsRemovedWithoutGrace() {
        engine.apply(desires: [desire()])
        hal.calls = []
        engine.apply(desires: [])
        firePending()
        XCTAssertEqual(hal.calls, FakeTapHAL.teardown(102, taps: [101]))
    }

    func testShutdownSyncTearsEverythingDownInOrder() {
        engine.apply(desires: [desire()])
        hal.calls = []
        engine.shutdownSync()
        XCTAssertEqual(hal.calls, FakeTapHAL.teardown(102, taps: [101]))
    }

    func testDisablingTapsDisengagesEverything() {
        engine.apply(desires: [desire()])
        hal.calls = []
        engine.setTapsEnabled(false, probing: false)
        firePending()
        XCTAssertEqual(hal.calls, FakeTapHAL.teardown(102, taps: [101]))
        XCTAssertEqual(states["com.example.app"], .notTapped)
    }

    // MARK: - Grace

    func testStoppedPlayingSurvivesTheGraceThenComesDown() {
        engine.apply(desires: [desire()])
        hal.calls = []
        engine.apply(desires: [desire(playing: false)])
        XCTAssertEqual(hal.calls, [], "the leg outlives a pause by the grace period")
        firePending()  // grace expiry, then the ramp it schedules
        XCTAssertEqual(hal.calls, FakeTapHAL.teardown(102, taps: [101]))
    }

    func testResumeInsideGraceKeepsTheLeg() {
        engine.apply(desires: [desire()])
        hal.calls = []
        engine.apply(desires: [desire(playing: false)])
        engine.apply(desires: [desire(playing: true)])
        firePending()  // the stale grace fires and must re-check
        XCTAssertEqual(hal.calls, [], "a resumed app must not be torn down by a stale grace")
        XCTAssertEqual(states["com.example.app"], .engaged)
    }

    // MARK: - Device move

    func testDeviceMoveEngagesTheNewDeviceBeforeTheOldLegComesDown() {
        engine.apply(desires: [desire()])
        hal.calls = []
        engine.apply(desires: [desire(devices: ["usb"])])
        XCTAssertEqual(Array(hal.calls.prefix(4)), [
            .makeTap(pids: [900]),
            .makeAggregate(device: "usb", taps: 1),
            .installIOProc(104),
            .start(104),
        ], "make before break: the new device's path exists before the old comes down")
        firePending()
        XCTAssertTrue(hal.calls.contains(.destroyAggregate(102)), "the old aggregate is gone")
        XCTAssertTrue(hal.calls.contains(.destroyTap(101)), "and the old tap with it")
        XCTAssertFalse(hal.calls.contains(.destroyAggregate(104)),
                       "the new device's aggregate must survive the move")
        XCTAssertEqual(states["com.example.app"], .engaged,
                       "the moved app stays engaged on the new device")
    }

    // MARK: - Helper restart

    func testPidChangeRebuildsTheLegMakeBeforeBreak() {
        engine.apply(desires: [desire()])
        hal.calls = []
        engine.apply(desires: [desire(pids: [44])])
        XCTAssertEqual(hal.calls, [
            .makeTap(pids: [902]),
            .setTapList(uids: 2, aggregate: 102),
        ], "the new tap joins the running aggregate; the old leg keeps the app muted meanwhile")
        firePending()
        XCTAssertEqual(Array(hal.calls.suffix(2)), [
            .setTapList(uids: 1, aggregate: 102),
            .destroyTap(101),
        ], "only then does the old leg leave, and the aggregate is never folded")
        XCTAssertFalse(hal.calls.contains(.stop(102)))
        XCTAssertEqual(states["com.example.app"], .engaged)
    }

    // MARK: - Permission

    func testProbeRunsTheFullLifecycleAndTearsDown() {
        engine.setTapsEnabled(false, probing: false)
        hal.calls = []
        engine.setTapsEnabled(true, probing: true)
        XCTAssertEqual(hal.calls.first, .makeProbeTap)
        XCTAssertTrue(hal.calls.contains { if case .start = $0 { return true }; return false })
        XCTAssertTrue(hal.calls.contains { if case .destroyAggregate = $0 { return true }; return false })
        XCTAssertTrue(hal.calls.contains { if case .destroyTap = $0 { return true }; return false },
                      "the probe leaves nothing behind")
    }

    /// A start failure alone no longer means denied: the probe decides, and
    /// here it fails too.
    func testStartFailureWithAFailingProbeMarksPermissionDeniedAndCleansUp() {
        hal.startStatus = -50
        engine.apply(desires: [desire()])
        XCTAssertTrue(hal.calls.contains(.destroyAggregate(102)))
        XCTAssertTrue(hal.calls.contains(.destroyTap(101)), "a failed start leaks nothing")
        XCTAssertTrue(hal.calls.contains(.makeProbeTap), "the probe tells denial from a dead device")
        XCTAssertEqual(states["com.example.app"], .inert(reason: "permission needed"))
    }

    func testDeniedProbeLeavesRowsInertUntilTheToggleCycles() {
        engine.setTapsEnabled(false, probing: false)
        hal.startStatus = -50
        engine.setTapsEnabled(true, probing: true)
        engine.apply(desires: [desire()])
        XCTAssertEqual(states["com.example.app"], .inert(reason: "permission needed"))
        XCTAssertFalse(hal.calls.contains(.makeTap(pids: [900])), "denied means no tap attempts")
    }

    // MARK: - External invalidation

    func testServiceRestartDropsStaleObjectsAndRebuilds() {
        engine.apply(desires: [desire()])
        hal.calls = []
        hal.onServiceRestarted?()
        XCTAssertFalse(hal.calls.contains(.stop(102)),
                       "stale IDs are dropped, never destroyed")
        XCTAssertEqual(hal.calls.suffix(4), [
            .makeTap(pids: [900]),
            .makeAggregate(device: "spk", taps: 1),
            .installIOProc(104),
            .start(104),
        ], "the path is rebuilt from desires")
    }

    func testDeviceFormatChangeBuildsTheReplacementBeforeTearingDown() {
        engine.apply(desires: [desire()])
        hal.calls = []
        hal.onDeviceFormatChanged?("spk")
        XCTAssertEqual(hal.calls, [
            .makeTap(pids: [900]),
            .makeAggregate(device: "spk", taps: 1),
            .installIOProc(104),
            .start(104),
        ], "the replacement is running and the old aggregate is still there, so the app stays muted")
        XCTAssertEqual(hal.renders[104]?.current[0], 0.5,
                       "and it opens at the old leg's gain, not at full volume")
        XCTAssertEqual(hal.renders[102]?.targets[0], 0,
                       "the replacement is live (the fake presents it at once): the old leg fades out")
        firePending()
        XCTAssertEqual(Array(hal.calls.suffix(5)), FakeTapHAL.teardown(102, taps: [101]),
                       "and only after the ramp does the old aggregate go")
        XCTAssertEqual(states["com.example.app"], .engaged)
    }

    func testWiggleThroughHundredRevivesTheLegInsteadOfDoublingIt() {
        engine.apply(desires: [desire()])
        engine.apply(desires: [desire(position: 100)])   // ramp-out scheduled
        hal.calls = []
        engine.apply(desires: [desire(position: 40)])    // back below 100 inside the ramp
        XCTAssertEqual(hal.calls, [], "no second tap: the retiring leg is revived in place")
        XCTAssertEqual(states["com.example.app"], .engaged)
        firePending()
        XCTAssertEqual(hal.calls, [], "the cancelled retire must not remove the revived leg")
    }

    func testSecondPauseGetsItsOwnFullGrace() {
        engine.apply(desires: [desire()])
        engine.apply(desires: [desire(playing: false)])  // grace 1 armed
        engine.apply(desires: [desire(playing: true)])   // resume cancels it
        XCTAssertEqual(pending.count, 1, "the stale timer still exists in the scheduler")
        engine.apply(desires: [desire(playing: false)])  // pause again
        XCTAssertEqual(pending.count, 2, "the second pause must arm a fresh grace, not inherit the first")
    }

    // MARK: - The realtime tables

    func testMappingIsKeyedByBufferCountAndUnmappedStreamsStayUnity() {
        let render = TapRenderState(sampleRate: 48000)
        render.setMapping(bufferCount: 2, slots: [1, 0])
        XCTAssertEqual(render.mapping[2 * TapRenderState.maxLegs + 0], 1)
        XCTAssertEqual(render.mapping[2 * TapRenderState.maxLegs + 1], 0)
        XCTAssertEqual(render.mapping[1 * TapRenderState.maxLegs + 0], -1,
                       "an unpublished count keeps every stream unmapped (unity)")
    }

    func testPreparedSlotStartsAtUnityAndTargetsTheGain() {
        let render = TapRenderState(sampleRate: 48000)
        render.prepareSlot(2, targetGain: 0.3)
        XCTAssertEqual(render.current[2], 1, "engage ramps from unity, level-matched")
        XCTAssertEqual(render.targets[2], 0.3, accuracy: 0.0001)
    }
}
