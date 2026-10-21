import AppKit
import os

/// The lock-screen overlay's kill-switch events: `LockMonitor`'s, plus the
/// screensaver starting, reported as `.sleep`.
///
/// `LockMonitor` reports the screensaver stopping (as `.wake`) but not its
/// start, and a level-400 space very likely draws above the screensaver too,
/// so without this the overlay could stay up over it. Observers exist only
/// between `start()` and `stop()`; no timers.
@MainActor
final class LockScreenOverlayEvents: LockEventSource {

    static let screensaverDidStart = Notification.Name("com.apple.screensaver.didstart")

    private static let logger = Logger(subsystem: "com.techie.Astraea", category: "FaceUnlock")

    var onEvent: ((LockEvent) -> Void)?

    private let lockEvents: any LockEventSource
    private let center: NotificationCenter
    private var screensaverObserver: NSObjectProtocol?

    /// Both default to the real Mac: a `LockMonitor` and the distributed
    /// notification center. Tests pass fakes and a private center.
    init(lockEvents: (any LockEventSource)? = nil, center: NotificationCenter? = nil) {
        self.lockEvents = lockEvents ?? LockMonitor()
        self.center = center ?? DistributedNotificationCenter.default()
        self.lockEvents.onEvent = { [weak self] event in self?.onEvent?(event) }
    }

    deinit {
        if let screensaverObserver { center.removeObserver(screensaverObserver) }
    }

    /// Idempotent.
    func start() {
        lockEvents.start()
        guard screensaverObserver == nil else { return }
        screensaverObserver = center.addObserver(
            forName: Self.screensaverDidStart, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                Self.logger.notice("Lock-screen overlay: screensaver started")
                self?.onEvent?(.sleep)
            }
        }
    }

    /// Idempotent.
    func stop() {
        lockEvents.stop()
        guard let screensaverObserver else { return }
        center.removeObserver(screensaverObserver)
        self.screensaverObserver = nil
    }

    /// Whether the screensaver observer is registered. Read by tests.
    var isObservingScreensaver: Bool { screensaverObserver != nil }
}
