import Accelerate
import CoreAudio
import AudioToolbox
import Foundation
import os

/// The gain state one aggregate's IOProc reads, preallocated so the realtime
/// thread never allocates, and shaped so it never locks either.
///
/// **Threading.** The engine queue writes `targets` and `mapping`; the IO
/// thread reads them and owns `current` exclusively after init. All shared
/// values are aligned 4-byte words. This project is arm64-only by decision
/// (`ARCHS = arm64`, no Intel Mac has a notch), and ARMv8 guarantees
/// single-copy atomicity for aligned word loads and stores, so a plain read
/// on the IO thread sees a whole value, never a torn one. Ordering is
/// handled structurally, not with barriers: a mapping row is written
/// *before* the HAL call that creates the topology it describes, and the IO
/// thread selects the row by the buffer count the HAL actually presents —
/// measured in the spike (M1, 2026-09-18): stream indices shift on a
/// tap-list edit, so the count is the only safe key. The IO thread writes
/// that count back (`observedBufferCount`), and the engine does not rewrite
/// a row the HAL may still be presenting until it has seen the last edit
/// land.
nonisolated final class TapRenderState {

    static let maxLegs = 8
    /// Samples the bass stage filters per pass. Any buffer size works: a
    /// larger buffer is filtered in chunks of this, so scratch never has to
    /// be sized to the device. Even, so a chunk is whole stereo frames.
    static let chunkSamples = 2048
    /// Direct-form-I history per channel for one biquad section: x[n−1],
    /// x[n−2], y[n−1], y[n−2] (`vDSP_biquad`'s 2·M + 2 for M = 1).
    static let delayPerChannel = 4
    static let channelsFiltered = 2
    /// The limiter's lookahead ceiling in frames: 1 ms at 192 kHz, so the
    /// per-slot delay lines are sized once for any rate.
    static let maxLookahead = 192
    /// The level a slot runs at when its volume is above the app's own and
    /// it has no bass boost: no shelf, but the limiter, since it is the gain
    /// that can now leave full scale. Outside `BassBoost.levels`, so the
    /// shelf stage passes it through untouched. Never engine-written.
    static let flatLevel = 4

    /// Per-slot target gain, engine-written.
    let targets: UnsafeMutablePointer<Float>
    /// Per-slot ramp position, IO-thread-private after `prepareSlot`.
    let current: UnsafeMutablePointer<Float>
    /// `mapping[bufferCount * maxLegs + streamIndex]` = slot, or -1 for a
    /// stream the engine has not mapped, which renders at unity.
    let mapping: UnsafeMutablePointer<Int32>
    /// Per-frame gain step: full scale in ~40 ms at the aggregate's rate.
    let slewPerFrame: Float

    // MARK: Bass boost (V2 Phase 3)
    //
    // Engine-written, like `targets`: the level each slot should play at,
    // and a generation bumped whenever the slot changes hands. Everything
    // else below is IO-thread-private. The IO thread never trusts filter
    // history across a generation: a slot's history belongs to one leg, and
    // a stale filter carried into the next app would ring that app's bass
    // with the previous app's audio.

    /// Per-slot bass level, 0 (off) ... 3. Engine-written.
    let bassLevels: UnsafeMutablePointer<Int32>
    /// Per-slot generation, bumped by `prepareSlot` and `releaseSlot`.
    /// Engine-written.
    let generations: UnsafeMutablePointer<Int32>
    /// The generation the IO thread last reset each slot's filter for.
    let seenGenerations: UnsafeMutablePointer<Int32>
    /// The level each slot's filter is actually running at: a bass level,
    /// or `flatLevel` for a slot above unity with no boost. Differs from
    /// the level wanted for exactly one callback after a change: that
    /// callback crossfades from the old curve to the new one.
    let appliedLevels: UnsafeMutablePointer<Int32>
    /// `maxLegs × channelsFiltered × delayPerChannel` floats: every slot's
    /// own history for each channel.
    let delays: UnsafeMutablePointer<Float>
    /// History for the outgoing curve during a level-to-level crossfade,
    /// which runs both curves over the same buffer.
    let crossfadeDelay: UnsafeMutablePointer<Float>
    /// Four chunk-sized buffers: the outgoing curve's output, the incoming
    /// curve's output, the crossfaded sum, and the input with its volume
    /// applied. Shared by every slot — the callback processes streams one
    /// at a time.
    let scratch: UnsafeMutablePointer<Float>
    /// Index 1...3: one `vDSP_biquad_Setup` per level at this aggregate's
    /// sample rate. Built here, off the realtime thread (creating one
    /// allocates); nil if Accelerate refused, and that level then plays dry.
    let setups: UnsafeMutablePointer<vDSP_biquad_Setup?>

    // The limiter after the shelf (`BassBoost.Limiter`), IO-thread-private
    // and reset with the filter: a slot's gain, hold and delayed audio
    // belong to one leg.

    /// Lookahead in frames at this aggregate's rate; also the gain's block.
    let limiterLookahead: Int
    let limiterHoldFrames: Int
    /// The release time constant in frames.
    let limiterReleaseFrames: Float
    /// Per-slot gain at the end of the last block rendered, 1 when idle.
    let limiterGains: UnsafeMutablePointer<Float>
    /// Per-slot frames of hold left before the gain may recover.
    let limiterHolds: UnsafeMutablePointer<Int32>
    /// `maxLegs × channelsFiltered × maxLookahead` floats: each slot's
    /// delayed audio, interleaved, each channel in its own lane.
    let limiterDelays: UnsafeMutablePointer<Float>
    /// The delay line followed by one chunk: the limiter's working span.
    let limiterScratch: UnsafeMutablePointer<Float>
    /// `exp(-limiterLookahead / limiterReleaseFrames)`: the release step for
    /// a whole block, which is nearly every block. Computed once here with
    /// the same expression the IO thread would otherwise evaluate per block.
    let limiterReleaseStep: Float

    // MARK: Topology observation and handover

    /// The buffer count the IO thread presented on its last callback,
    /// IO-written. The engine reads it to learn that a tap-list edit has
    /// landed before it rewrites a mapping row the HAL may still be
    /// presenting (a live edit's topology lags the call by up to ~1 s, M1).
    let observedBufferCount: UnsafeMutablePointer<Int32>
    /// Per slot, engine-written: -1, or the slot of the leg replacing this
    /// one in the same aggregate. While set, this slot's ramp toward its
    /// target waits until the replacement's stream has been rendered once,
    /// so a make-before-break rebuild crossfades instead of dipping while
    /// the new stream is still on its way (~53 ms after the edit, measured).
    let handoverSlots: UnsafeMutablePointer<Int32>
    /// The replacement slot's generation when the handover was set: the
    /// replacement counts as present once `seenGenerations` reaches it.
    let handoverGenerations: UnsafeMutablePointer<Int32>

    // MARK: Output bus limiter

    /// The bus gain at the end of the last callback, IO-thread-private. 1
    /// unless the summed legs left full scale while one was above unity.
    let busGain: UnsafeMutablePointer<Float>
    /// Frames of hold left before the bus gain may recover.
    let busHold: UnsafeMutablePointer<Int32>
    let busHoldFrames: Int
    let busReleaseFrames: Float

    init(sampleRate: Double) {
        slewPerFrame = Float(1.0 / (0.040 * max(sampleRate, 8000)))
        targets = .allocate(capacity: Self.maxLegs)
        current = .allocate(capacity: Self.maxLegs)
        mapping = .allocate(capacity: (Self.maxLegs + 1) * Self.maxLegs)
        targets.initialize(repeating: 1, count: Self.maxLegs)
        current.initialize(repeating: 1, count: Self.maxLegs)
        mapping.initialize(repeating: -1, count: (Self.maxLegs + 1) * Self.maxLegs)

        let delayCount = Self.maxLegs * Self.channelsFiltered * Self.delayPerChannel
        bassLevels = .allocate(capacity: Self.maxLegs)
        generations = .allocate(capacity: Self.maxLegs)
        seenGenerations = .allocate(capacity: Self.maxLegs)
        appliedLevels = .allocate(capacity: Self.maxLegs)
        delays = .allocate(capacity: delayCount)
        crossfadeDelay = .allocate(capacity: Self.channelsFiltered * Self.delayPerChannel)
        scratch = .allocate(capacity: 4 * Self.chunkSamples)
        setups = .allocate(capacity: BassBoost.levels.upperBound + 1)
        bassLevels.initialize(repeating: 0, count: Self.maxLegs)
        generations.initialize(repeating: 0, count: Self.maxLegs)
        seenGenerations.initialize(repeating: 0, count: Self.maxLegs)
        appliedLevels.initialize(repeating: 0, count: Self.maxLegs)
        delays.initialize(repeating: 0, count: delayCount)
        crossfadeDelay.initialize(repeating: 0, count: Self.channelsFiltered * Self.delayPerChannel)
        scratch.initialize(repeating: 0, count: 4 * Self.chunkSamples)
        setups.initialize(repeating: nil, count: BassBoost.levels.upperBound + 1)

        let rate = max(sampleRate, 8000)
        let lineCount = Self.maxLegs * Self.channelsFiltered * Self.maxLookahead
        let scratchCount = Self.chunkSamples + Self.channelsFiltered * Self.maxLookahead
        limiterLookahead = max(1, min(Self.maxLookahead,
                                      Int((BassBoost.Limiter.lookaheadSeconds * rate).rounded())))
        limiterHoldFrames = Int((BassBoost.Limiter.holdSeconds * rate).rounded())
        limiterReleaseFrames = Float(BassBoost.Limiter.releaseSeconds * rate)
        limiterGains = .allocate(capacity: Self.maxLegs)
        limiterHolds = .allocate(capacity: Self.maxLegs)
        limiterDelays = .allocate(capacity: lineCount)
        limiterScratch = .allocate(capacity: scratchCount)
        limiterGains.initialize(repeating: 1, count: Self.maxLegs)
        limiterHolds.initialize(repeating: 0, count: Self.maxLegs)
        limiterDelays.initialize(repeating: 0, count: lineCount)
        limiterScratch.initialize(repeating: 0, count: scratchCount)
        limiterReleaseStep = exp(-Float(limiterLookahead) / limiterReleaseFrames)

        observedBufferCount = .allocate(capacity: 1)
        observedBufferCount.initialize(to: 0)
        handoverSlots = .allocate(capacity: Self.maxLegs)
        handoverGenerations = .allocate(capacity: Self.maxLegs)
        handoverSlots.initialize(repeating: -1, count: Self.maxLegs)
        handoverGenerations.initialize(repeating: 0, count: Self.maxLegs)
        busGain = .allocate(capacity: 1)
        busGain.initialize(to: 1)
        busHold = .allocate(capacity: 1)
        busHold.initialize(to: 0)
        busHoldFrames = Int((BassBoost.Limiter.holdSeconds * rate).rounded())
        busReleaseFrames = Float(BassBoost.Limiter.releaseSeconds * rate)

        for level in BassBoost.levels {
            let coefficients = BassBoost.coefficients(level: level, sampleRate: sampleRate)
            setups[level] = vDSP_biquad_CreateSetup(coefficients, 1)
        }
    }

    deinit {
        targets.deallocate()
        current.deallocate()
        mapping.deallocate()
        for level in BassBoost.levels {
            if let setup = setups[level] { vDSP_biquad_DestroySetup(setup) }
        }
        setups.deallocate()
        bassLevels.deallocate()
        generations.deallocate()
        seenGenerations.deallocate()
        appliedLevels.deallocate()
        delays.deallocate()
        crossfadeDelay.deallocate()
        scratch.deallocate()
        limiterGains.deallocate()
        limiterHolds.deallocate()
        limiterDelays.deallocate()
        limiterScratch.deallocate()
        observedBufferCount.deallocate()
        handoverSlots.deallocate()
        handoverGenerations.deallocate()
        busGain.deallocate()
        busHold.deallocate()
    }

    /// Engine side, before a slot can be mapped. The ramp starts at
    /// `startGain`: unity for a first engage, so the app is level-matched
    /// to the original it just replaced; the retiring leg's gain when this
    /// leg replaces one on another aggregate (a move, a format rebuild), so
    /// the new path does not open at full volume; 0 for a rebuild's
    /// crossfade. The slot's filter starts from silence at its first
    /// callback — the generation bump is last, so the IO thread sees the new
    /// level with it. The limiter is reset with the filter, on the same
    /// generation.
    func prepareSlot(_ slot: Int, targetGain: Float, startGain: Float = 1, bass: Int = 0) {
        guard slot >= 0, slot < Self.maxLegs else { return }
        current[slot] = startGain
        targets[slot] = targetGain
        handoverSlots[slot] = -1
        bassLevels[slot] = Int32(BassBoost.levels.contains(bass) ? bass : 0)
        generations[slot] &+= 1
    }

    /// Engine side: `slot`'s ramp waits until `replacement`'s stream has
    /// been rendered once (see `handoverSlots`). Set after the replacement
    /// is prepared and before this slot's target changes. Every way the IO
    /// thread can see these two words out of order only shortens the wait.
    func holdUntilPresent(_ slot: Int, replacement: Int) {
        guard slot >= 0, slot < Self.maxLegs,
              replacement >= 0, replacement < Self.maxLegs else { return }
        handoverGenerations[slot] = generations[replacement]
        handoverSlots[slot] = Int32(replacement)
    }

    func clearHandover(_ slot: Int) {
        guard slot >= 0, slot < Self.maxLegs else { return }
        handoverSlots[slot] = -1
    }

    func setTarget(_ gain: Float, slot: Int) {
        guard slot >= 0, slot < Self.maxLegs else { return }
        targets[slot] = gain
    }

    /// Engine side: the slot's boost level. The IO thread crossfades to it
    /// over one callback, so a change never clicks.
    func setBass(_ level: Int, slot: Int) {
        guard slot >= 0, slot < Self.maxLegs else { return }
        bassLevels[slot] = Int32(BassBoost.levels.contains(level) ? level : 0)
    }

    /// Engine side, when a leg leaves the slot: whatever the next callback
    /// still reads from it (a straggler mapping the old layout) starts from
    /// clean history, and nothing of this leg survives into the next one.
    func releaseSlot(_ slot: Int) {
        guard slot >= 0, slot < Self.maxLegs else { return }
        bassLevels[slot] = 0
        handoverSlots[slot] = -1
        generations[slot] &+= 1
    }

    /// Engine side: publish which slot each stream feeds when the callback
    /// presents `bufferCount` buffers. Written before the topology edit that
    /// makes that count real.
    func setMapping(bufferCount: Int, slots: [Int32]) {
        guard bufferCount >= 0, bufferCount <= Self.maxLegs else { return }
        for stream in 0..<Self.maxLegs {
            mapping[bufferCount * Self.maxLegs + stream] =
                stream < slots.count ? slots[stream] : -1
        }
    }
}

