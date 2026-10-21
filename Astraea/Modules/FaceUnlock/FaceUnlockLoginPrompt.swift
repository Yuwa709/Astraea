import Foundation
import os

/// The session at launch: restore the one the last run left unlocked, or
/// else "ask once after login". Lock-screen Face Unlock cannot read the
/// password until the session is unlocked, so shortly after launch this
/// first tries `FaceUnlockSession.restorePersistedUnlock` (no owner check;
/// a keychain read), and only if that fails asks for the owner check, at
/// most once per launch. Neither ever runs while the screen is locked.
///
/// - Acts only when the feature is on, a password is stored (a file check;
///   no keychain), the session is not already unlocked, and the session
///   server positively says the screen is unlocked.
/// - If the screen is locked at that moment, the restore and the one prompt
///   wait for the first unlock instead. An unknown answer is asked once
///   more after `unknownStateRecheckDelay`, then left for the next unlock.
/// - A cancelled prompt is not repeated: the session stays locked, and the
///   coordinator's status says to unlock it in Settings.
/// - If the screen locks while the prompt is up, the prompt is taken down
///   without locking the session (the record a later launch restores from
///   stays) and asked again after the next unlock.
@MainActor
final class FaceUnlockLoginPrompt {

    enum Phase: Equatable {
        case idle
        case waiting
        case deferredUntilUnlock
        case prompting
        case done
    }

    static let reason = "turn on Face Unlock for this login"
    /// `nonisolated` because it is a default argument of `schedule(after:)`.
    nonisolated static let launchDelay: TimeInterval = 3
    /// How long to wait before asking the session server again when it gave
    /// no answer. Once only; after that, the next unlock event re-asks.
    static let unknownStateRecheckDelay: TimeInterval = 2

    private static let logger = Logger(subsystem: "com.techie.Astraea", category: "FaceUnlock")

    private(set) var phase: Phase = .idle

    private let session: FaceUnlockSession
    private let lockGuard: any LockScreenGuard
    private let clock: any FaceUnlockClock
    private let isEnabled: () -> Bool
    private let autoLockInterval: () -> AutoLockInterval
    private let hasStoredPassword: () -> Bool
    private var task: Task<Void, Never>?
    /// Bumped whenever a prompt is held back, shown or not, so its task can
    /// neither show it later nor mark the login as done.
    private var promptToken = 0
    /// How the restore went, once tried. For tests and the logs.
    private(set) var restoreOutcome: FaceUnlockSession.RestoreOutcome?

    init(session: FaceUnlockSession, lockGuard: any LockScreenGuard, clock: any FaceUnlockClock,
         isEnabled: @escaping () -> Bool, autoLockInterval: @escaping () -> AutoLockInterval,
         hasStoredPassword: @escaping () -> Bool) {
        self.session = session
        self.lockGuard = lockGuard
        self.clock = clock
        self.isEnabled = isEnabled
        self.autoLockInterval = autoLockInterval
        self.hasStoredPassword = hasStoredPassword
    }

    /// Call once at launch. Later calls do nothing.
    func schedule(after delay: TimeInterval = FaceUnlockLoginPrompt.launchDelay) {
        guard phase == .idle else { return }
        phase = .waiting
        task = Task { [weak self] in
            guard let self else { return }
            await self.clock.sleep(for: delay)
            guard !Task.isCancelled, self.phase == .waiting else { return }
            self.evaluate(trigger: "launch")
        }
    }

    /// The coordinator calls this whenever the session server says the
    /// screen is unlocked; only a deferred prompt acts on it.
    func screenDidUnlock() {
        guard phase == .deferredUntilUnlock else { return }
        evaluate(trigger: "first unlock")
    }

    /// The screen locked: a prompt still showing is taken down, and one
    /// about to show is held back; either is asked after the next unlock.
    ///
    /// Withdrawn, never `session.lock()`: locking would delete the record a
    /// later launch restores from, and nothing was unlocked to lock.
    func screenDidLock() {
        guard phase == .prompting else { return }
        if session.state == .unlocking {
            session.withdrawUnlockPrompt()
            holdBack(reason: "the screen locked while it was showing")
        } else if session.state == .locked {
            holdBack(reason: "the screen locked before it showed")
        }
    }

