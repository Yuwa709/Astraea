import Foundation
import AppKit
import CoreAudio
import AudioToolbox
import Accelerate
import Observation
import os

/// System-audio capture reduced to a small band spectrum, for a future
/// notch visualiser.
///
/// Distinct from `ArtworkVisualizerView`, which derives a glow from album
/// artwork and never touches audio. This reads the actual output signal.
///
/// **Why Core Audio taps and not ScreenCaptureKit.** SCK was the first
/// attempt and was wrong: its audio rides on a screen-content stream —
/// `SCContentFilter` has no audio-only initialiser, every one of them takes
/// a display, window or application — so it requires the *full* Screen
/// Recording grant. Core Audio process taps use the lighter **System Audio
/// Recording Only** permission instead, which is the correct grant for an
/// app that only wants the output signal. Verified end to end on this
/// machine 2026-08-29: tap created, private aggregate device created, IO
/// proc started, 562 buffers of 1024 frames delivered with RMS tracking the
/// music.
///
/// **Deployment target.** Process taps need macOS 14.2, and the app's floor
/// was raised to match rather than gating the feature. The gate cost a
/// type-erased `AnyObject` and three `as?` casts, purely so a 14.0-available
/// type could avoid naming a 14.2-available one — for a version that shipped
/// in December 2023 and that every Mac with a notch runs.
///
/// **Permission.** There is no preflight API for the audio-only grant — a
/// search of the SDK finds only `CGPreflightScreenCaptureAccess`,
/// `CGPreflightListenEventAccess` and `CGPreflightPostEventAccess`, none of
/// which describe this. Authorization therefore shows up as
/// `AudioDeviceStart` failing, which is handled as a logged, quiet decline.
///
/// **Lifetime.** Off by default. Capture runs only while all three of
/// enabled, spectrum-on-screen and *actively playing* hold, and is torn down
/// the moment any of them stops — hard rule 9's "nothing runs when nobody is
/// looking", expressed without a timer. The one exception is the pause
/// settle, a short bounded run of band updates after capture has already
/// stopped; see `pauseSettleDuration`.
///
/// The playback condition matters beyond tidiness. The tap is whole-system:
/// with only enabled-and-visible gating, the bars would dance to a YouTube
/// tab, a notification chime, or a video call while the notch showed a
/// paused track. Gating on the tracked player's state keeps the spectrum
/// honestly about the music the notch is displaying. Per-app isolation is a
/// different thing entirely and stays deferred — see
/// `docs/FUTURE-audio-mixer.md`.
///
/// **What the tap excludes (Phase 6).** Whatever the tap engine is muting
/// and re-rendering, pushed in through `setTappedProcesses`. A tapped app's
/// own stream is muted before it reaches the hardware, so leaving it in the
/// tap would show a level nobody can hear; Astraea's re-render of that app
/// is in the tap already — a global tap includes this process — and carries
/// the gain the user chose. Exclude the tapped processes and the tap's
/// content is the room's content.
@MainActor
@Observable
final class AudioVisualizerService {

    @ObservationIgnored
    private static let logger = Logger(subsystem: "com.techie.Astraea", category: "AudioViz")

    /// Bands published to any future view. Log-spaced, so low frequencies —
    /// where music actually lives — are not crushed into one bar.
    ///
    /// `nonisolated`: an immutable Int the analysis queue reads. Without it
    /// the target's MainActor-by-default isolation makes this unreachable
    /// from the very code that sizes its output.
    nonisolated static let bandCount = 16

    private(set) var bands: [Float] = Array(repeating: 0, count: bandCount)
    private(set) var isRunning = false
    /// Why capture is not running, when that is worth showing or logging.
    private(set) var lastError: String?

    @ObservationIgnored private(set) var isEnabled = false
    /// Processes the tap engine is currently muting and re-rendering, which
    /// this tap excludes. See `setTappedProcesses`. Readable so a test can
    /// check what was excluded without opening a real tap.
    @ObservationIgnored private(set) var tappedPIDs: [pid_t] = []
    /// Whether the view that draws the spectrum is on screen. Readable so tests
    /// can check what the media module reported without opening a real tap.
    @ObservationIgnored private(set) var spectrumVisible = false
    /// Driven by the media module from the active source's player state.
    @ObservationIgnored private var isPlaying = false
    @ObservationIgnored private var capture: (any AudioCaptureEngine)?
    @ObservationIgnored private let makeCapture: CaptureFactory
    /// The pause settle in progress, if any. See `settle()`.
    @ObservationIgnored private var settleTask: Task<Void, Never>?
    /// Throttles the verification logging; no timer, just a clock check on
    /// buffers that are arriving anyway.
    @ObservationIgnored private var lastLogged = Date.distantPast

    /// Per-band reference levels in dB: the ceiling each band is normalised
    /// against, with `dynamicWindow` of range below it.
    ///
    /// **Measured, not assumed** (2026-08-29, live playback through the tap):
    /// musical energy tilts ~67 dB across the spectrum — band 0 peaked at
    /// +35 dB while band 14 peaked at -32 dB. The old single mapping,
    /// `(db + 60) / 60`, assumed a flat -60 floor: it pinned bands 0-7 at
    /// 1.0 permanently and let the treble barely move. These references are
    /// the measured peak envelope, lightly smoothed, so every band's musical
    /// peak lands near the top of its own bar.
    nonisolated static let referenceDB: [Float] = [
        36, 36, 33, 28, 22, 17, 14, 12,
        11, 9, 4, -2, -9, -17, -24, -18,
    ]