/// One output device, as the engine needs it for qualification.
struct TapHALDevice: Equatable {
    var uid: String
    var name: String
    var sampleRate: Double
    /// True only for a single interleaved 2-channel output stream — the one
    /// layout the IOProc writes. Stereo split across streams is excluded.
    var isStereoOut: Bool
    var isAirPlay: Bool
    /// The device also carries input streams (a headset's microphone). An
    /// aggregate exposes its sub-devices' input streams to the IOProc
    /// alongside the tap streams, which would corrupt the buffer-count
    /// mapping key and pass the microphone into its own output at unity.
    /// Unmeasured territory, so v1 excludes such devices (caught in the
    /// Phase 5 code review, 2026-09-19).
    var hasInputStreams: Bool
}

/// Everything the tap engine asks of Core Audio, behind a seam so tests run
/// the entire lifecycle against a fake. No test creates a real tap or
/// aggregate (docs/FUTURE-audio-mixer.md, *Carried from the plan*).
///
/// Called only on the engine's serial queue.
protocol TapHAL: AnyObject {
    /// A `.mutedWhenTapped` private tap on these process objects.
    func makeTap(processObjects: [AudioObjectID]) -> (tap: AudioObjectID, uid: String)?
    /// An `.unmuted` global tap: the permission probe (decision 3 — the
    /// audio-recording prompt belongs to the toggle, not to first playback).
    func makeProbeTap() -> (tap: AudioObjectID, uid: String)?
    func destroyTap(_ tap: AudioObjectID)

