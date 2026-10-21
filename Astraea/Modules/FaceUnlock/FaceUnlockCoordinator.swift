// Adapted from Glance (github.com/jonnyoo/glance), MIT, (c) 2026 Jonathan Zhou.
// See THIRD-PARTY-LICENSES.md.

import Foundation
import CoreGraphics
import Observation
import os

/// Face Unlock at the lock screen: when the Mac wakes there, look for an
/// enrolled face for up to 2 minutes, and on a match while the password
/// field is up, type the stored password and Return.
///
/// The coordinator draws nothing itself: its status shows in Settings, and
/// nothing is drawn at the lock screen (a later phase).
///
/// Rules that keep it safe:
/// - Lock and wake notifications are only triggers. Every decision re-reads
///   `LockScreenGuard`, which fails closed, and the typer re-checks it
///   before every key group.
/// - Typing needs the password field focused: secure input on, held by
///   loginwindow. On the account picker a match only holds: the scan goes
///   on, and types on a later match once the field is up.
/// - A scan starts only with the display on, and ends as soon as the display
///   sleeps, the camera stops, or no frame has come for `frameTimeout`.
/// - Only a positive "unlocked" from the session server ends a lock session
///   or counts as success. "Unknown" stops the camera and types nothing, but
///   resets nothing either: not the one-password latch, not the rejection
///   count, not a pending check.
/// - Nothing here prompts, ever: not the owner check, not the keychain, not
///   the camera, not Accessibility (except `requestAccessibility()`, for a
///   Settings button). The password is read only while the session already
///   holds its key in memory.
/// - At most one password is typed per lock session; typing that stopped
///   before its first key event does not count. Two lock sessions in a
///   row in which the typed password did not unlock the Mac pause typing
///   until the password is re-saved or the session is unlocked again, so a
///   stale password cannot run up macOS's failed-login delays.
/// - With liveness on (Light, the default), a match types only while
///   liveness passes: no glare or device rectangle on that face frame or
///   the four counted face frames of the same face before it, and no cue
///   denying (`LivenessEvaluator`).
/// - At most `scanStartsPerLockSession` scans per lock session, so a wake
///   cannot be repeated without limit to give a photo more tries.
/// - No repeating timers: the camera runs only inside one scan, which ends
///   on unlock, sleep, an unknown lock state, the display sleeping, the
///   camera stopping or going silent, disabling, typing, persistent
///   recognition errors, or the `scanCap`; the model and camera are
///   released when the screen unlocks.
/// - Raw similarity scores are logged only at `.debug`; `.notice` lines and
///   Settings show a `SimilarityBand`.
@Observable
@MainActor
final class FaceUnlockCoordinator {

    @ObservationIgnored private static let logger = Logger(subsystem: "com.techie.Astraea", category: "FaceUnlock")

    /// The longest one scan runs. A later wake starts a new one.
    static let scanCap: TimeInterval = 120
    /// Every new frame is checked for this long after a scan starts...
    static let fastPhase: TimeInterval = 5
    /// ...and after it, at most one frame per this long, to save power. The
    /// camera then converts only the frames asked for.
    static let slowFrameInterval: TimeInterval = 0.25
    /// While waiting for a frame, the lock state is re-read at most this
    /// often (and before every frame that is checked).
    static let stateCheckInterval: TimeInterval = 0.25
    /// A scan whose camera sends nothing for this long ends: a closed lid,
    /// or a camera that reports running without frames.
    static let frameTimeout: TimeInterval = 3
    /// One lid-open fires several wake signals; these count as one wake.
    static let wakeDebounce: TimeInterval = 2
    /// How long a wake that could not start a scan yet (display asleep, lock
    /// state unknown) may still start one, once the state allows.
    static let pendingWakeLifetime: TimeInterval = 60
    /// The session server's answer can lag a notification.
    static let settleDelay: TimeInterval = 0.3
    static let frameWait: TimeInterval = 0.02
    static let verifyTimeout: TimeInterval = 4
    /// An unlock seen this soon after Return counts as the typed password
    /// working; one seen later, before `verifyTimeout`, may be the user
    /// typing it by hand, so it neither resets nor adds to the rejection
    /// count. A guess, not yet measured on hardware.
    static let unlockConfirmationWindow: TimeInterval = 2
    static let rejectionsBeforePause = 2
    /// Scans one lock session may start. Each wake gives a 2-minute scan, so
    /// without a cap someone at the lock screen could give a photo or video
    /// as many tries as they liked by closing and opening the lid. 8 is
    /// several wakes more than the owner needs (a match usually takes one),
    /// and caps a lock session at 16 minutes of camera time. Reset when the
    /// screen unlocks or the Face Unlock session is unlocked. Shown as
    /// `.pausedAfterRejections`, the same pause as two rejected passwords.
    static let scanStartsPerLockSession = 8
    /// Recognition errors in a row that end a scan as failed. One error is
    /// a bad frame; this many is a broken model or Vision, which would
    /// otherwise scan blind for the whole 2 minutes.
    static let recognitionErrorLimit = 5

    // MARK: - Observable state for Settings

    private(set) var status: FaceUnlockStatus = .disabled {
        didSet {
            guard status != oldValue else { return }
            Self.logger.notice("Status: \(String(describing: self.status), privacy: .public)")
        }
    }
    private(set) var lastOutcome: FaceUnlockOutcome?
    private(set) var lastOutcomeAt: Date?
    /// The best similarity seen in the last scan. In memory only, never
    /// shown or logged above `.debug`: Settings shows `lastBestBand`.
    private(set) var lastBestSimilarity: Float?
    /// Where the last scan's best similarity fell against its threshold, to
    /// help pick a threshold without showing the score.
    private(set) var lastBestBand: SimilarityBand?
    /// In memory only: a relaunch starts from zero.
    private(set) var consecutiveRejections = 0
    private(set) var isAccessibilityTrusted: Bool
    private(set) var cameraPermission: CameraPermission {
        didSet {
            guard cameraPermission != oldValue else { return }
            Self.logger.notice("Camera permission: \(String(describing: oldValue), privacy: .public) -> \(String(describing: self.cameraPermission), privacy: .public)")
        }
    }

    var isEnabled: Bool { settings.settings.faceUnlockAtLockScreenEnabled }