    /// For tests: waits for a scheduled or running prompt.
    func waitUntilSettled() async {
        var awaited: Task<Void, Never>?
        while let current = task, current != awaited {
            awaited = current
            await current.value
        }
    }

    private func evaluate(trigger: String, isRecheck: Bool = false) {
        guard isEnabled(), hasStoredPassword(), !session.isOwnerVerified, session.state == .locked else {
            phase = .done
            Self.logger.notice("Login prompt not needed (\(trigger, privacy: .public))")
            return
        }
        let lockState = lockGuard.currentState()
        guard lockState == .unlocked else {
            // Never at the lock screen, and never on an unknown answer.
            phase = .deferredUntilUnlock
            if lockState == .unknown {
                recheckUnknownState(trigger: trigger, isRecheck: isRecheck)
            } else {
                Self.logger.notice("Login prompt deferred until the screen unlocks (\(trigger, privacy: .public))")
            }
            return
        }
        phase = .prompting
        promptToken &+= 1
        let token = promptToken
        task = Task { [weak self] in
            guard let self, !Task.isCancelled, token == self.promptToken, self.phase == .prompting else { return }
            // The screen can lock between the check above and this task
            // running; the prompt must never show at the lock screen.
            guard self.lockGuard.isDefinitelyUnlocked() else {
                return self.holdBack(reason: "the screen was no longer unlocked")
            }
            if self.restoreOutcome == nil {
                let outcome = await self.session.restorePersistedUnlock(interval: self.autoLockInterval())
                self.restoreOutcome = outcome
                Self.logger.notice("Restore at launch: \(String(describing: outcome), privacy: .public)")
                guard outcome != .restored else {
                    self.phase = .done
                    return
                }
                // The restore awaited the keychain: re-check before prompting.
                guard !Task.isCancelled, token == self.promptToken, self.phase == .prompting else { return }
                guard self.session.state == .locked else {
                    self.phase = .done
                    return
                }
                guard self.lockGuard.isDefinitelyUnlocked() else {
                    return self.holdBack(reason: "the screen was no longer unlocked")
                }
            }
            Self.logger.notice("Login prompt shown (\(trigger, privacy: .public))")
            let verified = await self.session.unlock(reason: Self.reason)
            // Withdrawn because the screen locked: held back for the next
            // unlock, not done.
            guard token == self.promptToken else {
                Self.logger.notice("Login prompt ended by the screen locking; asked again after the next unlock")
                return
            }
            self.phase = .done
            Self.logger.notice("Login prompt \(verified ? "accepted" : "cancelled or failed", privacy: .public)")
        }
    }

    /// The session server gave no answer: ask once more shortly, then leave
    /// it to the next unlock event.
    private func recheckUnknownState(trigger: String, isRecheck: Bool) {
        guard !isRecheck else {
            Self.logger.notice("Login prompt deferred: the lock state is still unknown; waiting for the next unlock (\(trigger, privacy: .public))")
            return
        }
        Self.logger.notice("Login prompt deferred: the lock state is unknown; checking again in \(Int(Self.unknownStateRecheckDelay), privacy: .public) s (\(trigger, privacy: .public))")
        task?.cancel()
        promptToken &+= 1
        let token = promptToken
        task = Task { [weak self] in
            guard let self else { return }
            await self.clock.sleep(for: Self.unknownStateRecheckDelay)
            guard !Task.isCancelled, token == self.promptToken, self.phase == .deferredUntilUnlock else { return }
            self.evaluate(trigger: "\(trigger), rechecked", isRecheck: true)
        }
    }

    /// A prompt that has not shown yet waits for the next unlock instead.
    private func holdBack(reason: String) {
        task?.cancel()
        promptToken &+= 1
        phase = .deferredUntilUnlock
        Self.logger.notice("Login prompt deferred until the screen unlocks: \(reason, privacy: .public)")
    }
}
