// Adapted from Glance (github.com/jonnyoo/glance), MIT, (c) 2026 Jonathan Zhou.
// See THIRD-PARTY-LICENSES.md.

import AppKit
import Observation
import os

/// How long an unused Face Unlock session stays unlocked. Stored in
/// `AppSettings` by raw value: whole days, 0 for never.
nonisolated enum AutoLockInterval: Int, Codable, CaseIterable, Identifiable, Sendable {
    case sevenDays = 7
    case fourteenDays = 14
    case thirtyDays = 30
    case never = 0

    static let `default`: AutoLockInterval = .thirtyDays

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .sevenDays: "7 days"
        case .fourteenDays: "14 days"
        case .thirtyDays: "30 days"
        case .never: "Never"
        }
    }

    /// nil for `.never`: the session then stays unlocked, across restarts
    /// too, until it is locked by hand (`FaceSessionRecord`).
    var duration: TimeInterval? {
        self == .never ? nil : TimeInterval(rawValue) * 24 * 60 * 60
    }

    /// When a session last used at `lastActivityAt` should lock. nil when it
    /// never should: no activity to age, or `.never`.
    func deadline(after lastActivityAt: Date?) -> Date? {
        guard let lastActivityAt, let duration else { return nil }
        return lastActivityAt.addingTimeInterval(duration)
    }

    /// Stays unlocked longer than `other` (`.never` longest): changing to it
    /// needs a fresh owner check (`FaceUnlockSession.reauthenticate(reason:)`).
    func isLonger(than other: AutoLockInterval) -> Bool {
        switch (duration, other.duration) {
        case (nil, nil): false
        case (nil, _?): true
        case (_?, nil): false
        case (let mine?, let theirs?): mine > theirs
        }
    }

    /// Wall-clock comparison, so time spent asleep counts as idle.
    func shouldLock(lastActivityAt: Date?, now: Date) -> Bool {
        guard let deadline = deadline(after: lastActivityAt) else { return false }
        return now >= deadline
    }
}

/// Re-locks the session once it has been idle past the chosen interval.
///
/// Never polls (hard rule 9). While the session is unlocked it holds one
/// one-shot timer, set for `lastActivityAt + interval`, and replaces it
/// whenever either changes; locked, or on `.never`, it holds none. Glance
/// polls every five minutes instead.
///
/// A timer does not advance while the Mac sleeps, so on wake the deadline is
/// checked against the wall clock and the timer is re-armed with the
/// wall-clock time left; otherwise it would fire late by however long the
/// Mac slept. Asleep, nothing here runs.
@MainActor
final class FaceSessionAutoLocker {

    private static let logger = Logger(subsystem: "com.techie.Astraea", category: "FaceUnlock")

    private let session: FaceUnlockSession
    private let interval: () -> AutoLockInterval
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?

    /// What the timer is set for; nil when none is scheduled.
    private(set) var scheduledDeadline: Date?
    /// The delay the current timer was armed with, from the injected clock.
    private(set) var scheduledDelay: TimeInterval?
    /// How many timers have been armed. Lets a test see a re-arm that keeps
    /// the same deadline.
    private(set) var armCount = 0

    /// `interval` is read on every reschedule. Read it from an observable
    /// source (the settings store), so a change reschedules on its own.
    init(session: FaceUnlockSession, interval: @escaping () -> AutoLockInterval) {
        self.session = session
        self.interval = interval
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate(reason: "wake") }
        }
        observe()
    }

    deinit {
        timer?.invalidate()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    /// Observation fires once per registration, so it re-registers on each
    /// change.
    private func observe() {
        withObservationTracking {
            _ = session.state
            _ = session.lastActivityAt
            _ = interval()
        } onChange: { [weak self] in
            // `observe()` reschedules as it re-registers.
            Task { @MainActor [weak self] in self?.observe() }
        }
        reschedule()
    }

    /// Locks if the deadline has passed, else re-arms the timer from the
    /// wall clock. Called by the timer and on wake.
    func evaluate(reason: String) {
        let interval = interval()
        if session.isOwnerVerified,
           interval.shouldLock(lastActivityAt: session.lastActivityAt, now: session.now()) {
            Self.logger.notice("Auto-locking session after \(interval.rawValue, privacy: .public) idle days (\(reason, privacy: .public))")
            cancelTimer()
            session.lock()
            return
        }
        // Always a fresh timer: the old one's delay was counted in awake
        // time, so after a sleep it would fire late even for this deadline.
        timer?.invalidate()
        timer = nil
        reschedule()
    }

    /// Replaces the timer with one for the current deadline, or none.
    func reschedule() {
        let deadline = interval().deadline(after: session.lastActivityAt)
        guard deadline != scheduledDeadline || (deadline != nil && timer == nil) else { return }
        guard let deadline else { return cancelTimer() }
        timer?.invalidate()
        // A delay, not a fire date: the deadline is on the injected clock.
        let delay = max(0, deadline.timeIntervalSince(session.now()))
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.timer = nil
                self.evaluate(reason: "deadline")
            }
        }
        // Days away, so a minute of slack costs nothing and lets the system
        // coalesce the wake-up.
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        scheduledDeadline = deadline
        scheduledDelay = delay
        armCount += 1
        Self.logger.notice("Auto-lock scheduled in \(Int(delay), privacy: .public) s")
    }

    private func cancelTimer() {
        timer?.invalidate()
        timer = nil
        scheduledDelay = nil
        if scheduledDeadline != nil {
            scheduledDeadline = nil
            Self.logger.notice("Auto-lock timer cancelled")
        }
    }
}