    /// How far below its ceiling a band stays visible. Narrower means more
    /// height per dB, so bands separate and travel further.
    ///
    /// **35 is the measured optimum**, simulated against live audio
    /// 2026-08-29 across 45/35/30/26/22/18 dB. Mean cross-band spread peaks
    /// there at 0.71 (45 gave 0.61) and then *falls* as the window keeps
    /// narrowing, because bands start hitting the floor rather than
    /// separating: 30 floors 4 bands a frame, 26 floors 8 of 16, and spread
    /// collapses to 0.51 by 18. Pinning stayed at 0.00 bands/frame at every
    /// candidate, so none of this risks the max-volume brick returning —
    /// that is the adaptive gain's job and it still does it.
    nonisolated static let dynamicWindow: Float = 35

    /// dB of headroom kept above the recent peak, so the loudest band lands
    /// just below the top instead of pinned against it. 3 dB puts a peak at
    /// 42/45 = 0.93 of full height, which still reads as "maxed" while
    /// leaving room to show a louder transient.
    nonisolated static let peakHeadroom: Float = 3

    /// How far the adaptive ceiling may fall below the measured references.
    /// Without a floor the gain would keep climbing through a quiet passage
    /// until room tone lit the bars.
    nonisolated static let minimumGain: Float = -12

    /// How much of a *rising* band's previous value survives each buffer:
    /// every buffer closes `1 - barAttack` of the gap to the new level. 0 is
    /// an instant jump; nearer 1 is a slower swell.
    ///
    /// **0.675: a rise covers half its travel in ~2 buffers (~40ms) and 90% in
    /// ~6 (~125ms)**, at 1024-frame buffers and 48kHz, about 47 a second.
    /// Attack was instant until 2026-09-16, when the spectrum had become the
    /// scrub bar and every transient snapped it to full height: it read as
    /// flicker rather than level. 0.8 (90% in ~220ms) then overcorrected into
    /// a rectangle with a ripple, and 0.55 (~80ms) came back slightly too
    /// jumpy; 0.675 splits the difference.
    nonisolated static let barAttack: Float = 0.675

    /// How much of a *falling* band's previous value survives each buffer:
    /// every buffer closes `1 - barRelease` of the gap.
    ///
    /// **0.9: a fall covers half its travel in ~7 buffers (~140ms) and 90% in
    /// ~22 (~470ms)**, so peaks subside smoothly while troughs still open up
    /// between them (0.92 held the wave up and helped flatten it). Deliberately
    /// slower than the attack: a band that falls as fast as it rises reads as
    /// flicker rather than as level.
    ///
    /// It was 0.35, measured on 2026-08-30 to pass about 80% of the raw
    /// frame-to-frame travel (0.073 of full height per buffer) to the old
    /// header bars, where motion was the point. The scrub bar wants calm, and
    /// gives most of that travel up on purpose. Neither constant can bring
    /// back the max-volume brick, which the adaptive gain owns.
    nonisolated static let barRelease: Float = 0.9

    /// The shortest gap between two publishes: at most one every 40ms (25Hz).
    ///
    /// Analysis still runs on every buffer, so the smoothing above keeps its
    /// time base; only what reaches the main actor is thinned. At 1024-frame
    /// buffers that lets every second buffer through at 48kHz (~23Hz) and
    /// 44.1kHz (~22Hz), and every fourth at 96kHz (~23Hz), against ~47 a
    /// second before. Each publish dropped is a main-actor hop and a SwiftUI
    /// update not made, and fewer updates are calmer too. See
    /// `PublishThrottle`.
    nonisolated static let publishInterval: TimeInterval = 1.0 / 25

    /// How long the wave takes to sink to its silent baseline when playback
    /// pauses, in seconds. Capture stops at once; this only eases the last
    /// published bands down, stepping at `publishInterval` (0.4s is ten
    /// steps). 0 drops the wave in a single frame, as it did before.
    nonisolated static let pauseSettleDuration: TimeInterval = 0.4

    /// The fraction of the paused level still showing `elapsed` seconds into
    /// the settle. An ease-out: quickest at first and gentlest on landing, so
    /// the wave sinks into the baseline rather than stopping against it.
    /// Exactly 0 once `pauseSettleDuration` has passed.
    nonisolated static func settleLevel(after elapsed: TimeInterval) -> Float {
        guard pauseSettleDuration > 0 else { return 0 }
        let remaining = 1 - min(1, max(0, elapsed / pauseSettleDuration))
        return Float(remaining * remaining)
    }

    /// One buffer of bar smoothing: an eased rise at `barAttack`, a slower
    /// fall at `barRelease`. It only ever interpolates between the previous
    /// value and the new one, so it cannot push a band out of range.
    nonisolated static func smoothed(previous: Float, raw: Float) -> Float {
        let keep = raw > previous ? barAttack : barRelease
        return previous * keep + raw * (1 - keep)
    }

    /// Per-frame decay of the ceiling, at roughly 46 buffers a second: about
    /// a four-second fall. The ceiling rises instantly so a transient cannot
    /// clip, and falls slowly so a quiet bar inside a loud track still reads
    /// as quiet rather than being re-normalised to full height a frame later.
    nonisolated static let gainRelease: Float = 0.995

