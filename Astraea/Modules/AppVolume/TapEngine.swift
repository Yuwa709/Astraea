import AppKit
import CoreAudio
import Foundation
import os

/// The Phase 5 tap engine: per-app volume for everything that is not
/// Spotify or Music, via `.mutedWhenTapped` process taps mixed back to the
/// owner's own output device through one shared aggregate per device.
///
/// V2 adds per-app output routing on the same machinery: the aggregate's
/// device is the owner's *chosen* output when one is set and connected
/// (`TapReconciler.target`). `.mutedWhenTapped` still silences the app's own
/// output when the aggregate renders elsewhere (V2 Phase 1, question 1).
/// Owners routed to one device share its aggregate. A routed Spotify or
/// Music reaches the engine at unity; their volume stays AppleScript's.
///
/// V2 Phase 3 adds per-app bass boost in the same render path: a low
/// shelf per leg per channel, then a linked lookahead limiter per leg
/// (`BassBoost`, `TapRender`).
/// A boost is a third reason for a tap, beside turning down and routing, so
/// a boosted Spotify or Music is tapped at unity too.
///
/// **Known and accepted (2026-09-27):** a live tap-list edit on a
/// cross-device aggregate stalls its IOProc for ~616 ms (V2 Phase 1), so an
/// app already routed to a device goes silent for that long whenever
/// another app joins it. Recorded in docs/FUTURE-audio-mixer.md.
///
/// Owned by AppDelegate (v1 plan, decision 4). Every Core Audio call runs on
/// one serial queue, never main — `AudioDeviceStart` blocks while the
/// permission prompt is up (measured 17 s in the spike). The desired state
/// arrives from `AppVolumeService` as `TapDesire` rows; `TapReconciler`
/// (pure) turns desired-versus-actual into ops; this type executes them.
///
/// Lifecycle facts this design leans on, all measured 2026-09-18 (see
/// docs/FUTURE-audio-mixer.md, *Phase 5 pre-build measurements*):
/// - a live aggregate's tap list is editable both ways with IO running,
///   and the mute follows list membership, so same-device topology changes
///   never rebuild the aggregate;
/// - stream indices shift on removal, so per-stream gain mapping is keyed
///   by the callback's buffer count (`TapRenderState`);
/// - with two taps on one process the mute holds until the last one goes,
///   so a device move, a pid-set rebuild and a format rebuild are all
///   make-before-break;
/// - revoking the grant does nothing to a live tap (TCC checks at start),
///   so there is no runtime watchdog: a failed start runs the probe, and
///   only a failed probe marks the permission denied (the taps toggle is
///   then the recovery lever); a passing one marks just that device.
nonisolated final class TapEngine {

    private static let logger = Logger(subsystem: "com.techie.Astraea", category: "TapEngine")

    /// How long a disengage ramp gets before the leg is removed. The IOProc
    /// slews full scale in ~40 ms; 120 ms covers any start gain with margin.
    private let rampDelay: TimeInterval
    /// The one-shot grace after an owner stops outputting, so a brief pause
    /// does not tear down and rebuild the whole path (carried from the
    /// plan). Cancelled by a resume; the fire re-checks before acting.
    private let graceDelay: TimeInterval
    /// How long a leg being replaced keeps rendering when its replacement
    /// renders somewhere other than the app's own device. Such a path
    /// delivers nothing for 614–667 ms after it starts or joins, and its tap
    /// does not mute the app until it does (V2 Phase 1, question 2 and the
    /// follow-up). Retiring the old leg sooner would unmute the app on its
    /// own device for that half second. 1 s covers the measured worst case
    /// with margin; the cost is up to ~0.35 s of the app on both devices.
    /// A one-shot per move, not a timer.
    private let crossDeviceHandover: TimeInterval
    /// How often a tap-list edit waiting on the previous one to land checks
    /// again, and how long it waits at most. A live edit's topology lags the
    /// call by up to ~1 s (M1); rewriting a mapping row the HAL may still be
    /// presenting would play one app at another's gain. One-shot retries,
    /// bounded by the timeout — not a timer.
    private let observeRetryDelay: TimeInterval
    private let observeTimeout: TimeInterval
    /// How long a failed engage for the same device and pids, or a device
    /// that would not start, is left alone before the next reconcile tries
    /// it again. Without it a slider drag retries the failing HAL calls at
    /// pointer rate.
    private let failureRetryDelay: TimeInterval
    /// Monotonic seconds; injectable so tests move time by hand.
    private let now: () -> TimeInterval

    private let hal: TapHAL
    /// nil under test: calls run synchronously in the caller's context.
    private let queue: DispatchQueue?
    /// Delayed work, injectable so tests fire it deterministically.
    /// Returns a cancel closure.
    private let schedule: (TimeInterval, @escaping () -> Void) -> () -> Void
    /// Delivers `onStatesChange` (main queue in production).
    private let notify: (@escaping () -> Void) -> Void

    // The three callbacks below are set from main and read on the engine
    // queue, so a set hops onto the queue: the queue is the only place the
    // stored handlers are touched. Sets made in order land in order, before
    // any work queued after them (`refreshOutputDevices`, say). The getters
    // read the stored value and are for the engine queue only.

    /// Row states for the page, keyed by owner key. Delivered via `notify`.
    var onStatesChange: (([String: TapRowState]) -> Void)? {
        get { statesHandler }
        set { onQueue { self.statesHandler = newValue } }
    }
    /// Every PID currently in a live tap list — muted at the device and
    /// re-rendered by us. The visualiser excludes exactly these, so its
    /// spectrum shows our correctly-scaled re-render instead of the app's
    /// pre-mute stream (Phase 6). Delivered via `notify`, like the states.
    ///
    /// A leg that is ramping out is still in the list and still muting its
    /// app, so it stays in this set until `remove` takes it out.
    var onTappedProcessesChange: (([pid_t]) -> Void)? {
        get { tappedProcessesHandler }
        set { onQueue { self.tappedProcessesHandler = newValue } }
    }
    /// The devices a mixer row may route to, on `refreshOutputDevices()` and
    /// whenever the list really changes (our own aggregates are not in it).
    /// Delivered via `notify`. The engine is the one watcher of the device
    /// list, so the menu and the routing can never disagree about it.
    var onOutputDevicesChange: (([TapHALDevice]) -> Void)? {
        get { outputDevicesHandler }
        set { onQueue { self.outputDevicesHandler = newValue } }
    }
    private var statesHandler: (([String: TapRowState]) -> Void)?
    private var tappedProcessesHandler: (([pid_t]) -> Void)?
    private var outputDevicesHandler: (([TapHALDevice]) -> Void)?

    // MARK: - Engine-context state (queue-confined in production)

    private final class Leg {
        let key: String
        let deviceUID: String
        let tapID: AudioObjectID
        let tapUID: String
        var pids: [pid_t]
        var gain: Float
        /// Bass boost level, 0 (off) ... 3 (V2 Phase 3).
        var bass: Int
        let slot: Int
        var rampingOut = false
        /// Bumped by every retirement and revival, and carried by the work
        /// each one schedules, so a stale hold, fade or removal from an
        /// earlier retirement does nothing. Cancelling a work item is not
        /// enough on its own: tests schedule synchronously and cannot cancel.
        var retireToken = 0
        var cancelRetire: (() -> Void)?
        var cancelGrace: (() -> Void)?

        init(key: String, deviceUID: String, tapID: AudioObjectID, tapUID: String,
             pids: [pid_t], gain: Float, bass: Int, slot: Int) {
            self.key = key
            self.deviceUID = deviceUID
            self.tapID = tapID
            self.tapUID = tapUID
            self.pids = pids
            self.gain = gain
            self.bass = bass
            self.slot = slot
        }
    }

    private final class Aggregate {
        let deviceUID: String
        let id: AudioObjectID
        let procID: AudioDeviceIOProcID
        let render: TapRenderState
        /// Tap-list order; stream indices follow it.
        var legs: [Leg] = []
        /// Round-robin start for slot assignment, so a just-freed slot is
        /// not immediately reused: a live tap-list edit's topology effect
        /// lags the call (measured ≤1 s), and a straggling callback still
        /// mapping the old layout may write the departed leg's ramp state
        /// into a reused slot. Rotation keeps a freed slot cold for seven
        /// further assignments, far beyond the lag.
        var slotCursor = 0
        /// The buffer count the last tap-list edit asked for.
        var expectedCount = 1
        /// Every buffer count the HAL may be presenting right now: the
        /// count before each edit not yet seen to land, and the count after
        /// it. A mapping row in here must not be rewritten; it collapses to
        /// `expectedCount` once the IO thread reports that count.
        var presentable: Set<Int> = [1]
        /// When an edit first had to wait on the previous one, for the
        /// timeout.
        var deferringSince: TimeInterval?
        var cancelObserveRetry: (() -> Void)?

        init(deviceUID: String, id: AudioObjectID, procID: AudioDeviceIOProcID,
             render: TapRenderState) {
            self.deviceUID = deviceUID
            self.id = id
            self.procID = procID
            self.render = render
        }
    }

    private enum Permission { case unknown, granted, denied }

    /// An engage that failed, remembered so the same attempt is not
    /// repeated until `until` or until the device or pids change.
    private struct EngageFailure {
        let signature: String
        let reason: String?
        let until: TimeInterval
    }
    private var failedEngages: [String: EngageFailure] = [:]
    /// Devices whose aggregate would not start while capture itself works
    /// (the probe passed): hogged, or unplugged mid-engage. By device UID.
    private var failedDevices: [String: (reason: String, until: TimeInterval)] = [:]
    /// Gains of the legs a format rebuild is replacing, by owner key, so
    /// each replacement opens at its predecessor's level. Set and cleared
    /// around one reconcile.
    private var carriedGains: [String: Float] = [:]
    /// The UIDs the HAL last watched formats on; nil forces the next
    /// reconcile to hand the set over again (and so re-resolve the IDs).
    private var watchedFormatUIDs: Set<String>?

    private var aggregates: [String: Aggregate] = [:]
    /// Aggregates a format change replaced, by device UID. Each keeps
    /// rendering its legs — and keeps their apps muted — until its
    /// replacement in `aggregates` is seen live, then fades and folds
    /// (`awaitReplacement`).
    private var replacedAggregates: [String: Aggregate] = [:]
    /// The active leg per owner. A leg mid-retirement (device move, ramp-out)
    /// leaves this map and lives only in its aggregate's `legs` until removed.
    private var activeLegs: [String: Leg] = [:]
    private var desires: [TapDesire] = []
    private var tapsEnabled = false
    private var permission: Permission = .unknown
    private var published: [String: TapRowState] = [:]
    private var publishedTappedPIDs: [pid_t] = []
    /// nil until the first publish, so the first one always goes out.
    private var publishedOutputDevices: [TapHALDevice]?

    init(hal: TapHAL? = nil,
         queue: DispatchQueue? = DispatchQueue(label: "com.techie.Astraea.tapengine"),
         rampDelay: TimeInterval = 0.12,
         graceDelay: TimeInterval = 3.0,
         crossDeviceHandover: TimeInterval = 1.0,
         observeRetryDelay: TimeInterval = 0.05,
         observeTimeout: TimeInterval = 1.5,
         failureRetryDelay: TimeInterval = 2.0,
         now: (() -> TimeInterval)? = nil,
         schedule: ((TimeInterval, @escaping () -> Void) -> () -> Void)? = nil,
         notify: ((@escaping () -> Void) -> Void)? = nil) {
        self.hal = hal ?? CoreAudioTapHAL()
        self.queue = queue
        self.rampDelay = rampDelay
        self.graceDelay = graceDelay
        self.crossDeviceHandover = crossDeviceHandover
        self.observeRetryDelay = observeRetryDelay
        self.observeTimeout = observeTimeout
        self.failureRetryDelay = failureRetryDelay
        self.now = now ?? { ProcessInfo.processInfo.systemUptime }
        if let schedule {
            self.schedule = schedule
        } else if let queue {
            self.schedule = { delay, block in
                let item = DispatchWorkItem(block: block)
                queue.asyncAfter(deadline: .now() + delay, execute: item)
                return { item.cancel() }
            }
        } else {
            self.schedule = { _, block in block(); return {} }
        }
        self.notify = notify ?? { block in DispatchQueue.main.async(execute: block) }

        self.hal.onServiceRestarted = { [weak self] in
            self?.onQueue { self?.handleServiceRestarted() }
        }
        self.hal.onDeviceFormatChanged = { [weak self] uid in
            self?.onQueue { self?.handleFormatChanged(uid) }
        }
        self.hal.onDevicesChanged = { [weak self] in
            self?.onQueue { self?.handleDevicesChanged() }
        }
        if queue != nil {
            // One reconcile on wake: rebuild whatever died or moved while
            // asleep. willSleep needs nothing — a tap is the playing app's
            // audio path and the HAL quiesces IO itself.
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
            ) { [weak self] _ in
                Self.logger.notice("Woke; reconciling taps")
                self?.onQueue { self?.reconcile() }
            }
        }
    }

    /// Held so the observation is removable; AppDelegate owns the one
    /// engine for the process lifetime, but the token must not be dropped.
    private var wakeObserver: NSObjectProtocol?

    deinit {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    private func onQueue(_ block: @escaping () -> Void) {
        if let queue { queue.async(execute: block) } else { block() }
    }

    // MARK: - API (any thread; work hops to the engine queue)

    func apply(desires: [TapDesire]) {
        onQueue {
            self.desires = desires
            self.reconcile()
        }
    }

    /// Publishes the current output devices through `onOutputDevicesChange`.
    /// Called once at launch; after that the device-list listener drives it.
    func refreshOutputDevices() {
        onQueue { self.publishOutputDevices() }
    }

    /// Decision 3: the audio-recording prompt belongs to the moment the user
    /// turns taps on, so the Settings toggle passes `probing: true` and runs
    /// the probe start right here. Launch restore passes `probing: false` —
    /// launch must never prompt; on a granted machine the first engage
    /// start just succeeds, on a revoked one it fails into the inert rows.
    func setTapsEnabled(_ on: Bool, probing: Bool) {
        onQueue {
            guard on != self.tapsEnabled else { return }
            self.tapsEnabled = on
            Self.logger.notice("Taps \(on ? "enabled" : "disabled", privacy: .public)")
            self.forgetFailures()
            if on && probing && self.permission != .granted {
                self.probe()
            }
            if on && !probing && self.permission == .denied {
                // A fresh session gets a fresh chance; the last denial may
                // have been revoked-and-regranted since.
                self.permission = .unknown
            }
            self.reconcile()
        }
    }

    /// Synchronous full teardown for `applicationWillTerminate`. No ramp: a
    /// clean destroy restores audio within 0.5 s (measured), and quit must
    /// not wait on the engine — bounded, because the queue may be sitting
    /// inside a prompt-blocked `AudioDeviceStart` (measured 17 s, unbounded
    /// until answered). A timed-out quit is the SIGKILL path, which fails
    /// open by `.mutedWhenTapped` (measured, 0.2 s).
    func shutdownSync() {
        let work = {
            self.tapsEnabled = false
            self.desires = []
            for aggregate in self.aggregates.values { self.teardown(aggregate) }
            for aggregate in self.replacedAggregates.values { self.teardown(aggregate) }
            self.aggregates = [:]
            self.replacedAggregates = [:]
            self.activeLegs = [:]
            self.publishTappedProcesses()
            Self.logger.notice("Engine shut down")
        }
        guard let queue else { work(); return }
        let done = DispatchSemaphore(value: 0)
        queue.async {
            work()
            done.signal()
        }
        if done.wait(timeout: .now() + 2) == .timedOut {
            Self.logger.error("Engine shutdown timed out (queue blocked, likely on the permission prompt); quitting anyway — taps fail open")
        }
    }

    // MARK: - Reconciling

    /// Re-entrancy guard: executing an op can change the inputs (a failed
    /// start marks the permission denied) and ask for another pass. The
    /// nested request is queued and the loop re-plans, so what gets
    /// published is never a plan the ops themselves invalidated.
    private var reconcileInProgress = false
    private var reconcileQueued = false
    /// Keys whose engage failed (or was skipped as a remembered failure)
    /// this pass without changing any planner input (process vanished, tap
    /// creation refused, device would not start), with the state to publish
    /// instead of the plan's. Downgraded rather than re-planned: re-planning
    /// would emit the same failing op forever.
    private var passFailures: [String: TapRowState] = [:]

    private func reconcile() {
        guard !reconcileInProgress else {
            reconcileQueued = true
            return
        }
        reconcileInProgress = true
        defer { reconcileInProgress = false }
        repeat {
            reconcileQueued = false
            passFailures = [:]
            let legFacts = activeLegs.values.map {
                TapLegFacts(key: $0.key, deviceUID: $0.deviceUID, pids: $0.pids,
                            gain: $0.gain, bass: $0.bass)
            }
            // One lookup per distinct device per pass: `device(forUID:)`
            // enumerates every Core Audio device and reads a UID off each,
            // while a live slider drag reconciles at pointer rate.
            var deviceCache: [String: TapHALDevice?] = [:]
            let plan = TapReconciler.plan(
                desires: desires,
                legs: legFacts,
                tapsEnabled: tapsEnabled,
                permissionDenied: permission == .denied,
                legsOnDevice: { uid in self.aggregates[uid]?.legs.count ?? 0 },
                device: { uid in
                    if let cached = deviceCache[uid] { return cached }
                    let device = self.hal.device(forUID: uid)
                    deviceCache[uid] = device
                    return device
                })
            for op in plan.ops { execute(op) }
            guard !reconcileQueued else { continue }
            // A pause with an unchanged gain plans no op, so nothing else
            // cancels a stale grace timer when playback resumes; without
            // this, a second pause soon after would inherit the first
            // pause's nearly-expired timer. Only for a settled owner: one
            // between devices is in its grace on purpose.
            let settledKeys = Set(desires.filter(Self.isSettled).map(\.key))
            for (key, leg) in activeLegs where leg.cancelGrace != nil && settledKeys.contains(key) {
                leg.cancelGrace?()
                leg.cancelGrace = nil
            }
            var states = plan.states
            for (key, state) in passFailures where states[key] == plan.states[key] {
                states[key] = state
            }
            watchFormats()
            publish(states)
            publishTappedProcesses()
        } while reconcileQueued
    }

    private func execute(_ op: TapPlanOp) {
        switch op {
        case .engage(let key, let deviceUID, let pids, let gain, let bass):
            engage(key: key, deviceUID: deviceUID, pids: pids, gain: gain, bass: bass)
        case .setGain(let key, let gain):
            guard let leg = activeLegs[key],
                  let aggregate = aggregates[leg.deviceUID] else { return }
            leg.cancelGrace?()
            leg.cancelGrace = nil
            leg.gain = gain
            aggregate.render.setTarget(gain, slot: leg.slot)
            // Pointer rate during a drag: chatter, not a state transition.
            Self.logger.debug("Gain \(key, privacy: .public) -> \(gain, privacy: .public)")
        case .setBass(let key, let level):
            guard let leg = activeLegs[key],
                  let aggregate = aggregates[leg.deviceUID] else { return }
            leg.bass = level
            aggregate.render.setBass(level, slot: leg.slot)
            Self.logger.notice("Bass \(key, privacy: .public) -> \(Self.describe(bass: level), privacy: .public)")
        case .disengage(let key, let afterGrace):
            guard let leg = activeLegs[key], !leg.rampingOut else { return }
            if afterGrace {
                guard leg.cancelGrace == nil else { return }
                Self.logger.notice("Grace started for \(key, privacy: .public)")
                leg.cancelGrace = schedule(graceDelay) { [weak self] in
                    self?.graceExpired(key: key)
                }
            } else {
                disengage(leg)
            }
        case .rebuild(let key, let deviceUID, let pids, let gain, let bass):
            // The owner's pid set changed: a helper restarted, or (routine
            // for Web content) a process joined or left. Make-before-break,
            // as M2 allows: the new tap joins first and the old leg stays,
            // keeping the app muted, until the new one is live. Tearing the
            // old one down first played the app at full volume for the gap.
            engage(key: key, deviceUID: deviceUID, pids: pids, gain: gain, bass: bass,
                   rebuild: true)
        }
    }

    /// Playing on exactly one device: nothing transient about it.
    private static func isSettled(_ desire: TapDesire) -> Bool {
        desire.isPlaying && desire.deviceUIDs.count == 1
    }

    /// "off", "+6 dB", ... for the logs.
    private static func describe(bass level: Int) -> String {
        level == 0 ? "off" : "+\(Int(BassBoost.gainDB(level: level))) dB"
    }

    private func graceExpired(key: String) {
        guard let leg = activeLegs[key] else { return }
        leg.cancelGrace = nil
        // Re-check: a resume, or the owner settling back onto one device,
        // between scheduling and firing keeps the leg.
        let settled = desires.first { $0.key == key }.map(Self.isSettled) ?? false
        guard !settled else { return }
        Self.logger.notice("Grace expired for \(key, privacy: .public)")
        disengage(leg)
    }

    // MARK: - Legs

    /// `rebuild`: the owner's pid set changed and its leg on this device is
    /// being replaced in the same aggregate (crossfaded, see below).
    private func engage(key: String, deviceUID: String, pids: [pid_t], gain: Float, bass: Int,
                        rebuild: Bool = false) {
        guard permission != .denied, tapsEnabled else { return }
        // A leg mid-ramp-out on the same device (a slider wiggle through
        // 100, or a resume racing an expired grace) is revived rather than
        // doubled: a second tap on the same pids would render the app at
        // both legs' gains summed for the ramp window.
        if let aggregate = aggregates[deviceUID],
           let retiring = aggregate.legs.first(where: { $0.key == key && $0.rampingOut }),
           Set(retiring.pids) == Set(pids) {
            // A route flipped back inside a handover: the leg that replaced
            // this one is active elsewhere and must retire in its place, or
            // it would keep rendering the app on that device for good. The
            // revived leg never left its tap list, so the app stays muted
            // and there is nothing to wait for.
            if let current = activeLegs[key], current !== retiring {
                retire(current, fadeTo: 0, hold: 0)
            }
            retiring.cancelRetire?()
            retiring.cancelRetire = nil
            retiring.retireToken &+= 1
            retiring.rampingOut = false
            retiring.gain = gain
            retiring.bass = bass
            aggregate.render.clearHandover(retiring.slot)
            aggregate.render.setTarget(gain, slot: retiring.slot)
            aggregate.render.setBass(bass, slot: retiring.slot)
            activeLegs[key] = retiring
            Self.logger.notice("Revived \(key, privacy: .public) mid-rampout at gain \(gain, privacy: .public), bass \(Self.describe(bass: bass), privacy: .public)")
            return
        }
        // A leg already active for this key is the one this engage replaces:
        // a device move or a route change, or — `rebuild` — the same device
        // on a new pid set. It keeps rendering, and keeps the app muted,
        // until the new leg is live; every failure below leaves it exactly
        // as it was, so a move that cannot be built never sends the app back
        // to full volume (M2: with two taps the mute holds until the last) —
        // unless its device is gone, when keeping it would keep the app
        // muted with nowhere to play (`releaseIfStranded`).
        let old = activeLegs[key]
        let signature = Self.signature(deviceUID: deviceUID, pids: pids)
        if let failure = failedEngages[key], failure.signature == signature, now() < failure.until {
            markFailed(key, reason: failure.reason)
            return
        }
        if aggregates[deviceUID] == nil, let failure = failedDevices[deviceUID], now() < failure.until {
            markFailed(key, reason: failure.reason)
            return
        }
        let crossfade = rebuild && old?.deviceUID == deviceUID
        // Where the new leg's ramp starts. A first engage starts at unity,
        // level with the original it replaces; a leg replacing one on
        // another aggregate at that leg's level (a move, a format rebuild),
        // so the new path never opens at full volume; a rebuild's crossfade
        // at silence.
        let startGain: Float = crossfade ? 0 : (old?.gain ?? carriedGains[key] ?? 1)

        if let aggregate = aggregates[deviceUID] {
            // The edit below writes the mapping row for the grown count. If
            // the HAL may still be presenting that count from before the
            // last edit, wait for that edit to land. Checked before a slot
            // is taken, so waiting does not turn the slot rotation.
            guard canEdit(aggregate, toCount: aggregate.legs.count + 1) else {
                retryWhenObserved(aggregate)
                return
            }
            guard let slot = freeSlot(in: aggregate) else {
                Self.logger.error("No free slot on \(deviceUID, privacy: .public)")
                engageFailed(key, signature: signature, reason: nil)
                return
            }
            guard let (tapID, tapUID) = makeTap(for: key, pids: pids) else {
                engageFailed(key, signature: signature, reason: nil)
                return
            }
            let leg = Leg(key: key, deviceUID: deviceUID, tapID: tapID, tapUID: tapUID,
                          pids: pids, gain: gain, bass: bass, slot: slot)
            aggregate.render.prepareSlot(slot, targetGain: gain, startGain: startGain, bass: bass)
            if crossfade, let old {
                // The old leg's fade waits on the IO thread for the new
                // stream, so the two ramps cross instead of leaving a gap.
                aggregate.render.holdUntilPresent(old.slot, replacement: slot)
            }
            let newLegs = aggregate.legs + [leg]
            // Mapping for the grown topology goes in before the edit that
            // makes it real; the IOProc keys rows by buffer count.
            aggregate.render.setMapping(bufferCount: newLegs.count,
                                        slots: newLegs.map { Int32($0.slot) })
            guard hal.setTapList(newLegs.map(\.tapUID), onAggregate: aggregate.id) else {
                if crossfade, let old { aggregate.render.clearHandover(old.slot) }
                aggregate.render.releaseSlot(slot)
                hal.destroyTap(tapID)
                engageFailed(key, signature: signature, reason: nil)
                return
            }
            noteEdit(aggregate, count: newLegs.count)
            aggregate.legs = newLegs
            if let old {
                // Fades to silence, never to unity — the new leg's tap keeps
                // the app muted, so the original does not come back on the
                // old leg's device — after holding for the new path's
                // warm-up when that path renders away from the app's own
                // device. A crossfade needs no hold: the IO thread holds.
                retire(old, fadeTo: 0, hold: crossfade ? 0 : handover(toward: deviceUID, key: key))
            }
            activeLegs[key] = leg
            failedEngages[key] = nil
            if crossfade {
                Self.logger.notice("Rebuilt \(key, privacy: .public) on new pids \(pids.map(String.init).joined(separator: ","), privacy: .public) on \(deviceUID, privacy: .public) (slot \(slot, privacy: .public), crossfading from slot \(old?.slot ?? -1, privacy: .public))")
            } else {
                Self.logger.notice("Engaged \(key, privacy: .public) gain \(gain, privacy: .public) bass \(Self.describe(bass: bass), privacy: .public) on \(deviceUID, privacy: .public) (slot \(slot, privacy: .public), \(newLegs.count, privacy: .public) legs)")
            }
            return
        }

        // First leg on this device: build the aggregate around it.
        guard let device = hal.device(forUID: deviceUID) else {
            engageFailed(key, signature: signature, reason: nil)
            return
        }
        guard let (tapID, tapUID) = makeTap(for: key, pids: pids) else {
            engageFailed(key, signature: signature, reason: nil)
            return
        }
        let render = TapRenderState(sampleRate: device.sampleRate)
        let leg = Leg(key: key, deviceUID: deviceUID, tapID: tapID, tapUID: tapUID,
                      pids: pids, gain: gain, bass: bass, slot: 0)
        render.prepareSlot(0, targetGain: gain, startGain: startGain, bass: bass)
        render.setMapping(bufferCount: 1, slots: [0])
        guard let aggID = hal.makeAggregate(outputDeviceUID: deviceUID, tapUIDs: [tapUID]) else {
            hal.destroyTap(tapID)
            engageFailed(key, signature: signature, reason: nil)
            return
        }
        guard let procID = hal.installIOProc(onAggregate: aggID, render: render) else {
            hal.destroyAggregate(aggID)
            hal.destroyTap(tapID)
            engageFailed(key, signature: signature, reason: nil)
            return
        }
        let status = hal.start(aggID, proc: procID)
        guard status == noErr else {
            // Authorization surfaces here (no preflight API exists), but so
            // does a device that will not start: hogged, or unplugged
            // mid-engage. The probe tells them apart.
            Self.logger.error("Start failed on \(deviceUID, privacy: .public) (\(status, privacy: .public)); probing capture")
            dismantle(aggID, proc: procID, taps: [tapID], started: false)
            startFailed(key: key, deviceUID: deviceUID)
            return
        }
        let aggregate = Aggregate(deviceUID: deviceUID, id: aggID, procID: procID, render: render)
        aggregate.legs = [leg]
        aggregates[deviceUID] = aggregate
        if let old {
            retire(old, fadeTo: 0, hold: handover(toward: deviceUID, key: key))
        }
        activeLegs[key] = leg
        failedEngages[key] = nil
        failedDevices[deviceUID] = nil
        Self.logger.notice("Engaged \(key, privacy: .public) gain \(gain, privacy: .public) bass \(Self.describe(bass: bass), privacy: .public) on new aggregate for \(deviceUID, privacy: .public)")
    }

    /// The owner's process objects, then a tap on them; nil when the
    /// processes are gone or the tap is refused (the HAL logs that).
    private func makeTap(for key: String, pids: [pid_t]) -> (tap: AudioObjectID, uid: String)? {
        let objects = pids.compactMap { hal.processObject(forPID: $0) }
        guard !objects.isEmpty else {
            Self.logger.notice("No process objects for \(key, privacy: .public); not engaging")
            return nil
        }
        return hal.makeTap(processObjects: objects)
    }

    private static func signature(deviceUID: String, pids: [pid_t]) -> String {
        deviceUID + "|" + pids.sorted().map(String.init).joined(separator: ",")
    }

    /// This pass's published state for a key whose engage failed or was
    /// skipped: the reason when there is one; otherwise not tapped, unless
    /// an existing leg is still rendering it (a move that could not be
    /// built leaves the old leg in place).
    private func markFailed(_ key: String, reason: String?) {
        if let reason {
            passFailures[key] = .inert(reason: reason)
        } else if activeLegs[key] == nil {
            passFailures[key] = .notTapped
        }
    }

    private func engageFailed(_ key: String, signature: String, reason: String?) {
        failedEngages[key] = EngageFailure(signature: signature, reason: reason,
                                           until: now() + failureRetryDelay)
        releaseIfStranded(key)
        markFailed(key, reason: reason)
    }

    /// A failed engage keeps the leg it would have replaced, which is right
    /// only while that leg's device is still there to render it. Once the
    /// device is gone (a DAC unplugged, and the fallback onto the app's own
    /// output failing), the old tap keeps the app muted while rendering
    /// nowhere: silence until a retry succeeds. Retiring it gives the app
    /// back at its own volume instead. "Gone" is the planner's test for
    /// connected, `device(forUID:)`. Only real failures check: a remembered
    /// one cannot outlive a device-list change (`forgetFailures`).
    private func releaseIfStranded(_ key: String) {
        guard let old = activeLegs[key], case .none = hal.device(forUID: old.deviceUID) else { return }
        Self.logger.notice("\(old.deviceUID, privacy: .public) is gone and \(key, privacy: .public) could not move; retiring its old leg so the app is heard")
        disengage(old)
    }

    /// A start failed. Only a failed probe — a tap-only aggregate with no
    /// output device — means capture is refused; anything else is this
    /// device, and only this device's rows go inert.
    private func startFailed(key: String, deviceUID: String) {
        probe()
        guard permission != .denied else {
            Self.logger.error("Probe failed too; treating capture permission as denied")
            reconcile()
            return
        }
        let reason = "output couldn't start"
        failedDevices[deviceUID] = (reason, now() + failureRetryDelay)
        Self.logger.error("Capture works but \(deviceUID, privacy: .public) would not start; leaving it for \(self.failureRetryDelay, privacy: .public) s")
        releaseIfStranded(key)
        markFailed(key, reason: reason)
    }

    private func forgetFailures() {
        failedEngages = [:]
        failedDevices = [:]
    }

    // MARK: - Edit observation (the mapping-row guard)

    /// Whether an edit to `count` buffers may write its mapping row now.
    /// It may not while the HAL may still be presenting that count from an
    /// earlier layout — e.g. [A, X, B] → remove X → [A, B] → add X′ makes
    /// three buffers mean [A, B, X′] while the HAL can still be presenting
    /// [A, X, B], playing B at X′'s gain. Bounded by `observeTimeout`, so an
    /// aggregate whose IO never runs cannot wedge the engine.
    private func canEdit(_ aggregate: Aggregate, toCount count: Int) -> Bool {
        if aggregate.presentable.count > 1,
           Int(aggregate.render.observedBufferCount.pointee) == aggregate.expectedCount {
            aggregate.presentable = [aggregate.expectedCount]
        }
        guard aggregate.presentable.contains(count) else {
            aggregate.deferringSince = nil
            return true
        }
        guard let since = aggregate.deferringSince else {
            aggregate.deferringSince = now()
            Self.logger.notice("Deferring a tap-list edit on \(aggregate.deviceUID, privacy: .public) until the last one lands")
            return false
        }
        guard now() - since >= observeTimeout else { return false }
        Self.logger.notice("Last tap-list edit on \(aggregate.deviceUID, privacy: .public) not seen to land in \(self.observeTimeout, privacy: .public) s; editing anyway")
        aggregate.presentable = [aggregate.expectedCount]
        aggregate.deferringSince = nil
        return true
    }

    private func noteEdit(_ aggregate: Aggregate, count: Int) {
        aggregate.expectedCount = count
        aggregate.presentable.insert(count)
        aggregate.deferringSince = nil
    }

    /// One pending re-plan per aggregate while a join waits on an edit to
    /// land; a drag's pointer-rate reconciles do not stack more.
    private func retryWhenObserved(_ aggregate: Aggregate) {
        guard aggregate.cancelObserveRetry == nil else { return }
        aggregate.cancelObserveRetry = schedule(observeRetryDelay) { [weak self, weak aggregate] in
            aggregate?.cancelObserveRetry = nil
            self?.reconcile()
        }
    }

    /// Taking an owner off the tap path entirely. Where the app's original
    /// returns on this leg's own device, ramp to unity so the handover is
    /// level-matched (disengage measured clean). A routed leg's original
    /// returns somewhere else, so this device fades out instead of jumping
    /// to full volume just before it goes quiet.
    private func disengage(_ leg: Leg) {
        let own = desires.first { $0.key == leg.key }?.deviceUIDs
        let returnsHere = own == nil || own == [leg.deviceUID]
        retire(leg, fadeTo: returnsHere ? 1 : 0, hold: 0)
    }

    /// How long a leg being replaced keeps rendering: nothing when the new
    /// leg renders where the app itself plays (52 ms warm-up, measured), the
    /// cross-device handover otherwise.
    private func handover(toward uid: String, key: String) -> TimeInterval {
        let own = desires.first { $0.key == key }?.deviceUIDs ?? []
        return own == [uid] ? 0 : crossDeviceHandover
    }

    /// Retirement step one: after `hold` at its current gain, ramp to
    /// `fadeTo`; step two, `remove`, follows the ramp. The leg stays in its
    /// tap list — and keeps the app muted — until then.
    private func retire(_ leg: Leg, fadeTo: Float, hold: TimeInterval) {
        guard !leg.rampingOut else { return }
        leg.rampingOut = true
        leg.retireToken &+= 1
        leg.cancelGrace?()
        leg.cancelGrace = nil
        if activeLegs[leg.key] === leg { activeLegs.removeValue(forKey: leg.key) }
        guard hold > 0 else {
            fade(leg, to: fadeTo, token: leg.retireToken)
            return
        }
        let token = leg.retireToken
        Self.logger.notice("Holding \(leg.key, privacy: .public) on \(leg.deviceUID, privacy: .public) for \(hold, privacy: .public) s while its new path warms up")
        leg.cancelRetire = schedule(hold) { [weak self] in
            self?.fade(leg, to: fadeTo, token: token)
        }
    }

    private func fade(_ leg: Leg, to gain: Float, token: Int) {
        // A revival or a later retirement since this was scheduled owns the
        // leg now.
        guard leg.rampingOut, leg.retireToken == token else { return }
        aggregates[leg.deviceUID]?.render.setTarget(gain, slot: leg.slot)
        if gain == 1 && leg.bass != 0 {
            // Handing back to the app's own output, which is unboosted: the
            // filter crossfades out (one callback) inside the gain ramp, so
            // by removal the leg is exactly the original and the handover
            // stays level-matched. A fade to silence keeps its curve — the
            // app's other leg is boosted too, and nothing returns here.
            leg.bass = 0
            aggregates[leg.deviceUID]?.render.setBass(0, slot: leg.slot)
        }
        Self.logger.notice("Ramping out \(leg.key, privacy: .public) on \(leg.deviceUID, privacy: .public) to \(gain == 0 ? "silence" : "unity", privacy: .public)")
        leg.cancelRetire = schedule(rampDelay) { [weak self] in
            self?.remove(leg, token: token)
        }
    }

    /// Retirement step two: edit the leg out of the live tap list (the
    /// unmute — mute follows membership, measured), destroy its tap, and
    /// fold the aggregate when it was the last one. `waited` marks a retry
    /// that had to wait for the previous tap-list edit to land.
    private func remove(_ leg: Leg, token: Int, waited: Bool = false) {
        // Whichever way this returns, the leg set may have changed.
        defer { publishTappedProcesses() }
        // A stale retire can fire after a revival cancelled it (cancelling
        // a work item already dequeued does not stop it): a leg that is no
        // longer ramping out is active again and must stay, and one retired
        // again since belongs to that newer retirement.
        guard leg.rampingOut, token == leg.retireToken else { return }
        leg.cancelRetire = nil
        leg.cancelGrace?()
        guard let aggregate = aggregates[leg.deviceUID],
              aggregate.legs.contains(where: { $0 === leg }) else {
            hal.destroyTap(leg.tapID)
            return
        }
        let remaining = aggregate.legs.filter { $0 !== leg }
        guard !remaining.isEmpty else {
            aggregates.removeValue(forKey: leg.deviceUID)
            teardown(aggregate)
            watchFormats()
            Self.logger.notice("Last leg left; aggregate for \(leg.deviceUID, privacy: .public) torn down")
            return
        }
        // The shrunken count's row may still be on show from before the
        // last edit (a rebuild's join, say): wait for that edit to land.
        guard canEdit(aggregate, toCount: remaining.count) else {
            leg.cancelRetire = schedule(observeRetryDelay) { [weak self] in
                self?.remove(leg, token: token, waited: true)
            }
            return
        }
        if waited {
            // The edit this waited on has just landed, and with it any
            // replacement stream a crossfade was holding for: the fade
            // starts now, so it gets its ramp before the leg goes.
            leg.cancelRetire = schedule(rampDelay) { [weak self] in
                self?.remove(leg, token: token)
            }
            return
        }
        // Survivor stream indices shift down (measured); their new mapping
        // is published before the edit, keyed by the shrunken buffer count.
        aggregate.render.setMapping(bufferCount: remaining.count,
                                    slots: remaining.map { Int32($0.slot) })
        if !hal.setTapList(remaining.map(\.tapUID), onAggregate: aggregate.id) {
            Self.logger.error("Tap-list removal failed for \(leg.key, privacy: .public); rebuilding aggregate")
            aggregates.removeValue(forKey: leg.deviceUID)
            teardown(aggregate)
            reconcile()
            return
        }
        noteEdit(aggregate, count: remaining.count)
        aggregate.legs = remaining
        // Nothing of this leg's filter may reach whoever takes the slot next.
        aggregate.render.releaseSlot(leg.slot)
        hal.destroyTap(leg.tapID)
        Self.logger.notice("Removed \(leg.key, privacy: .public); \(remaining.count, privacy: .public) legs remain on \(leg.deviceUID, privacy: .public)")
    }

    private func freeSlot(in aggregate: Aggregate) -> Int? {
        let used = Set(aggregate.legs.map(\.slot))
        for offset in 0..<TapRenderState.maxLegs {
            let slot = (aggregate.slotCursor + offset) % TapRenderState.maxLegs
            if !used.contains(slot) {
                aggregate.slotCursor = (slot + 1) % TapRenderState.maxLegs
                return slot
            }
        }
        return nil
    }

    private func teardown(_ aggregate: Aggregate) {
        for leg in aggregate.legs {
            // Cancel AND clear: the closures retain their work items, whose
            // blocks retain the leg — left set, a mid-ramp leg would leak.
            leg.cancelRetire?()
            leg.cancelRetire = nil
            leg.cancelGrace?()
            leg.cancelGrace = nil
            if activeLegs[leg.key] === leg { activeLegs.removeValue(forKey: leg.key) }
        }
        aggregate.cancelObserveRetry?()
        aggregate.cancelObserveRetry = nil
        dismantle(aggregate.id, proc: aggregate.procID, taps: aggregate.legs.map(\.tapID), started: true)
        aggregate.legs = []
    }

    /// Empty the tap list first — the measured unmute: mute follows list
    /// membership (M1) — so the apps are back whatever happens to the calls
    /// after it; then stop → destroy IOProc → destroy aggregate → destroy
    /// taps, the reverse of creation. A failing step is logged by the HAL
    /// and does not stop the ones after it. Emptying a whole list in one
    /// edit is unmeasured; M1 edited one entry at a time.
    private func dismantle(_ id: AudioObjectID, proc: AudioDeviceIOProcID,
                           taps: [AudioObjectID], started: Bool) {
        if !hal.setTapList([], onAggregate: id) {
            Self.logger.error("Could not empty the tap list of \(id, privacy: .public); tearing down anyway")
        }
        if started { hal.stop(id, proc: proc) }
        hal.destroyIOProc(proc, onAggregate: id)
        hal.destroyAggregate(id)
        for tap in taps { hal.destroyTap(tap) }
    }

    /// Hands the HAL the device set to watch formats on when it changed, or
    /// when an event forgot the last one (it re-resolves IDs on each call).
    private func watchFormats() {
        let uids = Set(aggregates.keys)
        guard uids != watchedFormatUIDs else { return }
        hal.watchDeviceFormats(uids: uids)
        watchedFormatUIDs = uids
    }

    // MARK: - Permission probe

    /// One deliberate start at toggle-on, so the prompt happens there and
    /// nowhere else (decision 3). An unmuted global tap: it changes nothing
    /// audible and is destroyed straight after.
    private func probe() {
        guard let (tapID, tapUID) = hal.makeProbeTap() else {
            permission = .denied
            Self.logger.error("Probe tap creation failed; capture unavailable")
            return
        }
        guard let aggID = hal.makeAggregate(outputDeviceUID: nil, tapUIDs: [tapUID]) else {
            hal.destroyTap(tapID)
            permission = .denied
            return
        }
        let render = TapRenderState(sampleRate: 48000)
        guard let procID = hal.installIOProc(onAggregate: aggID, render: render) else {
            hal.destroyAggregate(aggID)
            hal.destroyTap(tapID)
            permission = .denied
            return
        }
        Self.logger.notice("Capture probe starting (may block on the permission prompt)")
        let status = hal.start(aggID, proc: procID)
        hal.stop(aggID, proc: procID)
        hal.destroyIOProc(procID, onAggregate: aggID)
        hal.destroyAggregate(aggID)
        hal.destroyTap(tapID)
        permission = status == noErr ? .granted : .denied
        Self.logger.notice("Capture probe -> \(status == noErr ? "granted" : "denied (\(status))", privacy: .public)")
    }

    // MARK: - External invalidation

    /// Every held ID is stale after a coreaudiod restart; drop references
    /// without destroy calls and rebuild from desires. Never routed to the
    /// permission-denied state — the grant did not change.
    private func handleServiceRestarted() {
        for aggregate in aggregates.values {
            for leg in aggregate.legs {
                leg.cancelRetire?()
                leg.cancelRetire = nil
                leg.cancelGrace?()
                leg.cancelGrace = nil
            }
        }
        // The IOProc blocks and their render states are knowingly dropped
        // unreleased: destroying against IDs the restarted daemon has
        // invalidated is riskier than a few KB per restart. Recorded.
        aggregates = [:]
        replacedAggregates = [:]
        activeLegs = [:]
        // The format listeners were registered with the old daemon, and the
        // new one may reuse the same object numbers: drop them all, so the
        // next reconcile registers afresh.
        hal.watchDeviceFormats(uids: [])
        watchedFormatUIDs = []
        forgetFailures()
        reconcile()
    }

    /// The device's rate or stream layout changed. Make-before-break, like
    /// a move: the replacement aggregate is built first, each leg opening
    /// at its predecessor's gain, and the old one keeps rendering until the
    /// replacement is seen live — while both exist the apps stay muted
    /// (M2), so a per-track rate switch neither blips a turned-down app to
    /// full volume nor drops it for the new path's warm-up (52 ms for the
    /// first leg, up to ~1 s for one joining by live edit, M1). Then the
    /// old legs fade to silence and the old aggregate folds, as a moved leg
    /// does. A device that grew input streams is no longer a target, so
    /// nothing replaces its aggregate; it goes at once and the apps come
    /// back on their own.
    private func handleFormatChanged(_ uid: String) {
        guard let old = aggregates.removeValue(forKey: uid) else { return }
        // A replacement being replaced in turn: the one before it has
        // nothing left to wait for, and the newer one keeps the apps muted.
        if let stale = replacedAggregates.removeValue(forKey: uid) {
            teardown(stale)
            Self.logger.notice("Earlier replaced aggregate for \(uid, privacy: .public) torn down; the format changed again")
        }
        Self.logger.notice("Device format changed on \(uid, privacy: .public); building its replacement before tearing the old aggregate down")
        for leg in old.legs {
            if activeLegs[leg.key] === leg {
                activeLegs.removeValue(forKey: leg.key)
                carriedGains[leg.key] = leg.gain
            }
            // Its retirement work, if any, looks the leg's aggregate up by
            // device UID, which now names the replacement; the whole old
            // aggregate goes in one piece instead.
            leg.cancelRetire?()
            leg.cancelRetire = nil
            leg.retireToken &+= 1
            leg.cancelGrace?()
            leg.cancelGrace = nil
        }
        replacedAggregates[uid] = old
        failedEngages = [:]
        failedDevices[uid] = nil
        reconcile()
        carriedGains = [:]
        guard let replacement = aggregates[uid] else {
            foldReplaced(old)
            return
        }
        awaitReplacement(of: old, by: replacement, since: now())
    }

    /// Polls the replacement until the IO thread presents the buffer count
    /// its last edit asked for — the same observation and the same one-shot
    /// retry and timeout as the mapping-row guard (`canEdit`) — then fades
    /// the old legs whose apps it carries to silence and folds the old
    /// aggregate after the ramp, as a moved leg is retired. A replacement
    /// that is itself gone, or not seen live within `observeTimeout`, folds
    /// the old one at once, so nothing outlives the timeout.
    private func awaitReplacement(of old: Aggregate, by replacement: Aggregate, since: TimeInterval) {
        guard replacedAggregates[old.deviceUID] === old else { return }
        old.cancelObserveRetry = nil
        guard aggregates[old.deviceUID] === replacement else {
            foldReplaced(old)
            return
        }
        guard Int(replacement.render.observedBufferCount.pointee) == replacement.expectedCount else {
            guard now() - since < observeTimeout else {
                Self.logger.notice("Replacement for \(old.deviceUID, privacy: .public) not seen live in \(self.observeTimeout, privacy: .public) s; tearing the old aggregate down anyway")
                foldReplaced(old)
                return
            }
            // The replacement is held strongly: if it goes away meanwhile,
            // the next check must still run to fold the old aggregate.
            old.cancelObserveRetry = schedule(observeRetryDelay) { [weak self, weak old] in
                guard let self, let old else { return }
                self.awaitReplacement(of: old, by: replacement, since: since)
            }
            return
        }
        let carried = Set(replacement.legs.map(\.key))
        for leg in old.legs where carried.contains(leg.key) {
            old.render.setTarget(0, slot: leg.slot)
        }
        Self.logger.notice("Replacement for \(old.deviceUID, privacy: .public) is live; ramping the old aggregate out")
        old.cancelObserveRetry = schedule(rampDelay) { [weak self, weak old] in
            guard let self, let old else { return }
            self.foldReplaced(old)
        }
    }

    private func foldReplaced(_ old: Aggregate) {
        guard replacedAggregates[old.deviceUID] === old else { return }
        replacedAggregates.removeValue(forKey: old.deviceUID)
        teardown(old)
        publishTappedProcesses()
        Self.logger.notice("Old aggregate for \(old.deviceUID, privacy: .public) torn down after the format change")
    }

    /// A device came or went. A route whose device was unplugged falls back
    /// to the app's own output, and one whose device returned is routed
    /// again — both by re-planning, since the planner resolves every target
    /// from the live device list. Our own aggregates coming and going fire
    /// this too; they are not in the published list, so an unchanged list
    /// means nothing a route could care about happened.
    private func handleDevicesChanged() {
        guard publishOutputDevices() else { return }
        Self.logger.notice("Output devices changed; re-resolving routes")
        // A device that came back is a fresh chance, and may have come back
        // under a new object ID that the format listener must follow.
        forgetFailures()
        watchedFormatUIDs = nil
        reconcile()
    }

    // MARK: - Publishing

    private func publish(_ states: [String: TapRowState]) {
        guard states != published else { return }
        published = states
        guard let statesHandler else { return }
        notify { statesHandler(states) }
    }

    /// Returns whether the list changed since the last publish.
    @discardableResult
    private func publishOutputDevices() -> Bool {
        let devices = hal.outputDevices()
        guard devices != publishedOutputDevices else { return false }
        publishedOutputDevices = devices
        Self.logger.notice("Output devices (\(devices.count, privacy: .public)): \(devices.map(\.uid).joined(separator: ", "), privacy: .public)")
        guard let outputDevicesHandler else { return true }
        notify { outputDevicesHandler(devices) }
        return true
    }

    /// Idempotent, so every path that can change a leg calls it without
    /// having to know whether another one already did.
    private func publishTappedProcesses() {
        // A replaced aggregate's legs still mute their apps until it folds.
        let all = Array(aggregates.values) + Array(replacedAggregates.values)
        let pids = Array(Set(all.flatMap { $0.legs.flatMap(\.pids) })).sorted()
        guard pids != publishedTappedPIDs else { return }
        publishedTappedPIDs = pids
        guard let tappedProcessesHandler else { return }
        notify { tappedProcessesHandler(pids) }
    }
}