    // MARK: - Dependencies

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let session: FaceUnlockSession
    @ObservationIgnored private let faceStore: FaceEnrollmentStore
    @ObservationIgnored private let passwordStore: FacePasswordStore
    @ObservationIgnored private let environment: FaceUnlockEnvironment
    private var lockGuard: any LockScreenGuard { environment.lockGuard }
    @ObservationIgnored let loginPrompt: FaceUnlockLoginPrompt

    // MARK: - Internal state

    @ObservationIgnored private var isActive = false
    @ObservationIgnored private var isSleeping = false
    /// Read by tests.
    @ObservationIgnored private(set) var lockSessionActive = false
    @ObservationIgnored private var injectedThisLockSession = false
    /// Scans started this lock session, against `scanStartsPerLockSession`.
    /// Read by tests.
    @ObservationIgnored private(set) var scansThisLockSession = 0
    @ObservationIgnored private var awaitingVerification = false
    /// When Return was pressed, on the coordinator's clock.
    @ObservationIgnored private var verifyStartedAt: TimeInterval?
    /// Bumped as each lock session begins, so typing that finishes after its
    /// lock session ended cannot be checked against the next one.
    @ObservationIgnored private var lockSessionID = 0
    /// When the wake that should start a scan arrived; nil when none is
    /// waiting. Kept through an unknown lock state or a display still
    /// asleep, for `pendingWakeLifetime`.
    @ObservationIgnored private var pendingWakeAt: TimeInterval?
    @ObservationIgnored private var lastWakeAt: TimeInterval?
    @ObservationIgnored private var lastSessionState: FaceUnlockSession.State
    @ObservationIgnored private var lastSaveCount: Int
    /// Bumped by every scan start and cancel. A superseded cycle still runs
    /// to its end (cancellation is cooperative), and must not stop the
    /// newer cycle's camera when it gets there.
    @ObservationIgnored private var scanGeneration = 0
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var settleTask: Task<Void, Never>?
    @ObservationIgnored private var settleToken = 0
    @ObservationIgnored private var verifyTask: Task<Void, Never>?
    /// Re-reads an unknown lock state a few times, so a lock session whose
    /// unlock was never positively seen still ends. Bounded one-shots, not a
    /// repeating timer.
    @ObservationIgnored private var unknownRecheckTask: Task<Void, Never>?
    @ObservationIgnored private var unknownRechecks = 0
    /// Measured 2026-10-15 on macOS 27.0.1: after an unlock the session
    /// server answered "unknown" for over 3 s, and no further event arrived
    /// to ask again.
    static let unknownRecheckDelays: [TimeInterval] = [1, 3, 10, 30]
    @ObservationIgnored private var preloadTask: Task<Void, Never>?
    /// Created on a lock session's first scan, released when it ends.
    @ObservationIgnored private var frameSource: (any FaceFrameSource)?
    @ObservationIgnored private var recognizer: (any FaceScanRecognizing)?

    init(settings: SettingsStore, session: FaceUnlockSession, faceStore: FaceEnrollmentStore,
         passwordStore: FacePasswordStore, environment: FaceUnlockEnvironment? = nil) {
        // Built here rather than as a default argument, which would run
        // outside the main actor.
        let environment = environment ?? .live()
        self.settings = settings
        self.session = session
        self.faceStore = faceStore
        self.passwordStore = passwordStore
        self.environment = environment
        self.isAccessibilityTrusted = environment.accessibility.isTrusted()
        self.cameraPermission = environment.cameraPermission()
        self.lastSessionState = session.state
        self.lastSaveCount = passwordStore.saveCount
        self.loginPrompt = FaceUnlockLoginPrompt(
            session: session, lockGuard: environment.lockGuard, clock: environment.clock,
            isEnabled: { [settings] in settings.settings.faceUnlockAtLockScreenEnabled },
            autoLockInterval: { [settings] in settings.settings.faceUnlockAutoLockInterval },
            hasStoredPassword: { [passwordStore] in
                FileManager.default.fileExists(atPath: passwordStore.fileURL.path)
            })
        environment.lockEvents.onEvent = { [weak self] event in self?.handle(event) }
        observe()
    }

    // MARK: - Settings API

    /// Shows the system Accessibility prompt. Only from a Settings button.
    func requestAccessibility() {
        environment.accessibility.requestTrust()
        refreshPermissions()
    }

    /// The Settings Camera row's button: the system prompt if the camera was
    /// never asked for, else System Settings, whose answer the row reads
    /// when the user comes back to Astraea. Only from that button.
    func requestCameraAccess() async {
        let before = environment.cameraPermission()
        guard let action = before.grantAction else { return }
        Self.logger.notice("Camera Grant Access tapped (\(String(describing: before), privacy: .public)): \(String(describing: action), privacy: .public)")
        switch action {
        case .request:
            await environment.requestCameraAccess()
            refreshPermissions()
            Self.logger.notice("Camera permission after the prompt: \(String(describing: self.cameraPermission), privacy: .public)")
        case .openSystemSettings:
            environment.openCameraSettings()
        }
    }

    /// Re-reads Accessibility and the camera, neither of which notifies on
    /// change. Never prompts.
    func refreshPermissions() {
        isAccessibilityTrusted = environment.accessibility.isTrusted()
        cameraPermission = environment.cameraPermission()
        refreshStatus()
    }

    /// At launch: restore the session left unlocked by the last run, or else
    /// "ask once after login". The caller (AppDelegate) skips it under XCTest.
    func scheduleLoginPrompt() {
        guard isEnabled else { return }
        loginPrompt.schedule()
    }

    // MARK: - Observation