    /// Band energies in dB, before normalisation.
    ///
    /// Split out from `fold` so the adaptive ceiling can read exactly the
    /// numbers the mapping will use, without folding the bins twice.
    nonisolated static func bandDecibels(magnitudes: [Float], into bandCount: Int) -> [Float] {
        guard !magnitudes.isEmpty, bandCount > 0 else {
            return [Float](repeating: -.infinity, count: max(0, bandCount))
        }
        var result = [Float](repeating: -.infinity, count: bandCount)
        let maxBin = Float(magnitudes.count)
        for band in 0..<bandCount {
            let lo = Int(powf(maxBin, Float(band) / Float(bandCount)))
            let hi = max(lo + 1, Int(powf(maxBin, Float(band + 1) / Float(bandCount))))
            let upper = min(hi, magnitudes.count)
            guard lo < upper else { continue }
            var sum: Float = 0
            for bin in lo..<upper { sum += magnitudes[bin] }
            result[band] = 20 * log10f(max(sum / Float(upper - lo), 1e-9))
        }
        return result
    }

    /// Maps band dB to 0...1 against the per-band references, with the whole
    /// set of ceilings shifted by `gain`.
    ///
    /// The references carry the *shape* — the spectral tilt of real music,
    /// which is a property of music and not of level. `gain` carries the
    /// *level*, which is a property of the track's mastering. Separating them
    /// is what lets one mapping serve a quiet recording and a loud one.
    nonisolated static func normalize(bandDecibels: [Float], gain: Float) -> [Float] {
        bandDecibels.enumerated().map { index, db in
            let reference = index < referenceDB.count ? referenceDB[index] : 0
            let ceiling = reference + gain
            return min(1, max(0, (db - (ceiling - dynamicWindow)) / dynamicWindow))
        }
    }

    /// How far the loudest band sits above its own reference this frame.
    /// Negative for quiet material, which is how the ceiling comes back down.
    nonisolated static func excess(bandDecibels: [Float]) -> Float {
        var highest = -Float.infinity
        for (index, db) in bandDecibels.enumerated() where db.isFinite {
            let reference = index < referenceDB.count ? referenceDB[index] : 0
            highest = max(highest, db - reference)
        }
        return highest.isFinite ? highest : minimumGain
    }

    /// Attack instantly, release slowly — the standard shape for anything
    /// that must not clip but also must not pump.
    nonisolated static func updatedGain(current: Float, excess: Float) -> Float {
        let target = max(minimumGain, excess + peakHeadroom)
        guard target <= current else { return target }
        return current * gainRelease + target * (1 - gainRelease)
    }

    /// Folds FFT bins into log-spaced bands, normalised to roughly 0...1
    /// against the static references — i.e. with no adaptive gain.
    ///
    /// Log spacing because linear bins put almost everything musical in the
    /// first band or two. Pure, and on the service rather than the private tap so it is testable.
    nonisolated static func fold(magnitudes: [Float], into bandCount: Int) -> [Float] {
        normalize(bandDecibels: bandDecibels(magnitudes: magnitudes, into: bandCount), gain: 0)
    }

    /// Makes the engine that captures. Injected so tests can run the whole
    /// lifecycle on a fake: no test may open a real system-audio tap.
    typealias CaptureFactory = @MainActor (_ excludedPIDs: [pid_t],
                                           _ onBands: @escaping ([Float]) -> Void)
        -> any AudioCaptureEngine

    /// `makeCapture` is nil in the app, which captures through the real
    /// system-audio tap.
    init(makeCapture: CaptureFactory? = nil) {
        self.makeCapture = makeCapture ?? { SystemAudioTap(excludedPIDs: $0, onBands: $1) }
    }

    // MARK: - Control

    func setEnabled(_ on: Bool) {
        guard on != isEnabled else { return }
        isEnabled = on
        Self.logger.notice("Visualiser \(on ? "enabled" : "disabled", privacy: .public)")
        reconcile()
    }

    /// Whether the spectrum is on screen right now. Called by `MediaModule`, the
    /// only thing that knows: an open panel is not enough. The stats page,
    /// clipboard, shelf and full-lyrics takeover all fill an open panel
    /// without drawing the spectrum, and while this was keyed on the panel,
    /// capture ran behind each of them whenever music played (fixed
    /// 2026-09-16).
    func setSpectrumVisible(_ visible: Bool) {
        guard visible != spectrumVisible else { return }
        spectrumVisible = visible
        reconcile()
    }

    /// Called by the media module whenever the active source's play state
    /// changes. Not a poll: this rides the adapter's existing push updates.
    func setPlaying(_ playing: Bool) {
        guard playing != isPlaying else { return }
        isPlaying = playing
        reconcile()
    }

    /// The processes the tap engine is muting and re-rendering right now,
    /// pushed by `TapEngine` through AppDelegate whenever its legs change.
    ///
    /// They are **excluded** from the tap, which is what makes the spectrum
    /// match what is audible: a tapped app's own stream never reaches the
    /// hardware (`.mutedWhenTapped`), and the copy that does is Astraea's
    /// re-render, already at the slider's gain. Excluding Astraea instead —
    /// the arrangement Phase 0's test G suggested — would remove the
    /// double-count but leave the app's *pre-mute* stream in the tap, so the
    /// bars would read 100% while the user heard 30%.
    ///
    /// A change while capturing rebuilds the tap, because a tap's process
    /// list is fixed at creation: an in-place description edit was measured
    /// to add processes but not remove them (M1, on a mixdown tap), and on
    /// an exclusive tap a failed removal would silently drop an app from the
    /// spectrum for good. A rebuild is the whole capture start, measured at
    /// a 27 ms median across 37 real captures, and only happens when the set
    /// changes mid-capture — which it did not once in three days of use.
    func setTappedProcesses(_ pids: [pid_t]) {
        let next = Array(Set(pids)).sorted()
        guard next != tappedPIDs else { return }
        tappedPIDs = next
        Self.logger.notice("Tapped processes: \(next.map(String.init).joined(separator: ","), privacy: .public)")
        // Not capturing: the next start picks the new list up for free.
        guard capture != nil else { return }
        rebuild(reason: "tapped processes changed")
    }