    /// A private aggregate over `tapUIDs`, rendering to `outputDeviceUID`
    /// (nil for the probe's tap-only aggregate).
    func makeAggregate(outputDeviceUID: String?, tapUIDs: [String]) -> AudioObjectID?
    /// Live tap-list edit; measured to work in both directions (M1).
    func setTapList(_ uids: [String], onAggregate: AudioObjectID) -> Bool
    func destroyAggregate(_ id: AudioObjectID)

    /// Installs the canonical gain-and-mix IOProc reading `render`.
    func installIOProc(onAggregate: AudioObjectID, render: TapRenderState) -> AudioDeviceIOProcID?
    func destroyIOProc(_ proc: AudioDeviceIOProcID, onAggregate: AudioObjectID)
    /// Blocks during the permission prompt; that is why the engine queue,
    /// never main, calls it.
    func start(_ aggregate: AudioObjectID, proc: AudioDeviceIOProcID) -> OSStatus
    func stop(_ aggregate: AudioObjectID, proc: AudioDeviceIOProcID)

    func processObject(forPID pid: pid_t) -> AudioObjectID?
    func device(forUID uid: String) -> TapHALDevice?
    /// Every device with output streams that a user could route an app to,
    /// sorted by name. This process's own private aggregates (the engine's
    /// and the visualiser's) are left out: they are visible only to us, and
    /// they are the machinery, not a destination.
    func outputDevices() -> [TapHALDevice]