    /// Observation fires once per registration, so it re-registers on each
    /// change.
    private func observe() {
        withObservationTracking {
            _ = settings.settings.faceUnlockAtLockScreenEnabled
            _ = session.state
            _ = faceStore.state
            _ = faceStore.identities
            _ = passwordStore.hasStoredPassword
            _ = passwordStore.saveCount
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observe() }
        }
        apply()
    }

    private func apply() {
        if isEnabled != isActive {
            isEnabled ? activate() : deactivate()
        }
        if session.state != lastSessionState {
            let becameUnlocked = session.state == .unlocked && lastSessionState != .unlocked
            lastSessionState = session.state
            if becameUnlocked {
                resetRejections(reason: "session unlocked")
                resetScanStarts(reason: "session unlocked")
                // While the user is here, so the lock screen never needs the
                // keychain for the faces.
                preloadFacesIfSafe()
            }
        }
        if passwordStore.saveCount != lastSaveCount {
            lastSaveCount = passwordStore.saveCount
            resetRejections(reason: "password re-saved")
        }
        refreshStatus()
    }

    private func activate() {
        isActive = true
        environment.lockEvents.start()
        refreshPermissions()
        preloadFacesIfSafe()
        Self.logger.notice("Lock-screen Face Unlock enabled")
        evaluate()
    }

    private func deactivate() {
        isActive = false
        environment.lockEvents.stop()
        settleTask?.cancel()
        settleTask = nil
        cancelUnknownRechecks()
        cancelScan(reason: "disabled")
        verifyTask?.cancel()
        verifyTask = nil
        awaitingVerification = false
        verifyStartedAt = nil
        pendingWakeAt = nil
        lockSessionActive = false
        injectedThisLockSession = false
        scansThisLockSession = 0
        releaseScanResources()
        Self.logger.notice("Lock-screen Face Unlock disabled")
    }

    // MARK: - Events

    private func handle(_ event: LockEvent) {
        guard isActive else { return }
        Self.logger.notice("Lock event: \(String(describing: event), privacy: .public)")
        switch event {
        case .sleep:
            isSleeping = true
            pendingWakeAt = nil
            // The debounce only merges the signals of one wake; the next
            // wake after a sleep is a new one, however soon it comes.
            lastWakeAt = nil
            cancelScan(reason: "sleep")
        case .wake:
            isSleeping = false
            let now = environment.clock.now()
            if let lastWakeAt, now - lastWakeAt < Self.wakeDebounce {
                Self.logger.notice("Wake debounced")
                return
            }
            lastWakeAt = now
            pendingWakeAt = now
            scheduleEvaluation()
        case .screenLocked:
            loginPrompt.screenDidLock()
            scheduleEvaluation()
        case .screenUnlocked:
            scheduleEvaluation()
        }
    }

    /// Re-derives the state a moment after the latest event. Flags carry
    /// what the event meant, so a newer event replacing the wait loses
    /// nothing.
    private func scheduleEvaluation() {
        settleTask?.cancel()
        settleToken &+= 1
        let token = settleToken
        settleTask = Task { [weak self] in
            guard let self else { return }
            await self.environment.clock.sleep(for: Self.settleDelay)
            guard !Task.isCancelled, token == self.settleToken else { return }
            self.settleTask = nil
            self.evaluate()
        }
    }

    private func evaluate() {
        guard isActive else { return }
        let state = lockGuard.currentState()
        if state != .unknown { cancelUnknownRechecks() }
        switch state {
        case .locked: break
        case .unlocked: return endLockSession()
        case .unknown: return suspendForUnknownState()
        }
        if !lockSessionActive {
            lockSessionActive = true
            lockSessionID &+= 1
            Self.logger.notice("Lock session began")
        }
        guard let wakeAt = pendingWakeAt else { return refreshStatus() }
        guard environment.clock.now() - wakeAt <= Self.pendingWakeLifetime else {
            pendingWakeAt = nil
            Self.logger.notice("Pending wake expired without a scan")
            return refreshStatus()
        }
        guard !isSleeping else {
            pendingWakeAt = nil
            Self.logger.notice("Wake ignored: the Mac is going to sleep")
            return
        }
        guard !lockGuard.isMainDisplayAsleep() else {
            // The camera never runs with the display off. The wake stays
            // pending, and the display's own wake signal is let through the
            // debounce to start the scan.
            lastWakeAt = nil
            Self.logger.notice("Scan waiting: the display is asleep")
            return refreshStatus()
        }
        pendingWakeAt = nil
        startScanIfAllowed(trigger: "wake", wakeAt: wakeAt)
    }

    /// Only on a positive `.unlocked`: the one place a lock session ends.
    private func endLockSession() {
        pendingWakeAt = nil
        cancelScan(reason: "screen unlocked")
        if awaitingVerification { finishVerification(verdictForObservedUnlock()) }
        if lockSessionActive {
            lockSessionActive = false
            Self.logger.notice("Lock session ended (unlocked)")
        }
        injectedThisLockSession = false
        resetScanStarts(reason: "screen unlocked")
        releaseScanResources()
        loginPrompt.screenDidUnlock()
        refreshStatus()
    }

    /// The session server gave no usable answer. Fail closed: no camera, no
    /// typing. Fail closed also means no reset: the lock session,
    /// the one-password latch, the rejection count, any pending check and
    /// any pending wake stay as they are until a positive answer. A recheck
    /// that reads "locked" then starts the pending wake's scan, through
    /// `evaluate()` and every gate again.
    private func suspendForUnknownState() {
        cancelScan(reason: "lock state unknown")
        releaseScanResources()
        Self.logger.notice("Lock state unknown (\(self.lockGuard.unknownReason(), privacy: .public)): scanning suspended; lock session\(self.lockSessionActive ? "" : " (none)", privacy: .public) and counters kept")
        scheduleUnknownRecheck()
        refreshStatus()
    }

    private func scheduleUnknownRecheck() {
        unknownRecheckTask?.cancel()
        unknownRecheckTask = nil
        guard unknownRechecks < Self.unknownRecheckDelays.count else {
            Self.logger.notice("Lock state still unknown; waiting for the next lock event")
            return
        }
        let delay = Self.unknownRecheckDelays[unknownRechecks]
        unknownRechecks += 1
        unknownRecheckTask = Task { [weak self] in
            guard let self else { return }
            await self.environment.clock.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self.unknownRecheckTask = nil
            self.evaluate()
        }
    }

    private func cancelUnknownRechecks() {
        unknownRecheckTask?.cancel()
        unknownRecheckTask = nil
        unknownRechecks = 0
    }

    // MARK: - Gates

    private var enabledIdentities: [FaceIdentity] {
        faceStore.identities.filter { $0.isEnabled && !$0.isStale }
    }

    /// The first reason a scan cannot run, or nil. Reads only cached state
    /// and file existence: nothing here prompts or touches the keychain.
    private func gateBlocker() -> FaceUnlockStatus? {
        guard isEnabled else { return .disabled }
        switch session.state {
        case .unlocked: break
        case .keyMissing: return .faceDataNotReady
        case .locked, .unlocking: return .sessionLocked
        }
        guard FileManager.default.fileExists(atPath: passwordStore.fileURL.path) else { return .noStoredPassword }
        guard session.hasKeyInMemory else { return .faceDataNotReady }
        guard consecutiveRejections < Self.rejectionsBeforePause else { return .pausedAfterRejections }
        // No new status case: the same pause, lifted by an unlock.
        guard !scanStartsExhausted else { return .pausedAfterRejections }
        guard faceStore.state == .ready else { return .faceDataNotReady }
        guard !enabledIdentities.isEmpty else {
            let onButStale = faceStore.identities.contains { $0.isEnabled && $0.isStale }
            return onButStale ? .enrolledFacesNeedRecapture : .noEnrolledFace
        }
        guard isAccessibilityTrusted else { return .accessibilityNeeded }
        switch cameraPermission {
        case .granted: break
        case .notDetermined: return .cameraNotYetRequested
        case .denied, .restricted: return .cameraNotAuthorized
        }
        return nil
    }

    private func refreshStatus() {
        guard scanTask == nil, !awaitingVerification else { return }
        status = gateBlocker() ?? (consecutiveRejections > 0 ? .passwordRejected : .ready)
    }

    /// Decrypts the faces only when that cannot prompt: the owner is
    /// verified and the key is already in memory. Checked here and again by
    /// the store when the task runs, since the session can lock in between.
    private func preloadFacesIfSafe() {
        guard isActive, preloadTask == nil, faceStore.state == .locked,
              session.isUnlocked, session.hasKeyInMemory else { return }
        Self.logger.notice("Loading face data for the lock screen")
        preloadTask = Task { [weak self] in
            guard let self else { return }
            await self.faceStore.unlock(prompting: false)
            self.preloadTask = nil
            self.refreshStatus()
        }
    }

    private func resetRejections(reason: String) {
        guard consecutiveRejections > 0 else { return }
        consecutiveRejections = 0
        Self.logger.notice("Password rejection count reset: \(reason, privacy: .public)")
    }

    /// The lock session has used up its scans (H2).
    private var scanStartsExhausted: Bool {
        lockSessionActive && scansThisLockSession >= Self.scanStartsPerLockSession
    }

    private func resetScanStarts(reason: String) {
        guard scansThisLockSession > 0 else { return }
        let wasExhausted = scansThisLockSession >= Self.scanStartsPerLockSession
        scansThisLockSession = 0
        if wasExhausted {
            Self.logger.notice("Scan limit lifted: \(reason, privacy: .public)")
        }
    }

    /// `wakeAt` is the wake that asked for the scan, on the coordinator's
    /// clock, for the wake-to-liveness timing in the log.
    private func startScanIfAllowed(trigger: String, wakeAt: TimeInterval) {
        guard scanTask == nil else {
            Self.logger.notice("Scan not restarted (\(trigger, privacy: .public)): one is already running")
            return
        }
        guard !injectedThisLockSession else {
            Self.logger.notice("Scan refused (\(trigger, privacy: .public)): the password was already typed this lock session")
            return
        }
        isAccessibilityTrusted = environment.accessibility.isTrusted()
        cameraPermission = environment.cameraPermission()
        if let blocker = gateBlocker() {
            let limit = blocker == .pausedAfterRejections && scanStartsExhausted
                ? " (\(scansThisLockSession) scans this lock session, the limit)" : ""
            Self.logger.notice("Scan refused (\(trigger, privacy: .public)): \(String(describing: blocker), privacy: .public)\(limit, privacy: .public)")
            status = blocker
            if blocker == .faceDataNotReady { preloadFacesIfSafe() }
            return
        }
        let threshold = settings.settings.faceUnlockMatchThreshold
        let liveness = settings.settings.faceUnlockLiveness
        let identities = enabledIdentities
        scanGeneration &+= 1
        let generation = scanGeneration
        scansThisLockSession += 1
        status = .scanning
        Self.logger.notice("Scan started (\(trigger, privacy: .public)), threshold \(threshold.rawValue, privacy: .public), liveness \(liveness.rawValue, privacy: .public), scan \(self.scansThisLockSession, privacy: .public) of \(Self.scanStartsPerLockSession, privacy: .public) this lock session")
        if scansThisLockSession >= Self.scanStartsPerLockSession {
            Self.logger.notice("Scan limit reached: this is the last scan until the screen unlocks")
        }
        let request = ScanRequest(identities: identities, threshold: threshold.value, liveness: liveness, wakeAt: wakeAt)
        scanTask = Task { [weak self] in
            await self?.runScanCycle(generation: generation, request: request)
        }
    }

    // MARK: - Scan

    private func cancelScan(reason: String) {
        guard scanTask != nil else { return }
        scanGeneration &+= 1
        scanTask?.cancel()
        scanTask = nil
        frameSource?.stop()
        Self.logger.notice("Scan cancelled: \(reason, privacy: .public)")
        refreshStatus()
    }

    private func releaseScanResources() {
        frameSource?.stop()
        if frameSource != nil || recognizer != nil {
            Self.logger.notice("Camera and face model released")
        }
        frameSource = nil
        recognizer = nil
    }

    /// What a scan looks for, fixed when it starts: a settings change applies
    /// from the next scan.
    private struct ScanRequest {
        let identities: [FaceIdentity]
        let threshold: Float
        let liveness: FaceLivenessLevel
        let wakeAt: TimeInterval
    }

    private func runScanCycle(generation: Int, request: ScanRequest) async {
        defer {
            if generation == scanGeneration {
                scanTask = nil
                refreshStatus()
            }
        }
        if let stop = lockScreenStop() {
            Self.logger.notice("Scan not run: \(String(describing: stop), privacy: .public)")
            return
        }

        // Read, never requested: `FaceCamera.start()` would ask if undetermined.
        guard environment.cameraPermission() == .granted else {
            record(.failed("camera access is off"))
            return
        }
        // A lock session's first scan loads the model (about 60 ms cold) off
        // the main actor while the camera starts and warms up, rather than
        // before it.
        async let loading = Self.loadRecognizer(environment.makeRecognizer, needed: recognizer == nil)
        let camera = frameSource ?? environment.makeFrameSource()
        frameSource = camera
        await camera.start()
        let loaded = await loading
        // A newer cycle or a cancel owns the camera now; leave it alone.
        guard generation == scanGeneration else { return }
        switch loaded {
        case .success(let loadedRecognizer)?:
            recognizer = loadedRecognizer
            Self.logger.notice("Face model loaded")
        case .failure(let error)?:
            Self.logger.error("Face model failed to load: \(error.localizedDescription, privacy: .public)")
            camera.stop()
            record(.failed(error.localizedDescription))
            return
        case nil:
            break
        }
        guard let recognizer else {
            camera.stop()
            return
        }
        guard camera.isRunning else {
            let reason = camera.errorMessage ?? "the camera did not start"
            Self.logger.error("Scan ended: \(reason, privacy: .public)")
            camera.stop()
            record(.failed(reason))
            return
        }

        let result = await observeScan(generation: generation, camera: camera, recognizer: recognizer,
                                       request: request)
        // Before the generation check: a scan cancelled by sleep or
        // superseded still gets its numbers in the log.
        logScanSummary(result)
        guard generation == scanGeneration else { return }
        camera.stop()
        lastBestSimilarity = result.bestSimilarity
        lastBestBand = result.frames.bestBand
        let best = result.frames.bestBand?.title ?? "none"
        Self.logger.notice("Scan ended: \(String(describing: result.outcome), privacy: .public), best similarity \(best, privacy: .public)")
        // A match liveness refused, in a scan that then ran to the cap with
        // that denial never cleared. Other endings record what they did
        // before liveness; the summary above still logs the blocked matches.
        let deniedCue = result.liveness?.lastBlockingCue

        switch result.outcome {
        case .matched: await injectPassword(generation: generation)
        case .capReached:
            Self.logger.notice("Scan stopped: 2-minute cap")
            record(deniedCue.map { .livenessDenied($0) } ?? .scanCapReached)
        case .noFrames:
            record(.failed("the camera sent no picture for \(Int(Self.frameTimeout)) seconds"))
        case .cameraStopped where !lockGuard.isMainDisplayAsleep():
            record(.failed(camera.errorMessage ?? "the camera stopped"))
        case .recognitionFailed(let reason):
            record(.failed("face recognition failed: \(reason)"))
        case .lockStateChanged:
            // Re-derived like any event: "unlocked" ends the lock session,
            // "unknown" suspends and schedules the rechecks.
            scanTask = nil
            evaluate()
        case .cameraStopped, .displayAsleep, .cancelled: break
        }
    }

    private enum ScanOutcome {
        case matched, capReached, cancelled
        /// The session server no longer says "locked": unlocked or unknown.
        case lockStateChanged
        case displayAsleep
        case cameraStopped
        /// Nothing new from the camera for `frameTimeout`.
        case noFrames
        /// `recognitionErrorLimit` recognition errors in a row; the first
        /// error's description.
        case recognitionFailed(String)
    }

    /// The model, loaded off the main actor; nil when one is already held.
    private nonisolated static func loadRecognizer(
        _ make: @escaping @Sendable () throws -> any FaceScanRecognizing, needed: Bool
    ) async -> Result<any FaceScanRecognizing, any Error>? {
        guard needed else { return nil }
        return await Task.detached(priority: .userInitiated) {
            Result { try make() }
        }.value
    }

    private struct ScanResult {
        let outcome: ScanOutcome
        let bestSimilarity: Float?
        let frames: ScanFrameStats
        /// Seconds from the camera starting to the scan's end.
        let elapsed: TimeInterval
        /// nil with liveness off.
        let liveness: LivenessScanStats?
    }

    /// One `.notice` line per scan that saw the camera, however it ended:
    /// the frame cadence and similarities, and with liveness on, the cues.
    private func logScanSummary(_ result: ScanResult) {
        let outcome = String(describing: result.outcome)
        let frames = result.frames.summary(elapsed: result.elapsed)
        // Raw scores only at `.debug`, which is not kept (L6).
        Self.logger.debug("Scan similarities (\(outcome, privacy: .public)): \(result.frames.similarityDetail, privacy: .public)")
        if let stats = result.liveness {
            Self.logger.notice("Liveness summary (\(outcome, privacy: .public)): \(frames, privacy: .public); \(stats.summary, privacy: .public)")
        } else {
            Self.logger.notice("Scan summary (\(outcome, privacy: .public), liveness off): \(frames, privacy: .public)")
        }
    }

    /// One scan's liveness: the evaluator, the numbers for the summary, and
    /// what has been logged.
    private struct ScanLiveness {
        var evaluator: LivenessEvaluator
        var stats = LivenessScanStats()
        let wakeAt: TimeInterval
        let startedAt: TimeInterval
        var lastDecision: LivenessDecision = .pending
        /// A blocked match is logged once per denial, not once per frame.
        var blockLogged = false
        var isOn: Bool { evaluator.level != .off }
    }

    /// Why a scan must not run on, or nil: the lock state, then the display.
    private func lockScreenStop() -> ScanOutcome? {
        guard lockGuard.isAtLockScreen() else { return .lockStateChanged }
        guard !lockGuard.isMainDisplayAsleep() else { return .displayAsleep }
        return nil
    }

    /// One continuous scan, bounded by `scanCap` (rule 9): it ends on a
    /// cancel (unlock, sleep, unknown state, disabling), on leaving the lock
    /// screen, on the display sleeping, on the camera stopping or sending
    /// nothing for `frameTimeout`, on a match the password field can take,
    /// or at the cap. New frames are polled every 20 ms; for the first
    /// `fastPhase` every one is checked, then at most one per
    /// `slowFrameInterval`, and the camera converts only those. The lock
    /// state is read before each checked frame, and while waiting at most
    /// once per `stateCheckInterval`.
    ///
    /// With liveness on, every face frame, matched or not, also feeds the
    /// liveness window, and a match types only while liveness passes. A
    /// denial blocks typing but not the scan, so the owner can recover once
    /// the window clears.
    private func observeScan(generation: Int, camera: any FaceFrameSource,
                             recognizer: any FaceScanRecognizing,
                             request: ScanRequest) async -> ScanResult {
        let clock = environment.clock
        let startedAt = clock.now()
        let deadline = startedAt + Self.scanCap
        let identities = request.identities, threshold = request.threshold
        // A fresh evaluator per scan: no denial or clean run carries over.
        var liveness = ScanLiveness(evaluator: LivenessEvaluator(level: request.liveness, threshold: threshold),
                                    wakeAt: request.wakeAt, startedAt: startedAt)
        let sampler: (any LivenessSampling)? = liveness.isOn ? environment.livenessSampler : nil
        var heldForPasswordField = false
        var lastFrameID: UInt64?
        var lastFrameAt = startedAt
        /// nil: read the lock state before the next frame.
        var lastStateCheckAt: TimeInterval?
        var best: Float?
        var frames = ScanFrameStats(threshold: threshold)
        var recognitionErrors = 0
        var firstRecognitionError: String?
        func end(_ outcome: ScanOutcome) -> ScanResult {
            ScanResult(outcome: outcome, bestSimilarity: best, frames: frames, elapsed: clock.now() - startedAt,
                       liveness: liveness.isOn ? liveness.stats : nil)
        }
        camera.setConvertsEveryFrame(true)

        while clock.now() < deadline {
            guard generation == scanGeneration, !Task.isCancelled else { return end(.cancelled) }
            guard camera.isRunning else {
                Self.logger.notice("Scan ended: the camera stopped")
                return end(.cameraStopped)
            }
            let now = clock.now()
            if lastStateCheckAt.map({ now - $0 >= Self.stateCheckInterval }) ?? true {
                lastStateCheckAt = now
                if let stop = lockScreenStop() { return end(stop) }
            }
            // Bounded by construction: the camera keeps only its latest frame
            // and this loop reads that one slot, one frame at a time. A frame
            // that arrives while one is being checked replaces the previous
            // one there; nothing queues behind the check.
            guard let frame = camera.currentFrame, frame.id != lastFrameID else {
                guard now - lastFrameAt < Self.frameTimeout else {
                    Self.logger.notice("Scan ended: no camera frame for \(Int(Self.frameTimeout), privacy: .public) s")
                    return end(.noFrames)
                }
                await clock.sleep(for: Self.frameWait)
                continue
            }
            lastFrameID = frame.id
            lastFrameAt = now
            lastStateCheckAt = nil

            let evaluation = await Task.detached(priority: .userInitiated) {
                FrameEvaluation.evaluate(frame, recognizer: recognizer, sampler: sampler,
                                         identities: identities, threshold: threshold)
            }.value
            frames.recordChecked(recognitionSeconds: evaluation.recognitionSeconds)
            guard generation == scanGeneration, !Task.isCancelled else { return end(.cancelled) }

            if let error = evaluation.recognitionError {
                recognitionErrors += 1
                if firstRecognitionError == nil {
                    firstRecognitionError = error
                    Self.logger.error("Face recognition failed on a frame: \(error, privacy: .public)")
                }
                guard recognitionErrors < Self.recognitionErrorLimit else {
                    Self.logger.notice("Scan ended: \(recognitionErrors, privacy: .public) recognition errors in a row")
                    return end(.recognitionFailed(firstRecognitionError ?? error))
                }
                await pace(camera, since: startedAt)
                continue
            }
            recognitionErrors = 0

            // A match counts only from this frame: a wrong face or no face
            // just keeps scanning, and nothing latched is handed to whoever
            // is next.
            var matchedThisFrame = false
            if let face = evaluation.face {
                if let similarity = face.similarity { best = max(best ?? similarity, similarity) }
                matchedThisFrame = face.matched
                frames.recordFace(similarity: face.similarity, matched: face.matched, after: clock.now() - startedAt)
                if let measured = face.liveness {
                    observeLiveness(&liveness, measured, similarity: face.similarity, matched: face.matched)
                }
            }
            if matchedThisFrame && livenessAllowsTyping(&liveness) {
                // Held only when the password field is all that is missing
                // (the account picker, or the field not up yet). Anything
                // else goes on to the typing checks, which refuse it.
                guard lockGuard.mayType() || !lockGuard.isAwakeAtLockScreen() else {
                    if !heldForPasswordField {
                        heldForPasswordField = true
                        Self.logger.notice("Typing held: no password field (\(self.lockGuard.secureInputSummary(), privacy: .public))")
                    }
                    await pace(camera, since: startedAt)
                    continue
                }
                return end(.matched)
            }
            await pace(camera, since: startedAt)
        }
        return end(.capReached)
    }

    /// Feeds one face frame to the liveness window. Transitions are logged
    /// at `.notice`; the per-frame cue values only at `.debug`.
    private func observeLiveness(_ liveness: inout ScanLiveness, _ measured: MeasuredLiveness,
                                 similarity: Float?, matched: Bool) {
        let decision = liveness.evaluator.observe(measured.sample, similarity: similarity, matched: matched)
        let evaluator = liveness.evaluator
        liveness.stats.record(measured.sample, tripped: evaluator.latestTrips, seconds: measured.seconds)
        let glare = evaluator.latestReadings[.glossGlare] ?? .none
        let device = evaluator.latestReadings[.deviceDetected] ?? .none
        // Formatted by os.Logger only when debug logging is on.
        let milliseconds = measured.seconds * 1000
        let neutral = evaluator.latestAbstained ? ", neutral (a cue unsure)" : ""
        Self.logger.debug("Liveness face frame \(evaluator.faceFrames, privacy: .public)\(matched ? " (match)" : "", privacy: .public), \(evaluator.latestBand.rawValue, privacy: .public), clean run \(evaluator.cleanRun, privacy: .public)\(neutral, privacy: .public): glare \(glare.level, format: .fixed(precision: 3), privacy: .public) (confidence \(glare.confidence, format: .fixed(precision: 2), privacy: .public), \(evaluator.trips(.glossGlare), privacy: .public) tripped), device \(device.level, format: .fixed(precision: 2), privacy: .public) (confidence \(device.confidence, format: .fixed(precision: 0), privacy: .public), \(evaluator.trips(.deviceDetected), privacy: .public) tripped), \(milliseconds, format: .fixed(precision: 1), privacy: .public) ms")

        let previous = liveness.lastDecision
        guard decision != previous else { return }
        liveness.lastDecision = decision
        switch decision {
        case .denied(let cue):
            liveness.stats.denials += 1
            liveness.blockLogged = false
            let reading = evaluator.latestReadings[cue] ?? .none
            var detail = String(format: "level %.3f (fires at %.2f)", reading.level, evaluator.tuning.level(for: cue))
            if cue == .deviceDetected, let device = measured.sample.device {
                detail += String(format: ", rectangle %.1fx the face", device.areaRatio)
            }
            Self.logger.notice("Liveness denied by \(cue.title, privacy: .public): \(detail, privacy: .public), tripped on \(evaluator.trips(cue), privacy: .public) of the last \(min(evaluator.window.count, evaluator.tuning.windowFrames), privacy: .public) face frames (face frame \(evaluator.faceFrames, privacy: .public))")
        case .passed:
            let now = environment.clock.now()
            let timing = String(format: "%.2f s after the wake, %.2f s after the camera started",
                                now - liveness.wakeAt, now - liveness.startedAt)
            let cleared = if case .denied = previous { " (a denial cleared)" } else { "" }
            liveness.stats.lastBlockingCue = nil
            Self.logger.notice("Liveness passed\(cleared, privacy: .public) on face frame \(evaluator.faceFrames, privacy: .public): this frame matched, and the last \(evaluator.cleanRun, privacy: .public) counted face frames of this face were clean (\(evaluator.tuning.cleanFrames, privacy: .public) needed): \(timing, privacy: .public)")
        case .pending:
            if case .denied(let cue) = previous {
                // The denial no longer stands, so it must not name the cap's
                // outcome if the scan now runs out without a match.
                liveness.stats.lastBlockingCue = nil
                Self.logger.notice("Liveness denial by \(cue.title, privacy: .public) cleared on face frame \(evaluator.faceFrames, privacy: .public); waiting for a match with \(evaluator.tuning.cleanFrames, privacy: .public) clean face frames")
            } else {
                Self.logger.debug("Liveness pending again: a face that did not match, or a cue tripped")
            }
        }
    }

    /// Whether liveness lets this frame's match type. Always with liveness
    /// off. A match refused by a denial is counted, and logged once per
    /// denial.
    private func livenessAllowsTyping(_ liveness: inout ScanLiveness) -> Bool {
        switch liveness.evaluator.decision {
        case .passed:
            return true
        case .pending:
            let needed = liveness.evaluator.tuning.cleanFrames, clean = liveness.evaluator.cleanRun
            Self.logger.debug("Match held: liveness needs \(needed, privacy: .public) clean face frames of this face in a row, has \(clean, privacy: .public)")
            return false
        case .denied(let cue):
            liveness.stats.blockedMatches += 1
            liveness.stats.lastBlockingCue = cue
            if !liveness.blockLogged {
                liveness.blockLogged = true
                Self.logger.notice("Match blocked: liveness denied by \(cue.title, privacy: .public); nothing typed, still scanning")
            }
            return false
        }
    }

    /// The wait after a checked frame: every frame in the fast phase; then
    /// at most one per `slowFrameInterval`, with the camera converting only
    /// the frame asked for after the wait.
    private func pace(_ camera: any FaceFrameSource, since startedAt: TimeInterval) async {
        let clock = environment.clock
        guard clock.now() - startedAt >= Self.fastPhase else {
            return await clock.sleep(for: Self.frameWait)
        }
        camera.setConvertsEveryFrame(false)
        await clock.sleep(for: Self.slowFrameInterval)
        camera.requestFrame()
    }

    // MARK: - Typing

    private func injectPassword(generation: Int) async {
        guard !injectedThisLockSession else {
            Self.logger.notice("Injection refused: already typed this lock session")
            return
        }
        guard lockGuard.mayType() else {
            logTypingRefused("Injection refused")
            record(.aborted)
            return
        }
        guard environment.accessibility.isTrusted() else {
            isAccessibilityTrusted = false
            Self.logger.notice("Injection refused: Accessibility not granted")
            record(.failed(KeystrokeTyperError.accessibilityNotGranted.localizedDescription))
            return
        }
        // Cached key only: reading the password must not touch the keychain.
        guard session.isUnlocked, session.hasKeyInMemory else {
            Self.logger.notice("Injection refused: the session key is not in memory")
            return
        }
        // Synchronous, straight into the zeroable buffer: no plaintext `Data`
        // is carried across an await.
        let secret: SecretBytes
        do {
            secret = try passwordStore.readPasswordSecret()
        } catch {
            Self.logger.error("Injection refused: password unreadable: \(error.localizedDescription, privacy: .public)")
            record(.failed(error.localizedDescription))
            return
        }
        defer { secret.wipe() }
        guard generation == scanGeneration, lockGuard.mayType() else {
            logTypingRefused("Injection aborted before typing")
            record(.aborted)
            return
        }

        let typingLockSession = lockSessionID
        injectedThisLockSession = true
        status = .typingPassword
        Self.logger.notice("Injection started; password field focused (\(self.lockGuard.secureInputSummary(), privacy: .public))")
        let typer = environment.typer
        let result = await Task.detached(priority: .userInitiated) {
            Result { try typer.typePasswordAndReturn(secret) }
        }.value
        secret.wipe()

        if case .failure(let error as KeystrokeTyperError) = result, error.postedNothing,
           lockSessionID == typingLockSession {
            // Nothing reached the field, so this lock session's one
            // password is not spent: a later wake may still type it.
            injectedThisLockSession = false
        }
        switch result {
        case .success:
            guard lockSessionActive, lockSessionID == typingLockSession else {
                // The screen unlocked while typing, and perhaps a new lock
                // began: the check belongs to neither, so none is made.
                Self.logger.notice("Injection finished after its lock session ended; not checked or counted")
                refreshStatus()
                return
            }
            Self.logger.notice("Injection finished")
            beginVerification()
        case .failure(let error as KeystrokeTyperError) where error == .notAtLockScreen:
            Self.logger.notice("Injection aborted before the first key: the lock screen went away or the password field lost focus; nothing typed")
            record(.aborted)
        case .failure(let error as KeystrokeTyperError) where error == .stoppedPartway:
            Self.logger.notice("Injection aborted partway: the lock screen went away or the password field lost focus; partially typed; Return not pressed — clear the field before typing your password")
            record(.abortedPartway)
        case .failure(let error):
            Self.logger.error("Injection failed: \(error.localizedDescription, privacy: .public)")
            record(.failed(error.localizedDescription))
        }
    }

    private func logTypingRefused(_ prefix: String) {
        if lockGuard.isAwakeAtLockScreen() {
            Self.logger.notice("\(prefix, privacy: .public): no password field (\(self.lockGuard.secureInputSummary(), privacy: .public))")
        } else {
            Self.logger.notice("\(prefix, privacy: .public): not at the lock screen with the display on")
        }
    }

    /// How a check after typing ended.
    private enum VerifyVerdict {
        /// Unlocked within `unlockConfirmationWindow` of Return.
        case accepted
        /// Still locked at `verifyTimeout`.
        case rejected
        /// Unlocked, but only after the confirmation window: perhaps by hand.
        case unlockedUnconfirmed
        /// The session server gave no answer at the timeout.
        case inconclusive
    }

    /// Waits for the unlock: `screenIsUnlocked` ends it early through
    /// `endLockSession`; otherwise one check at the end of the confirmation
    /// window and a final one at the timeout. Two bounded sleeps, not a
    /// repeating timer.
    private func beginVerification() {
        awaitingVerification = true
        verifyStartedAt = environment.clock.now()
        status = .verifying
        verifyTask = Task { [weak self] in
            guard let self else { return }
            let clock = self.environment.clock
            await clock.sleep(for: Self.unlockConfirmationWindow)
            guard !Task.isCancelled, self.awaitingVerification else { return }
            if self.lockGuard.currentState() == .unlocked {
                self.finishVerification(.accepted)
                // Ends the lock session now, rather than whenever the unlock
                // notification arrives: frees the model.
                self.scheduleEvaluation()
                return
            }
            await clock.sleep(for: Self.verifyTimeout - Self.unlockConfirmationWindow)
            guard !Task.isCancelled, self.awaitingVerification else { return }
            switch self.lockGuard.currentState() {
            case .locked: self.finishVerification(.rejected)
            case .unlocked: self.finishVerification(.unlockedUnconfirmed)
            case .unknown: self.finishVerification(.inconclusive)
            }
            self.scheduleEvaluation()
        }
    }

    /// An unlock observed outside the timer (the unlock notification).
    private func verdictForObservedUnlock() -> VerifyVerdict {
        guard let verifyStartedAt,
              environment.clock.now() - verifyStartedAt <= Self.unlockConfirmationWindow else {
            return .unlockedUnconfirmed
        }
        return .accepted
    }

    private func finishVerification(_ verdict: VerifyVerdict) {
        awaitingVerification = false
        verifyStartedAt = nil
        verifyTask?.cancel()
        verifyTask = nil
        switch verdict {
        case .accepted:
            Self.logger.notice("Verify: unlocked within the confirmation window")
            consecutiveRejections = 0
            record(.unlocked)
        case .rejected:
            consecutiveRejections += 1
            Self.logger.notice("Verify: still locked after typing (\(self.consecutiveRejections, privacy: .public) in a row)")
            if consecutiveRejections >= Self.rejectionsBeforePause {
                Self.logger.notice("Typing paused until the password is re-saved or the session is unlocked")
            }
            record(.passwordRejected)
        case .unlockedUnconfirmed:
            Self.logger.notice("Verify: unlocked after the confirmation window; rejection count kept at \(self.consecutiveRejections, privacy: .public)")
            record(.unlockedUnconfirmed)
        case .inconclusive:
            Self.logger.notice("Verify: lock state unknown at the timeout; rejection count kept at \(self.consecutiveRejections, privacy: .public)")
            record(.verificationInconclusive)
        }
        refreshStatus()
    }

    private func record(_ outcome: FaceUnlockOutcome) {
        lastOutcome = outcome
        lastOutcomeAt = Date()
        Self.logger.notice("Outcome: \(String(describing: outcome), privacy: .public)")
    }

    // MARK: - Tests

    /// Waits until no settle, scan, check or preload is pending.
    func waitUntilIdle() async {
        for _ in 0..<100 {
            if let settleTask { await settleTask.value }
            if let scanTask { await scanTask.value }
            if let verifyTask { await verifyTask.value }
            if let preloadTask { await preloadTask.value }
            await loginPrompt.waitUntilSettled()
            await Task.yield()
            if settleTask == nil, scanTask == nil, verifyTask == nil, preloadTask == nil { return }
        }
    }
}