    /// Tears the current capture down and starts a fresh one, keeping the
    /// bands where they are: nothing about playback changed, only what the
    /// tap is told to exclude (or, for a coreaudiod restart, which objects
    /// exist). Never animates, so hard rule 8 has nothing to answer for.
    private func rebuild(reason: String) {
        guard shouldRun else { return }
        Self.logger.notice("Rebuilding capture (\(reason, privacy: .public))")
        stop(reason: reason)
        start()
    }

    /// coreaudiod restarted: every object ID the engine held is stale and it
    /// has already dropped them, so the only recovery is a fresh capture.
    /// Matches `TapEngine.handleServiceRestarted`. Without this the IOProc
    /// simply stopped being called, with `isRunning` still true and no error
    /// anywhere — the wave froze until the panel was closed and reopened.
    private func handleCaptureInvalidated() {
        guard capture != nil else { return }
        rebuild(reason: "coreaudiod restarted")
    }

    private var shouldRun: Bool { isEnabled && spectrumVisible && isPlaying }

    private func reconcile() {
        if shouldRun {
            if capture == nil { start() }
            return
        }
        if capture != nil { stop(reason: stopReason) }
        // Only a pause sinks: still enabled and on screen, with playback the
        // one condition that stopped. Disabled or off screen, the bands drop
        // at once, cancelling any settle already running.
        if isEnabled && spectrumVisible {
            settle()
        } else {
            rest()
        }
    }

    private var stopReason: String {
        if !isEnabled { return "disabled" }
        if !spectrumVisible { return "spectrum not on screen" }
        return "playback stopped"
    }

    // MARK: - Capture

    private func start() {
        // Resumed mid-settle: the next live publish takes over from wherever
        // the wave had sunk to.
        settleTask?.cancel()
        settleTask = nil
        let engine = makeCapture(tappedPIDs) { [weak self] bands in
            Task { @MainActor in self?.publish(bands) }
        }
        // Synchronous, not a `Task` hop: the listener is registered on the
        // main queue precisely so the rebuild happens in the same turn, with
        // no window where a dead capture looks alive. `assumeIsolated`
        // states that fact to the compiler, and traps if anything ever
        // delivers this from elsewhere.
        engine.onInvalidated = { [weak self] in
            MainActor.assumeIsolated { self?.handleCaptureInvalidated() }
        }
        switch engine.start() {
        case .success:
            capture = engine
            isRunning = true
            lastError = nil
        case .failure(let reason):
            capture = nil
            isRunning = false
            lastError = reason
            // Nothing live will replace whatever a cancelled settle left.
            rest()
            // Authorization shows up here, since the audio-only grant has no
            // preflight. Quiet decline, no retry loop.
            Self.logger.error("Capture failed: \(reason, privacy: .public)")
        }
    }

    /// Tears capture down. Leaves `bands` alone: `reconcile` decides whether
    /// they settle or drop.
    private func stop(reason: String) {
        guard let engine = capture else { return }
        capture = nil
        isRunning = false
        engine.stop()
        Self.logger.notice("Capture stopped (\(reason, privacy: .public))")
    }

    /// Eases the last published bands down to the silent baseline over
    /// `pauseSettleDuration`, one plain band update per `publishInterval`.
    ///
    /// Only this transition moves the wave without audio behind it; there is
    /// still no view animation, so nothing is added to live playback, where
    /// the implicit animation cost 7.6 points of a core (see
    /// `AudioVisualizerSpectrumView`). Bounded, not a poll (hard rule 9): it
    /// ends itself at the baseline, and resuming, disabling, or hiding the
    /// spectrum cancels it. Instant under Reduce Motion (hard rule 8).
    private func settle() {
        guard settleTask == nil else { return }
        let from = bands
        guard from.contains(where: { $0 > 0 }) else { return }
        guard Self.pauseSettleDuration > 0,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            rest()
            return
        }
        Self.logger.notice("Settling to baseline over \(Self.pauseSettleDuration, privacy: .public)s")
        let clock = ContinuousClock()
        let began = clock.now
        settleTask = Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(Self.publishInterval))
                guard !Task.isCancelled, let self else { return }
                let level = Self.settleLevel(after: (clock.now - began) / .seconds(1))
                self.bands = from.map { $0 * level }
                if level == 0 {
                    self.settleTask = nil
                    return
                }
            }
        }
    }

    /// Drops the bands to the silent baseline at once, cancelling any settle.
    private func rest() {
        settleTask?.cancel()
        settleTask = nil
        guard bands.contains(where: { $0 != 0 }) else { return }
        bands = Array(repeating: 0, count: Self.bandCount)
    }

    private func publish(_ newBands: [Float]) {
        guard isRunning else { return }
        bands = newBands
        // Verification logging until a view exists: one line a second, so
        // real audio can be confirmed flowing without a UI.
        let now = Date()
        guard now.timeIntervalSince(lastLogged) >= 1 else { return }
        lastLogged = now
        let rendered = newBands.map { String(format: "%.2f", $0) }.joined(separator: " ")
        Self.logger.notice("bands: \(rendered, privacy: .public)")
    }

    deinit {
        // Nonisolated: hand the engine its own teardown and touch nothing
        // main-actor. Releasing the tap and aggregate device here is what
        // stops a quit from leaving a private aggregate device behind.
        capture?.stop()
    }
}