    /// coreaudiod restarted: every object this engine holds is invalid.
    var onServiceRestarted: (() -> Void)? { get set }
    /// The system's device list changed: something was plugged in or
    /// unplugged — or one of our own aggregates came or went, which the
    /// engine filters out by comparing `outputDevices()`.
    var onDevicesChanged: (() -> Void)? { get set }
    /// The named device's nominal rate or stream layout changed — output
    /// streams, or input streams appearing or going.
    var onDeviceFormatChanged: ((String) -> Void)? { get set }
    /// Registers format listeners for exactly these device UIDs (the ones
    /// with a live aggregate), dropping listeners for any other.
    func watchDeviceFormats(uids: Set<String>)
}

/// The real Core Audio implementation.
nonisolated final class CoreAudioTapHAL: TapHAL {

    private static let logger = Logger(subsystem: "com.techie.Astraea", category: "TapHAL")

    // The handlers are read by listener blocks, which Core Audio runs on
    // `listenerQueue`, and written by the engine (its init, on whatever
    // thread built it). Both sides go through `listenerQueue`, so neither
    // reads a half-written closure.
    var onServiceRestarted: (() -> Void)? {
        get { listenerQueue.sync { restartHandler } }
        set { listenerQueue.sync { restartHandler = newValue } }
    }
    var onDeviceFormatChanged: ((String) -> Void)? {
        get { listenerQueue.sync { formatHandler } }
        set { listenerQueue.sync { formatHandler = newValue } }
    }
    var onDevicesChanged: (() -> Void)? {
        get { listenerQueue.sync { devicesHandler } }
        set { listenerQueue.sync { devicesHandler = newValue } }
    }
    /// `listenerQueue`-confined.
    private var restartHandler: (() -> Void)?
    private var formatHandler: ((String) -> Void)?
    private var devicesHandler: (() -> Void)?

    private var restartListener: AudioObjectPropertyListenerBlock?
    private var devicesListener: AudioObjectPropertyListenerBlock?
    /// Engine-queue-confined: only `watchDeviceFormats` touches it, and the
    /// engine calls that on its own serial queue.
    private var formatListeners: [String: (device: AudioObjectID, block: AudioObjectPropertyListenerBlock)] = [:]
    /// The queue Core Audio delivers this HAL's listener blocks on, and the
    /// one the handlers above live on. It does not serialize anything with
    /// the engine queue; the handlers hop there themselves.
    private let listenerQueue = DispatchQueue(label: "com.techie.Astraea.taphal.listeners")

    /// What a format listener watches: the nominal rate, the output stream
    /// layout, and the input stream layout — an input stream appearing at
    /// runtime would ride into the aggregate and break the count-keyed
    /// mapping, which the plan-time `hasInputStreams` gate cannot see.
    private static let formatAddresses: [AudioObjectPropertyAddress] = [
        address(kAudioDevicePropertyNominalSampleRate),
        address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeOutput),
        address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput),
    ]

    init() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var addr = Self.address(kAudioHardwarePropertyServiceRestarted)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Self.logger.notice("coreaudiod restarted; every tap object is invalid")
            self?.restartHandler?()
        }
        if AudioObjectAddPropertyListenerBlock(system, &addr, listenerQueue, block) == noErr {
            restartListener = block
        } else {
            Self.logger.error("Could not watch for coreaudiod restarts")
        }
        // Push-only, like the restart listener: a routed device being
        // unplugged, or coming back, is what makes the engine re-resolve
        // routes. No timer (hard rule 9); nothing to suspend.
        var devicesAddr = Self.address(kAudioHardwarePropertyDevices)
        let devicesBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.devicesHandler?()
        }
        if AudioObjectAddPropertyListenerBlock(system, &devicesAddr, listenerQueue, devicesBlock) == noErr {
            devicesListener = devicesBlock
        } else {
            Self.logger.error("Could not watch the device list; routes will not follow unplugs")
        }
    }

    func makeTap(processObjects: [AudioObjectID]) -> (tap: AudioObjectID, uid: String)? {
        let description = CATapDescription(stereoMixdownOfProcesses: processObjects)
        description.uuid = UUID()
        description.name = "Astraea Volume"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        var tapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else {
            Self.logger.error("Create tap failed (\(status, privacy: .public))")
            return nil
        }
        return (tapID, description.uuid.uuidString)
    }

    func makeProbeTap() -> (tap: AudioObjectID, uid: String)? {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.name = "Astraea Volume Probe"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var tapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else {
            Self.logger.error("Create probe tap failed (\(status, privacy: .public))")
            return nil
        }
        return (tapID, description.uuid.uuidString)
    }

    func destroyTap(_ tap: AudioObjectID) {
        let status = AudioHardwareDestroyProcessTap(tap)
        if status != noErr {
            Self.logger.error("Destroy tap \(tap, privacy: .public) failed (\(status, privacy: .public))")
        }
    }

    func makeAggregate(outputDeviceUID: String?, tapUIDs: [String]) -> AudioObjectID? {
        var dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Astraea Volume",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: tapUIDs.map {
                [kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: $0]
            },
        ]
        if let outputDeviceUID {
            dict[kAudioAggregateDeviceMainSubDeviceKey] = outputDeviceUID
            dict[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: outputDeviceUID]]
        } else {
            dict[kAudioAggregateDeviceSubDeviceListKey] = [] as [[String: Any]]
        }
        var aggID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(dict as CFDictionary, &aggID)
        guard status == noErr else {
            Self.logger.error("Create aggregate failed (\(status, privacy: .public))")
            return nil
        }
        return aggID
    }

    func setTapList(_ uids: [String], onAggregate id: AudioObjectID) -> Bool {
        var addr = Self.address(kAudioAggregateDevicePropertyTapList)
        var value = uids as CFArray
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectSetPropertyData(id, &addr, 0, nil,
                                       UInt32(MemoryLayout<CFArray>.size), $0)
        }
        if status != noErr {
            Self.logger.error("Live tap-list edit failed (\(status, privacy: .public))")
        }
        return status == noErr
    }

    func destroyAggregate(_ id: AudioObjectID) {
        let status = AudioHardwareDestroyAggregateDevice(id)
        if status != noErr {
            Self.logger.error("Destroy aggregate \(id, privacy: .public) failed (\(status, privacy: .public))")
        }
    }

    func installIOProc(onAggregate id: AudioObjectID, render: TapRenderState) -> AudioDeviceIOProcID? {
        var procID: AudioDeviceIOProcID?
        // The realtime path: no allocation, no locks, no ObjC, and `render`
        // is captured strongly once here, so no retain traffic per callback.
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, id, nil) {
            _, inputData, _, outputData, _ in
            render.render(
                inputs: UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData)),
                outputs: UnsafeMutableAudioBufferListPointer(outputData))
        }
        guard status == noErr, let procID else {
            Self.logger.error("Create IOProc failed (\(status, privacy: .public))")
            return nil
        }
        return procID
    }

    func destroyIOProc(_ proc: AudioDeviceIOProcID, onAggregate id: AudioObjectID) {
        let status = AudioDeviceDestroyIOProcID(id, proc)
        if status != noErr {
            Self.logger.error("Destroy IOProc on \(id, privacy: .public) failed (\(status, privacy: .public))")
        }
    }

    func start(_ aggregate: AudioObjectID, proc: AudioDeviceIOProcID) -> OSStatus {
        AudioDeviceStart(aggregate, proc)
    }

    func stop(_ aggregate: AudioObjectID, proc: AudioDeviceIOProcID) {
        let status = AudioDeviceStop(aggregate, proc)
        if status != noErr {
            Self.logger.error("Stop on \(aggregate, privacy: .public) failed (\(status, privacy: .public))")
        }
    }

    func processObject(forPID pid: pid_t) -> AudioObjectID? {
        var addr = Self.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var qualifier = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                                UInt32(MemoryLayout<pid_t>.size), &qualifier,
                                                &size, &object)
        guard status == noErr, object != kAudioObjectUnknown else { return nil }
        return object
    }

    func device(forUID uid: String) -> TapHALDevice? {
        let ids = Self.allDeviceIDs()
        for id in ids where Self.string(id, kAudioDevicePropertyDeviceUID) == uid {
            return Self.describe(id, uid: uid)
        }
        return nil
    }

    func outputDevices() -> [TapHALDevice] {
        Self.allDeviceIDs()
            .compactMap { id -> TapHALDevice? in
                guard Self.streamLayout(id, scope: kAudioObjectPropertyScopeOutput).streams > 0,
                      (Self.scalar(id, kAudioDevicePropertyIsHidden, as: UInt32.self) ?? 0) == 0,
                      !Self.isOwnPrivateAggregate(id),
                      let uid = Self.string(id, kAudioDevicePropertyDeviceUID) else { return nil }
                return Self.describe(id, uid: uid)
            }
            .sorted { ($0.name.localizedLowercase, $0.uid) < ($1.name.localizedLowercase, $1.uid) }
    }

    private static func describe(_ id: AudioObjectID, uid: String) -> TapHALDevice {
        let transport = scalar(id, kAudioDevicePropertyTransportType, as: UInt32.self) ?? 0
        let out = streamLayout(id, scope: kAudioObjectPropertyScopeOutput)
        let input = streamLayout(id, scope: kAudioObjectPropertyScopeInput)
        return TapHALDevice(
            uid: uid,
            name: string(id, kAudioObjectPropertyName) ?? uid,
            sampleRate: scalar(id, kAudioDevicePropertyNominalSampleRate, as: Float64.self) ?? 48000,
            isStereoOut: out.streams == 1 && out.channels == 2,
            isAirPlay: transport == kAudioDeviceTransportTypeAirPlay,
            hasInputStreams: input.streams > 0)
    }

    /// A private aggregate is visible only to the process that made it, so
    /// any we can see is ours. The composition's private flag is the
    /// principled test; the name prefix covers an aggregate whose
    /// composition cannot be read.
    private static func isOwnPrivateAggregate(_ id: AudioObjectID) -> Bool {
        guard scalar(id, kAudioDevicePropertyTransportType, as: UInt32.self)
                == kAudioDeviceTransportTypeAggregate else { return false }
        if let composition = dictionary(id, kAudioAggregateDevicePropertyComposition),
           let isPrivate = composition[kAudioAggregateDeviceIsPrivateKey] as? NSNumber,
           isPrivate.boolValue {
            return true
        }
        // "PopNotch " is the pre-rebrand name: a crashed old version can leave
        // such an aggregate behind.
        guard let name = string(id, kAudioObjectPropertyName) else { return false }
        return name.hasPrefix("Astraea ") || name.hasPrefix("PopNotch ")
    }

    /// Re-resolves each UID's object ID on every call, so a listener left on
    /// an ID that a renumbering retired moves to the live one. The engine
    /// calls this only when its aggregate set changes or after an event that
    /// can renumber devices, never per reconcile; after a coreaudiod restart
    /// it first calls it with the empty set, because a restarted daemon may
    /// hand out the same numbers while every registration on them is gone.
    func watchDeviceFormats(uids: Set<String>) {
        let ids = uids.isEmpty ? [] : Self.allDeviceIDs()
        var resolved: [String: AudioObjectID] = [:]
        for uid in uids {
            if let id = ids.first(where: { Self.string($0, kAudioDevicePropertyDeviceUID) == uid }) {
                resolved[uid] = id
            }
        }
        for (uid, listener) in formatListeners where resolved[uid] != listener.device {
            // A dead object refuses the removal; that is expected after a
            // restart or an unplug, so it is not an error worth logging.
            for address in Self.formatAddresses {
                var address = address
                AudioObjectRemovePropertyListenerBlock(listener.device, &address, listenerQueue, listener.block)
            }
            formatListeners[uid] = nil
        }
        for (uid, id) in resolved where formatListeners[uid] == nil {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.formatHandler?(uid)
            }
            var added = 0
            for address in Self.formatAddresses {
                var address = address
                if AudioObjectAddPropertyListenerBlock(id, &address, listenerQueue, block) == noErr {
                    added += 1
                }
            }
            if added > 0 {
                formatListeners[uid] = (id, block)
            } else {
                Self.logger.error("Could not watch device format for \(uid, privacy: .public)")
            }
        }
    }

    // MARK: - Property plumbing

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func allDeviceIDs() -> [AudioObjectID] {
        var addr = address(kAudioHardwarePropertyDevices)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0
        else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func streamLayout(_ id: AudioObjectID,
                                     scope: AudioObjectPropertyScope) -> (streams: Int, channels: Int) {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0
        else { return (0, 0) }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return (0, 0) }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return (list.count, list.reduce(0) { $0 + Int($1.mNumberChannels) })
    }

    private static func scalar<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                  as type: T.Type) -> T? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, pointer) == noErr
        else { return nil }
        return pointer.pointee
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func dictionary(_ object: AudioObjectID,
                                   _ selector: AudioObjectPropertySelector) -> [String: Any]? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<CFDictionary?>.size)
        var value: Unmanaged<CFDictionary>?
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as? [String: Any]
    }
}
