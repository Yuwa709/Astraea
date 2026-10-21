// Adapted from Glance (github.com/jonnyoo/glance), MIT, (c) 2026 Jonathan Zhou.
// See THIRD-PARTY-LICENSES.md.

import AppKit
import os

/// A lock-screen trigger. Never a security signal on its own: whoever
/// receives one re-derives the real state from `LockScreenGuard`.
enum LockEvent: Equatable, Sendable {
    case screenLocked
    case screenUnlocked
    /// The system is about to sleep, or the displays went to sleep.
    case sleep
    /// The display came back on: system wake, display wake, or the
    /// screensaver stopping.
    case wake
}

/// Where lock and wake events come from, so tests can send their own.
@MainActor
protocol LockEventSource: AnyObject {
    var onEvent: ((LockEvent) -> Void)? { get set }
    func start()
    func stop()
}

/// Lock, unlock, sleep and wake, from notifications only: no timers.
/// Observers exist only between `start()` and `stop()`.
@MainActor
final class LockMonitor: LockEventSource {

    private static let logger = Logger(subsystem: "com.techie.Astraea", category: "FaceUnlock")

    var onEvent: ((LockEvent) -> Void)?

    private var distributedObservers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []

    deinit {
        let distributed = DistributedNotificationCenter.default()
        distributedObservers.forEach { distributed.removeObserver($0) }
        let workspace = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach { workspace.removeObserver($0) }
    }

    /// Idempotent.
    func start() {
        guard distributedObservers.isEmpty, workspaceObservers.isEmpty else { return }
        let distributed = DistributedNotificationCenter.default()
        distributedObservers = [
            observe(distributed, Notification.Name("com.apple.screenIsLocked"), as: .screenLocked),
            observe(distributed, Notification.Name("com.apple.screenIsUnlocked"), as: .screenUnlocked),
            // The key press that dismissed the screensaver cannot be seen
            // (Secure Event Input), so its stopping stands in for it.
            observe(distributed, Notification.Name("com.apple.screensaver.didstop"), as: .wake),
        ]
        let workspace = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            observe(workspace, NSWorkspace.willSleepNotification, as: .sleep),
            observe(workspace, NSWorkspace.screensDidSleepNotification, as: .sleep),
            // System and display wake land within ~100 ms of each other, in
            // either order; the coordinator debounces them into one wake.
            observe(workspace, NSWorkspace.screensDidWakeNotification, as: .wake),
            observe(workspace, NSWorkspace.didWakeNotification, as: .wake),
        ]
        Self.logger.notice("Lock monitor started")
    }

    /// Idempotent.
    func stop() {
        guard !distributedObservers.isEmpty || !workspaceObservers.isEmpty else { return }
        let distributed = DistributedNotificationCenter.default()
        distributedObservers.forEach { distributed.removeObserver($0) }
        distributedObservers = []
        let workspace = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach { workspace.removeObserver($0) }
        workspaceObservers = []
        Self.logger.notice("Lock monitor stopped")
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         as event: LockEvent) -> NSObjectProtocol {
        center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onEvent?(event) }
        }
    }
}