/// What `AudioVisualizerService` starts and stops. `SystemAudioTap` is the
/// only real one; tests supply a fake, so none of them opens a real tap.
///
/// `nonisolated` for the same reason as `SystemAudioTap` below.
nonisolated protocol AudioCaptureEngine: AnyObject {
    func start() -> AudioCaptureStartResult
    func stop()
    /// Fired when coreaudiod restarts, after the engine has dropped its
    /// now-meaningless object IDs. The service rebuilds; nothing else can,
    /// because a tap, an aggregate and an IOProc ID are all stale at once
    /// and destroying them by ID would act on whatever reused the number.
    ///
    /// **Delivered on the main queue**, which is what lets the service
    /// handle it synchronously.
    var onInvalidated: (() -> Void)? { get set }
}

nonisolated enum AudioCaptureStartResult {
    case success
    /// Why capture could not start, for the log and `lastError`.
    case failure(String)
}

/// Captures system output audio with a Core Audio process tap feeding a
/// private aggregate device, and reduces each buffer to bands.
///
/// The tap is created `.unmuted`: this observes the output, it must never
/// silence what the user is listening to.
///
/// `nonisolated` on purpose: this target sets
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so an unannotated class here
/// would be main-actor isolated — wrong for a type whose work happens on a
/// Core Audio realtime thread and a background analysis queue.
private nonisolated final class SystemAudioTap: AudioCaptureEngine {

    private static let logger = Logger(subsystem: "com.techie.Astraea", category: "AudioViz")

    private let onBands: ([Float]) -> Void
    private let analyzer = AudioAnalyzer()
    /// The FFT runs here, never on the realtime IO thread: the analysis
    /// allocates, and allocating in a Core Audio callback is how you get
    /// dropouts in the audio the user is actually listening to.
    private let analysisQueue = DispatchQueue(label: "com.techie.Astraea.audioviz",
                                              qos: .userInitiated)
    /// Thins publishes to `AudioVisualizerService.publishInterval`. Touched
    /// only on `analysisQueue`, like the analyzer.
    private var throttle = PublishThrottle(interval: AudioVisualizerService.publishInterval)
    /// Where the realtime IO block leaves each buffer, mixed to mono, in
    /// preallocated storage. The IO block never allocates and never
    /// dispatches a closure; it only fills a slot and pokes `wake`.
    private let mailbox = SampleMailbox(slotCapacity: SampleMailbox.defaultSlotCapacity,
                                        slotCount: SampleMailbox.defaultSlotCount)
    /// Gathers mono buffers into whole FFT windows, so analysis does not
    /// depend on the hardware buffer size. Touched only on `analysisQueue`.
    private var accumulator = SampleAccumulator(windowSize: AudioAnalyzer.fftSize)
    /// Whether this capture has logged its first buffer's frame count yet.
    /// Touched only on `analysisQueue`.
    private var loggedBufferSize = false
    /// Signalled from the IO block, drained on `analysisQueue`. A user-data
    /// source merges signals without allocating, unlike `async`, which
    /// heap-allocates a block per buffer on the realtime thread.
    private let wake: DispatchSourceUserDataAdd

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    /// PIDs the tap engine is muting and re-rendering; excluded from the
    /// tap so the spectrum shows the re-render rather than both copies.
    private let excludedPIDs: [pid_t]

    var onInvalidated: (() -> Void)?
    /// The `kAudioHardwarePropertyServiceRestarted` listener, kept so it can
    /// be removed again. Registered on the **main** queue on purpose: this
    /// type's object IDs are touched only from the main actor (the service
    /// starts and stops it there), so a listener on any other queue would be
    /// the one place they raced. The event is rare and the block does three
    /// assignments, so nothing is charged to the main thread in practice.
    private var restartListener: AudioObjectPropertyListenerBlock?

    init(excludedPIDs: [pid_t], onBands: @escaping ([Float]) -> Void) {
        self.excludedPIDs = excludedPIDs
        self.onBands = onBands
        wake = DispatchSource.makeUserDataAddSource(queue: analysisQueue)
        wake.setEventHandler { [weak self] in self?.drainMailbox() }
        // An idle user-data source costs nothing: it fires only when the IO
        // block signals it, so there is nothing here to suspend.
        wake.activate()
    }

    /// Analyses every buffer waiting in the mailbox, oldest first. Runs on
    /// `analysisQueue`, where allocating is fine.
    private func drainMailbox() {
        while let samples = mailbox.read() {
            if !loggedBufferSize {
                // Once per capture, here rather than in the IO block, which
                // must never log. Says whether windows span several buffers.
                loggedBufferSize = true
                Self.logger.notice("First buffer: \(samples.count, privacy: .public) frames (FFT window \(AudioAnalyzer.fftSize, privacy: .public))")
            }
            // Analysed once per full window of new samples: every buffer at
            // 1024 frames or more, so the smoothing keeps its time base, and
            // every second one at 512. Published at most once per
            // `publishInterval`.
            guard let window = accumulator.append(samples),
                  let bands = analyzer.bands(from: window),
                  throttle.admit(at: ProcessInfo.processInfo.systemUptime)
            else { continue }
            onBands(bands)
        }
    }

    /// The tap's stream format, or nil if Core Audio will not say.
    private static func tapFormat(_ tapID: AudioObjectID) -> AudioStreamBasicDescription? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format)
        guard status == noErr else { return nil }
        return format
    }

    func start() -> AudioCaptureStartResult {
        // 1. Tap the global output, minus the processes Astraea is already
        //    muting and re-rendering. Their own streams never reach the
        //    hardware, and our re-render — which is in the tap, because a
        //    global tap includes this process — carries them at the gain the
        //    user set. Excluding them is therefore what makes the spectrum
        //    agree with the room. An app we do not tap is untouched and
        //    stays in at its true level.
        //
        //    A PID with no Core Audio process object cannot be excluded
        //    (Phase 0, A: a process only gets one when it has an audio
        //    path). That app is then double-counted until the next rebuild,
        //    so the count is logged rather than assumed.
        let excluded = excludedPIDs.compactMap { Self.processObject(forPID: $0) }
        if !excludedPIDs.isEmpty {
            Self.logger.notice("Excluding \(excluded.count, privacy: .public) of \(self.excludedPIDs.count, privacy: .public) tapped processes")
        }
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        let tapStatus = AudioHardwareCreateProcessTap(description, &tapID)
        guard tapStatus == noErr else {
            return .failure("Could not create the process tap (\(Self.describe(tapStatus))). System Audio Recording permission is likely not granted.")
        }
        Self.logger.notice("Tap created (id \(self.tapID, privacy: .public))")

        // 1b. What the tap actually delivers. The IO block mixes whatever
        //     channel layout arrives down to mono (it reads each buffer's own
        //     channel count), but it can only read 32-bit float samples, so
        //     any other format is refused rather than analysed as garbage.
        if let format = Self.tapFormat(tapID) {
            let isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
            let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
            Self.logger.notice(
                "Tap format: \(format.mChannelsPerFrame, privacy: .public) ch, \(format.mSampleRate, privacy: .public) Hz, \(format.mBitsPerChannel, privacy: .public)-bit \(isFloat ? "float" : "int", privacy: .public), \(interleaved ? "interleaved" : "non-interleaved", privacy: .public)")
            guard format.mFormatID == kAudioFormatLinearPCM, isFloat, format.mBitsPerChannel == 32 else {
                cleanUp()
                return .failure("The tap delivers a sample format the visualiser cannot read.")
            }
        } else {
            Self.logger.notice("Tap format unavailable; reading the channel layout per buffer")
        }

        // 2. A private aggregate device whose only member is that tap.
        //    Private so it never appears in the user's sound settings.
        let dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Astraea Visualiser",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        let aggStatus = AudioHardwareCreateAggregateDevice(dict as CFDictionary, &aggregateID)
        guard aggStatus == noErr else {
            cleanUp()
            return .failure("Could not create the aggregate device (\(Self.describe(aggStatus))).")
        }
        Self.logger.notice("Aggregate device created (id \(self.aggregateID, privacy: .public))")

        // 3. IO proc: mix the frames to mono into preallocated storage and
        //    signal the analysis queue. No allocation, no closure dispatch,
        //    no lock wait (the mailbox only ever try-locks here), and no
        //    weak-reference load: the block holds the mailbox and the wake
        //    source directly. The stereo tap delivers interleaved L/R; it
        //    used to be read as one mono stream at twice the rate.
        let mailbox = self.mailbox
        let wake = self.wake
        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) {
            _, inputData, _, _, _ in
            let list = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inputData))
            if mailbox.write(list) { wake.add(data: 1) }
        }
        guard ioStatus == noErr, let procID else {
            cleanUp()
            return .failure("Could not create the IO proc (\(Self.describe(ioStatus))).")
        }

        let startStatus = AudioDeviceStart(aggregateID, procID)
        guard startStatus == noErr else {
            cleanUp()
            return .failure("Could not start the device (\(Self.describe(startStatus))). System Audio Recording permission is likely not granted.")
        }
        watchForServiceRestart()
        Self.logger.notice("Capture started (\(AudioVisualizerService.bandCount, privacy: .public) bands, \(AudioAnalyzer.fftSize, privacy: .public)-point FFT)")
        return .success
    }

    /// One listener, for the life of this capture, on the system object's
    /// `ServiceRestarted` property. Not a timer and not a poll (hard rule
    /// 9): it is registered by `start` and removed by `cleanUp`, so nothing
    /// is watching while nobody is looking at the spectrum.
    private func watchForServiceRestart() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyServiceRestarted,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleServiceRestarted()
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
        if status == noErr {
            restartListener = block
        } else {
            // Worth saying out loud: without it, a coreaudiod restart leaves
            // this capture running and silent.
            Self.logger.error("Could not watch for a coreaudiod restart (\(Self.describe(status), privacy: .public))")
        }
    }

    /// Every ID this object holds names something that no longer exists.
    /// Drop them **without** destroy calls — the same rule `TapEngine` keeps
    /// — and hand the rebuild to the service.
    private func handleServiceRestarted() {
        // Idempotent: the block is removed from inside itself, so a second
        // delivery already in flight must not ask for a second rebuild.
        guard tapID != kAudioObjectUnknown || aggregateID != kAudioObjectUnknown
            || procID != nil else { return }
        Self.logger.notice("coreaudiod restarted; dropping stale tap, aggregate and IO proc")
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        removeServiceRestartListener()
        onInvalidated?()
    }

    private func removeServiceRestartListener() {
        guard let restartListener else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyServiceRestarted,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, restartListener)
        self.restartListener = nil
    }

    /// The Core Audio process object for a PID, or nil when the process has
    /// none. Public property, no private API (v1 plan, decision 5).
    private static func processObject(forPID pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var qualifier = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &qualifier, &size, &object)
        guard status == noErr, object != kAudioObjectUnknown else { return nil }
        return object
    }

    func stop() {
        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
        }
        cleanUp()
    }

    /// Torn down in reverse order of creation. Leaving a private aggregate
    /// device or a live tap behind outlives the process's usefulness and is
    /// exactly what "release all resources" means here.
    private func cleanUp() {
        removeServiceRestartListener()
        // `stop()` cleans up and then `deinit` cleans up again, so an
        // unconditional line printed twice per capture and made the log
        // useless for counting them. Say it only when something was really
        // released (fixed 2026-09-19).
        var released = false
        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            released = true
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
            released = true
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
            released = true
        }
        guard released else { return }
        Self.logger.notice("Tap and aggregate device released")
    }

    deinit {
        cleanUp()
        wake.setEventHandler {}
        wake.cancel()
    }

    /// OSStatus as its four-character code when it is one, which is how
    /// Core Audio errors are actually documented.
    private static func describe(_ status: OSStatus) -> String {
        let value = UInt32(bitPattern: status)
        let chars = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xFF) }
        if chars.allSatisfy({ $0 >= 32 && $0 < 127 }) {
            return "'\(String(decoding: chars, as: UTF8.self))' \(status)"
        }
        return "\(status)"
    }
}

