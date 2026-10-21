import AppKit
import Observation
import os

/// The coordinator state the overlay follows. `FaceUnlockCoordinator` is the
/// real one; tests use an observable fake.
@MainActor
protocol LockScreenOverlaySource: AnyObject {
    var status: FaceUnlockStatus { get }
    var lastOutcome: FaceUnlockOutcome? { get }
    var lastOutcomeAt: Date? { get }
}

extension FaceUnlockCoordinator: LockScreenOverlaySource {}

/// Follows Face Unlock and shows its progress above the lock screen.
///
/// Rules:
/// - The phase is derived from the coordinator (`LockScreenOverlayMapping`),
///   never tracked separately. The only state of its own is the kill
///   switch's `suppression`.
/// - Nothing is shown unless `LockScreenGuard` positively says the screen is
///   locked and the display is on. Anything else hides at once. A refusal
///   during an attempt is retried on the next wake or lock event, never on
///   a timer.
/// - The window and its SkyLight space exist only while a phase is visible.
/// - The kill switch listens whenever Face Unlock is not `.disabled`, so it
///   is already live when a scan starts: an unlock in the same turn as
///   `.scanning` is caught before the first presentation (lock-screen review
///   L3). It also keeps listening while it suppresses an attempt and while
///   a window is up or fading out. Disabled, nothing runs: no observers, no
///   hold task. Notification observers only, no timers.
/// - Reduce Motion (hard rule 8): every show, hide and phase change is
///   instant.
/// - Unlock, sleep or screensaver remove the overlay at once, no fade, ahead
///   of the coordinator catching up, and keep it off for the rest of that
///   attempt unless the Mac is locked again (or, after sleep, wakes) with
///   the gate open.
@MainActor
final class LockScreenOverlayController {

    /// Why the kill switch is holding the overlay off for the current attempt.
    enum Suppression: Equatable {
        /// The screen unlocked. Only a fresh lock re-arms: right after an
        /// unlock the gate can still read locked, so a wake must not.
        case unlocked
        /// Sleep, display sleep or screensaver. A wake or a lock re-arms.
        case asleep
    }

    private static let logger = Logger(subsystem: "com.techie.Astraea", category: "FaceUnlock")

    private weak var source: (any LockScreenOverlaySource)?
    private let presenter: any LockScreenOverlayPresenting
    private let lockGuard: any LockScreenGuard
    private let killEvents: any LockEventSource
    private let clock: any FaceUnlockClock
    private let now: () -> Date
    private let reduceMotion: () -> Bool

    /// The phase on screen, nil when hidden. Read by tests.
    private(set) var shownPhase: LockScreenOverlayPhase?
    /// The `lastOutcomeAt` already dealt with; see `LockScreenOverlayMapping`.
    private var consumedOutcomeAt: Date?
    /// Set by the kill switch mid-attempt; cleared by a re-arming event or
    /// once the coordinator leaves the attempt, so a scan it had not yet
    /// cancelled cannot bring the overlay back.
    private(set) var suppression: Suppression?
    var isSuppressed: Bool { suppression != nil }
    /// The failure hold: one cancellable one-shot, for `holdOutcomeAt`.
    private var holdTask: Task<Void, Never>?
    private var holdOutcomeAt: Date?

    init(source: any LockScreenOverlaySource,
         presenter: (any LockScreenOverlayPresenting)? = nil,
         lockGuard: (any LockScreenGuard)? = nil,
         killEvents: (any LockEventSource)? = nil,
         clock: (any FaceUnlockClock)? = nil,
         now: (() -> Date)? = nil,
         reduceMotion: (() -> Bool)? = nil) {
        // Built here rather than as default arguments, which would run
        // outside the main actor.
        self.source = source
        self.presenter = presenter ?? LockScreenScanPresenter()
        self.lockGuard = lockGuard ?? SystemLockScreenGuard()
        self.killEvents = killEvents ?? LockScreenOverlayEvents()
        self.clock = clock ?? ContinuousFaceUnlockClock()
        self.now = now ?? { Date() }
        self.reduceMotion = reduceMotion ?? { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
        // An outcome from before this controller existed is never shown.
        consumedOutcomeAt = source.lastOutcomeAt
        self.killEvents.onEvent = { [weak self] event in self?.handleKillEvent(event) }
        self.presenter.onFadeOutFinished = { [weak self] in self?.updateKillMonitor() }
        observe()
    }

    // MARK: - Observation

    /// Observation fires once per registration, so it re-registers on each
    /// change.
    private func observe() {
        guard let source else { return }
        withObservationTracking {
            _ = source.status
            _ = source.lastOutcome
            _ = source.lastOutcomeAt
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observe() }
        }
        apply()
    }

    private func apply() {
        applyPhase()
        updateKillMonitor()
    }

    private func applyPhase() {
        guard let source else { return }
        let status = source.status
        let outcomeAt = source.lastOutcomeAt
        let inProgress = LockScreenOverlayMapping.isInProgress(status)
        // Any outcome recorded before this attempt belongs to an earlier one.
        if inProgress { consumedOutcomeAt = outcomeAt }
        if let suppression {
            guard !inProgress else {
                Self.logger.notice("Lock-screen overlay held off (\(String(describing: suppression), privacy: .public)): status \(String(describing: status), privacy: .public), attempt still winding down")
                return hide(reason: "kill switch, attempt still winding down", animated: false)
            }
            self.suppression = nil
            consumedOutcomeAt = outcomeAt
            Self.logger.notice("Lock-screen overlay: attempt ended after the kill switch; armed again")
        }
        let target = LockScreenOverlayMapping.phase(
            status: status, outcome: source.lastOutcome, outcomeAt: outcomeAt,
            consumedOutcomeAt: consumedOutcomeAt, now: now())
        show(target, outcomeAt: outcomeAt, status: status)
    }

