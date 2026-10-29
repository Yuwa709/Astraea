import AppKit
import os

/// Another app's window, as it was when the user grabbed it.
struct DraggedWindow: Equatable {
    let windowID: CGWindowID
    let pid: pid_t
    let ownerName: String
    /// Accessibility coordinates (top-left origin), captured before the drag
    /// moved it. This is what decides the screen the window lands back on.
    let startFrameAX: CGRect
}

/// Notices when the user is dragging another app's window, and follows the
/// cursor until they let go.
///
/// A window drag is not a drag-and-drop session: the window server moves the
/// window and no destination ever hears about it, so the notch cannot be a
/// drop target the way it is for files. Instead this watches the mouse
/// globally and asks the window server whether the window under the press
/// is moving with it. Text selections, file drags and resizes all press and
/// drag too; only a window whose origin moves while its size holds counts.
///
/// Needs no permission: global monitors for mouse events do not require
/// Accessibility (key events would), and window bounds and owner PIDs come
/// from `CGWindowListCopyWindowInfo` without Screen Recording. Placing the
/// window afterwards is what needs Accessibility, and that is the module's.
///
/// Event-driven, no timer. Window-server queries run only while the mouse
/// button is down and the gesture is still unclassified, throttled to
/// `checkInterval`; once it is classified each drag event is a comparison.
@MainActor
final class WindowDragMonitor {

    private static let logger = Logger(subsystem: "com.techie.Astraea", category: "WindowDrag")

    /// Minimum spacing between window-server queries while classifying.
    nonisolated static let checkInterval: TimeInterval = 0.04
    /// Unchanged checks before a press-and-drag is given up on as not a
    /// window drag. About a quarter second of dragging at `checkInterval`.
    nonisolated static let maxUnchangedChecks = 6

    /// A confirmed window drag began.
    var onBegan: ((DraggedWindow) -> Void)?
    /// The cursor moved during a confirmed drag. AppKit screen coordinates.
    var onMoved: ((CGPoint) -> Void)?
    /// The button came up at the end of a confirmed drag. AppKit coordinates.
    var onEnded: ((CGPoint) -> Void)?

    private enum Phase {
        case idle
        /// Button down; nothing looked up yet. Most clicks never get further,
        /// so a plain click costs no window-server query at all.
        case pressed(downAX: CGPoint)
        case candidate(DraggedWindow, unchangedChecks: Int, lastCheck: Date)
        case confirmed(DraggedWindow)
        /// Not a window drag; ignore the rest of this gesture.
        case rejected
    }

    private var phase: Phase = .idle
    private var monitor: Any?

    var isRunning: Bool { monitor != nil }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            // Global monitor handlers run on the main thread.
            MainActor.assumeIsolated { self?.handle(event.type) }
        }
        if monitor == nil {
            Self.logger.error("Global mouse monitor could not be installed")
        } else {
            Self.logger.notice("Window drag monitor started")
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            Self.logger.notice("Window drag monitor stopped")
        }
        monitor = nil
        phase = .idle
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    private func handle(_ type: NSEvent.EventType) {
        let location = NSEvent.mouseLocation
        switch type {
        case .leftMouseDown:
            guard let primaryHeight = Self.primaryHeight else { phase = .rejected; return }
            phase = .pressed(downAX: CGPoint(x: location.x, y: primaryHeight - location.y))
        case .leftMouseDragged:
            dragged(to: location)
        case .leftMouseUp:
            if case .confirmed(let window) = phase {
                Self.logger.notice("Window drag ended: \(window.ownerName, privacy: .public)")
                onEnded?(location)
            }
            phase = .idle
        default:
            return
        }
    }

    private func dragged(to location: CGPoint) {
        switch phase {
        case .idle, .rejected:
            return
        case .pressed(let downAX):
            guard let window = Self.window(at: downAX) else {
                phase = .rejected
                return
            }
            phase = .candidate(window, unchangedChecks: 0, lastCheck: Date())
        case .candidate(let window, let unchanged, let lastCheck):
            guard Date().timeIntervalSince(lastCheck) >= Self.checkInterval else { return }
            guard let current = Self.boundsAX(of: window.windowID) else {
                phase = .rejected
                return
            }
            switch Self.classify(start: window.startFrameAX, current: current) {
            case .moved:
                phase = .confirmed(window)
                Self.logger.notice("Window drag began: \(window.ownerName, privacy: .public) (pid \(window.pid, privacy: .public)), start frame \(NSStringFromRect(window.startFrameAX), privacy: .public)")
                onBegan?(window)
                onMoved?(location)
            case .resized:
                phase = .rejected
            case .unchanged:
                phase = unchanged + 1 >= Self.maxUnchangedChecks
                    ? .rejected
                    : .candidate(window, unchangedChecks: unchanged + 1, lastCheck: Date())
            }
        case .confirmed:
            onMoved?(location)
        }
    }

    // MARK: - Classification

    enum Verdict: Equatable {
        case moved
        case resized
        case unchanged
    }

    /// What happened to the window since the press. A size change is a
    /// resize from an edge, which also moves the origin on two of the four
    /// sides, so it is checked first and never reads as a move.
    nonisolated static func classify(start: CGRect, current: CGRect) -> Verdict {
        if abs(current.width - start.width) > 1 || abs(current.height - start.height) > 1 {
            return .resized
        }
        if abs(current.minX - start.minX) > 0.5 || abs(current.minY - start.minY) > 0.5 {
            return .moved
        }
        return .unchanged
    }

    // MARK: - Window server

    private static var primaryHeight: CGFloat? {
        NSScreen.screens.first?.frame.height
    }

    /// The frontmost ordinary window under a point, if it belongs to another
    /// app. Layer 0 only: menus, the Dock and this app's own panel sit on
    /// higher layers and are never something to place.
    private static func window(at pointAX: CGPoint) -> DraggedWindow? {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let number = info[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.contains(pointAX) else { continue }
            // Frontmost hit wins; if that is ours, nothing below it was grabbed.
            guard pid != ownPID else { return nil }
            let owner = info[kCGWindowOwnerName as String] as? String ?? "pid \(pid)"
            return DraggedWindow(windowID: number, pid: pid, ownerName: owner, startFrameAX: bounds)
        }
        return nil
    }

    /// One window's current bounds, in Accessibility coordinates (the window
    /// server already uses a top-left origin).
    static func boundsAX(of windowID: CGWindowID) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID)
                as? [[String: Any]],
              let info = list.first,
              let boundsDict = info[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: boundsDict)
    }
}