/// Windowing, FFT and smoothing. Unchanged from the ScreenCaptureKit
/// version: only the source of the PCM changed.
///
/// `nonisolated` for the same reason as `SystemAudioTap`: it runs on the
/// analysis queue, never on the main actor. Internal rather than private so
/// tests can feed it windows from `SampleAccumulator`.
nonisolated final class AudioAnalyzer {

    /// 1024 samples at 48kHz is ~21ms — fast enough to track a beat, long
    /// enough for usable low-frequency resolution. Independent of the tap's
    /// buffer size: `SampleAccumulator` assembles each window, so smaller
    /// buffers are joined rather than skipped.
    static let fftSize = 1024

    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup?
    private var window: [Float]
    /// Previous frame, for the eased rise and slower fall.
    private var smoothed = [Float](repeating: 0, count: AudioVisualizerService.bandCount)
    /// Adaptive ceiling offset, in dB, tracking recent loudness. Starts at 0
    /// (the static references) and follows the material from there.
    private var gain: Float = 0

    init() {
        log2n = vDSP_Length(log2(Float(Self.fftSize)))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        window = [Float](repeating: 0, count: Self.fftSize)
        // Hann: without a window the FFT of a chopped signal smears energy
        // across every bin and the bands all move together.
        vDSP_hann_window(&window, vDSP_Length(Self.fftSize), Int32(vDSP_HANN_NORM))
    }

    deinit {
        if let fftSetup { vDSP_destroy_fftsetup(fftSetup) }
    }

    func bands(from samples: [Float]) -> [Float]? {
        guard let fftSetup, samples.count >= Self.fftSize else { return nil }

        var windowed = [Float](repeating: 0, count: Self.fftSize)
        samples.withUnsafeBufferPointer { src in
            guard let base = src.baseAddress else { return }
            vDSP_vmul(base, 1, window, 1, &windowed, 1, vDSP_Length(Self.fftSize))
        }

        let half = Self.fftSize / 2
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var magnitudes = [Float](repeating: 0, count: half)

        real.withUnsafeMutableBufferPointer { realPtr in
            imag.withUnsafeMutableBufferPointer { imagPtr in
                guard let realBase = realPtr.baseAddress,
                      let imagBase = imagPtr.baseAddress else { return }
                var split = DSPSplitComplex(realp: realBase, imagp: imagBase)
                windowed.withUnsafeBufferPointer { winPtr in
                    guard let winBase = winPtr.baseAddress else { return }
                    winBase.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(half))
            }
        }

        // Fold once, then let the ceiling follow the same numbers the
        // mapping is about to use.
        let decibels = AudioVisualizerService.bandDecibels(
            magnitudes: magnitudes, into: AudioVisualizerService.bandCount)
        gain = AudioVisualizerService.updatedGain(
            current: gain, excess: AudioVisualizerService.excess(bandDecibels: decibels))
        let raw = AudioVisualizerService.normalize(bandDecibels: decibels, gain: gain)
        // Eased rise, slower fall: see `AudioVisualizerService.barAttack`
        // and `barRelease`.
        for i in smoothed.indices {
            smoothed[i] = AudioVisualizerService.smoothed(previous: smoothed[i], raw: raw[i])
        }
        return smoothed
    }
}