    private func show(_ target: LockScreenOverlayPhase?, outcomeAt: Date?, status: FaceUnlockStatus) {
        guard let target else {
            return hide(reason: "status \(String(describing: status)), outcome \(source?.lastOutcome.map { String(describing: $0) } ?? "none")")
        }
        if target == .failed, let outcomeAt { startHoldIfNeeded(for: outcomeAt) } else { cancelHold() }
        guard lockGuard.isAwakeAtLockScreen() else {
            let retry = LockScreenOverlayMapping.isInProgress(status) ? "retried on the next wake or lock" : "dropped"
            Self.logger.notice("Lock-screen overlay refused (\(String(describing: target), privacy: .public)), \(retry, privacy: .public): not locked with the display on (state \(String(describing: self.lockGuard.currentState()), privacy: .public), display asleep \(self.lockGuard.isMainDisplayAsleep(), privacy: .public))")
            cancelHold()
            // Dealt with: a refused failure never comes back later.
            consumedOutcomeAt = outcomeAt
            return hide(reason: "lock gate closed", animated: false)
        }
        if presenter.isPresented {
            guard shownPhase != target else { return }
            Self.logger.notice("Lock-screen overlay phase: \(String(describing: self.shownPhase), privacy: .public) -> \(String(describing: target), privacy: .public)")
            presenter.update(target)
            shownPhase = target
            return
        }
        guard presenter.present(target, reduceMotion: reduceMotion()) else {
            Self.logger.notice("Lock-screen overlay unavailable for \(String(describing: target), privacy: .public)")
            cancelHold()
            shownPhase = nil
            return
        }
        shownPhase = target
    }

    /// Fades out while still at the lock screen; anywhere else, or with
    /// Reduce Motion on, at once.
    private func hide(reason: String, animated: Bool? = nil) {
        cancelHold()
        shownPhase = nil
        guard presenter.isPresented else { return }
        let fade = (animated ?? lockGuard.isAwakeAtLockScreen()) && !reduceMotion()
        presenter.dismiss(animated: fade, reason: reason)
    }

    // MARK: - Failure hold

    private func startHoldIfNeeded(for outcomeAt: Date) {
        guard holdOutcomeAt != outcomeAt || holdTask == nil else { return }
        cancelHold()
        let remaining = LockScreenOverlayMapping.failureHoldRemaining(outcomeAt: outcomeAt, now: now())
        holdOutcomeAt = outcomeAt
        holdTask = Task { [weak self] in
            guard let self else { return }
            await self.clock.sleep(for: remaining)
            guard !Task.isCancelled, self.holdOutcomeAt == outcomeAt else { return }
            self.holdTask = nil
            self.holdOutcomeAt = nil
            self.consumedOutcomeAt = outcomeAt
            Self.logger.notice("Lock-screen overlay: failure hold ended")
            self.apply()
        }
    }

    private func cancelHold() {
        holdTask?.cancel()
        holdTask = nil
        holdOutcomeAt = nil
    }

    // MARK: - Kill switch

    /// Listens whenever Face Unlock is on, so the switch is live before a
    /// scan's first presentation; disabled, only while something on screen
    /// or a suppression still needs it.
    private func updateKillMonitor() {
        let enabled = source.map { $0.status != .disabled } ?? false
        if enabled || suppression != nil || presenter.isPresented || presenter.isFadingOut {
            killEvents.start()
        } else {
            killEvents.stop()
        }
    }

    private func handleKillEvent(_ event: LockEvent) {
        switch event {
        case .screenUnlocked: kill(.unlocked, reason: "screen unlocked")
        case .sleep: kill(.asleep, reason: "sleep or screensaver")
        case .screenLocked, .wake: rearm(by: event)
        }
    }

    /// Instant, no fade, no gate check: the lock screen is going away. Also
    /// ends any fade still running.
    private func kill(_ kind: Suppression, reason: String) {
        cancelHold()
        consumedOutcomeAt = source?.lastOutcomeAt
        if let status = source?.status, LockScreenOverlayMapping.isInProgress(status),
           suppression != .unlocked {
            // An unlock stays the stronger reason until a fresh lock.
            suppression = kind
        }
        Self.logger.notice("Lock-screen overlay kill switch: \(reason, privacy: .public) (window up \(self.presenter.isPresented, privacy: .public), fading \(self.presenter.isFadingOut, privacy: .public), held off \(String(describing: self.suppression), privacy: .public))")
        presenter.dismiss(animated: false, reason: "kill switch: \(reason)")
        shownPhase = nil
        updateKillMonitor()
    }

    /// A lock or wake: lifts a suppression it is allowed to, when the gate
    /// is open, and re-applies, which retries a refused presentation.
    private func rearm(by event: LockEvent) {
        if let suppression {
            guard event == .screenLocked || suppression == .asleep else {
                Self.logger.notice("Lock-screen overlay: \(String(describing: event), privacy: .public) does not re-arm after an unlock")
                return
            }
            guard lockGuard.isAwakeAtLockScreen() else {
                Self.logger.notice("Lock-screen overlay not re-armed by \(String(describing: event), privacy: .public): not locked with the display on")
                return
            }
            self.suppression = nil
            Self.logger.notice("Lock-screen overlay re-armed by \(String(describing: event), privacy: .public)")
        }
        apply()
    }

    // MARK: - Tests

    /// Waits for a pending failure hold to finish.
    func waitForHold() async {
        if let holdTask { await holdTask.value }
    }
}