/// One face frame's liveness measurements, and what taking them cost.
private nonisolated struct MeasuredLiveness: Sendable {
    let sample: LivenessSample
    let seconds: TimeInterval
}

/// One frame's verdict, computed off the main actor.
private nonisolated struct FrameEvaluation: Sendable {
    struct Face: Sendable {
        /// The top identity's, nil when nothing scored.
        let similarity: Float?
        let matched: Bool
        /// nil when liveness is off.
        let liveness: MeasuredLiveness?
    }

    /// nil: no usable face.
    let face: Face?
    /// What detection, alignment and the embedding cost, face or not.
    let recognitionSeconds: TimeInterval
    /// The recognizer threw on this frame: its description. Counted by the
    /// scan rather than hidden as "no face".
    var recognitionError: String?

    /// Narrower faces, as a share of the frame's width, are no face at the
    /// lock screen: too far to match reliably, and too small for the glare
    /// cue (at 0.12 of the 640 px frame the glare crop is about 100 px,
    /// confidence 0.6; under 50 px it abstains). Enrolment asks for 0.21;
    /// on hardware the owner's face measured 0.2 to 0.28 at the lock screen.
    static let minimumFaceWidth: CGFloat = 0.12

    static func evaluate(_ frame: CameraFrame, recognizer: any FaceScanRecognizing,
                         sampler: (any LivenessSampling)?,
                         identities: [FaceIdentity], threshold: Float) -> FrameEvaluation {
        let (result, recognitionSeconds) = timed { Result { try recognizer.scan(frame) } }
        let found: FaceScan?
        switch result {
        case .success(let scan):
            found = scan
        case .failure(let error):
            return FrameEvaluation(face: nil, recognitionSeconds: recognitionSeconds,
                                   recognitionError: error.localizedDescription)
        }
        let frameWidth = CGFloat(frame.image.width)
        guard let scan = found, frameWidth > 0, scan.faceBox.width / frameWidth >= minimumFaceWidth else {
            return FrameEvaluation(face: nil, recognitionSeconds: recognitionSeconds)
        }
        let scored = FaceMatcher.score(scan.embedding, against: identities)
        let liveness = sampler.map { sampler in
            let (sample, seconds) = timed { sampler.sample(frame, faceBox: scan.faceBox) }
            return MeasuredLiveness(sample: sample, seconds: seconds)
        }
        let face = Face(similarity: scored.first?.centroidSimilarity,
                        matched: FaceMatcher.bestMatch(in: scored, threshold: threshold) != nil,
                        liveness: liveness)
        return FrameEvaluation(face: face, recognitionSeconds: recognitionSeconds)
    }

    private static func timed<T>(_ work: () -> T) -> (T, TimeInterval) {
        let clock = ContinuousClock()
        let started = clock.now
        let value = work()
        let elapsed = started.duration(to: clock.now).components
        return (value, TimeInterval(elapsed.seconds) + TimeInterval(elapsed.attoseconds) / 1e18)
    }
}