/// Lets a publish through at most once per `interval`, measured from the last
/// one it let through.
///
/// It admits once 90% of the interval has passed rather than all of it.
/// Buffers arrive with a little scheduling jitter, and without that margin a
/// buffer landing a hair early would be held back to the next one, so the
/// stride would flip between two buffers and three and the rate would wobble.
nonisolated struct PublishThrottle {

    let interval: TimeInterval
    private(set) var lastAdmitted: TimeInterval?

    init(interval: TimeInterval) {
        self.interval = interval
    }

    mutating func admit(at now: TimeInterval) -> Bool {
        if let lastAdmitted, now - lastAdmitted < interval * 0.9 {
            return false
        }
        lastAdmitted = now
        return true
    }
}

/// Joins mono buffers into FFT windows on the analysis side of the mailbox,
/// so analysis no longer depends on the hardware buffer size. A 512-frame
/// buffer used to be skipped outright, because the analyser needs a full
/// window and nothing ever assembled one.
///
/// A window is due once `windowSize` new samples have arrived since the last
/// one, and it is always the most recent `windowSize` samples. Buffers of a
/// window or more therefore yield one window each, exactly as before, and
/// smaller ones yield a window every few buffers: never more FFTs than
/// buffers, and never more than one per window of audio.
///
/// Storage is allocated once and only shifted in place afterwards. Not
/// thread-safe: owned by the analysis queue, and never touched by the IO block.
nonisolated struct SampleAccumulator {

    let windowSize: Int
    /// The most recent `windowSize` samples, oldest first.
    private var history: [Float]
    /// Samples received since the last window, capped at `windowSize`.
    private(set) var pending = 0

    init(windowSize: Int) {
        self.windowSize = max(1, windowSize)
        history = [Float](repeating: 0, count: self.windowSize)
    }

    /// Adds one buffer and returns the window to analyse, or nil while a
    /// full window of new samples has not yet arrived.
    mutating func append(_ samples: [Float]) -> [Float]? {
        let size = windowSize
        let count = samples.count
        guard count > 0 else { return nil }
        let incoming = min(count, size)
        let keep = size - incoming
        history.withUnsafeMutableBufferPointer { dst in
            samples.withUnsafeBufferPointer { src in
                guard let dstBase = dst.baseAddress, let srcBase = src.baseAddress else { return }
                // Slide the newest `keep` samples to the front, then append
                // the tail of this buffer behind them. The slide overlaps
                // itself, hence `memmove`.
                if keep > 0 { memmove(dstBase, dstBase + incoming, keep * MemoryLayout<Float>.stride) }
                (dstBase + keep).update(from: srcBase + (count - incoming), count: incoming)
            }
        }
        pending = min(size, pending + count)
        guard pending >= size else { return nil }
        pending = 0
        return history
    }
}

/// Mixes one IO cycle's buffers down to mono. Realtime-safe: no allocation,
/// no locks, no Objective-C.
///
/// Handles both layouts Core Audio can deliver. Interleaved: one buffer
/// whose `mNumberChannels` frames sit side by side (L R L R ...), which is
/// what the stereo global tap produces. Non-interleaved: one buffer per
/// channel. Either way each output frame is the mean of every channel.
nonisolated enum MonoMixdown {

    /// Writes up to `capacity` mono frames into `destination` and returns
    /// how many. Zero when there is nothing readable.
    static func mix(_ list: UnsafeMutableAudioBufferListPointer,
                    into destination: UnsafeMutablePointer<Float>,
                    capacity: Int) -> Int {
        var totalChannels = 0
        var frames = Int.max
        for buffer in list where buffer.mData != nil {
            let channels = max(1, Int(buffer.mNumberChannels))
            totalChannels += channels
            frames = min(frames, Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / channels)
        }
        guard totalChannels > 0, frames != Int.max else { return 0 }
        frames = min(frames, capacity)
        guard frames > 0 else { return 0 }

        destination.update(repeating: 0, count: frames)
        for buffer in list {
            guard let raw = buffer.mData else { continue }
            let channels = max(1, Int(buffer.mNumberChannels))
            let samples = raw.assumingMemoryBound(to: Float.self)
            for frame in 0..<frames {
                let base = frame * channels
                var sum: Float = 0
                for channel in 0..<channels { sum += samples[base + channel] }
                destination[frame] += sum
            }
        }
        let scale = 1 / Float(totalChannels)
        for frame in 0..<frames { destination[frame] *= scale }
        return frames
    }
}

/// A small ring of preallocated mono buffers between the realtime IO thread
/// and the analysis queue.
///
/// The writer is the IO block and only ever *try*-locks: if the reader holds
/// the lock that instant, the buffer is dropped — a visualiser can lose a
/// frame, the user's audio cannot stall. When the ring is full the oldest
/// unread buffer is overwritten. The reader copies a buffer out under the
/// lock and analyses it after releasing it.
nonisolated final class SampleMailbox: @unchecked Sendable {

    /// Mono frames per slot. The tap delivers 1024-frame buffers; this is
    /// headroom for a device that delivers larger ones.
    static let defaultSlotCapacity = 4096
    /// Enough to ride out a briefly busy analysis queue.
    static let defaultSlotCount = 4

    let slotCapacity: Int
    let slotCount: Int
    private let storage: UnsafeMutablePointer<Float>
    private let counts: UnsafeMutablePointer<Int>
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    /// Slots ever written and ever read. Only touched under `lock`.
    private var written = 0
    private var consumed = 0

    init(slotCapacity: Int, slotCount: Int) {
        self.slotCapacity = max(1, slotCapacity)
        self.slotCount = max(1, slotCount)
        storage = .allocate(capacity: self.slotCapacity * self.slotCount)
        storage.initialize(repeating: 0, count: self.slotCapacity * self.slotCount)
        counts = .allocate(capacity: self.slotCount)
        counts.initialize(repeating: 0, count: self.slotCount)
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        storage.deinitialize(count: slotCapacity * slotCount)
        storage.deallocate()
        counts.deinitialize(count: slotCount)
        counts.deallocate()
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    /// Realtime side. Never blocks, never allocates. False when the buffer
    /// was dropped (lock busy) or held nothing readable.
    func write(_ list: UnsafeMutableAudioBufferListPointer) -> Bool {
        guard os_unfair_lock_trylock(lock) else { return false }
        defer { os_unfair_lock_unlock(lock) }
        let slot = written % slotCount
        let frames = MonoMixdown.mix(list, into: storage + slot * slotCapacity,
                                     capacity: slotCapacity)
        guard frames > 0 else { return false }
        counts[slot] = frames
        written += 1
        if written - consumed > slotCount { consumed = written - slotCount }
        return true
    }

    /// Analysis side: the oldest unread buffer, copied out, or nil.
    func read() -> [Float]? {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        guard consumed < written else { return nil }
        let slot = consumed % slotCount
        consumed += 1
        return Array(UnsafeBufferPointer(start: storage + slot * slotCapacity, count: counts[slot]))
    }
}
