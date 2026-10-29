import AppKit
import ApplicationServices
import SwiftUI
import os

/// What the picker shows while a window is being dragged over the notch.
@MainActor
@Observable
final class WindowLayoutState {
    let presets: [LayoutPreset] = LayoutPreset.builtIn
    /// The window being dragged, or nil between drags.
    var window: DraggedWindow?
    /// The zone under the cursor, highlighted and placed into on release.
    var hoveredZoneID: String?
    /// Whether Astraea may move other apps' windows. Read when a drag
    /// begins, so the picker can say so instead of failing silently on drop.
    var isTrusted = true

    /// The zones' on-screen views, for hit-testing. A `let`, so not
    /// observed: the views register themselves, and nothing renders from it.
    let anchors = ZoneAnchors()
}

/// Drag a window into the notch and drop it on a zone of a layout preset;
/// the window moves and resizes to that zone on the screen it came from.
///
/// Off by default: it watches every mouse press system-wide (cheaply — see
/// `WindowDragMonitor`) and needs Accessibility to move windows, and both
/// are things to opt into. Its `isEnabled` setter starts and stops the
/// monitor, so a disabled module has no monitor installed.
///
/// The module never touches the panel. AppDelegate wires `onDragMoved` and
/// `onDragEnded` to the coordinator, which decides whether the cursor is
/// over the notch and opens the picker.
@MainActor
final class WindowLayoutModule: NotchModule {

    private static let logger = Logger(subsystem: "com.techie.Astraea", category: "WindowLayout")

    /// Permanent. Persisted as a settings key.
    let id: ModuleID = "window-layout"
    let displayName = "Window Layouts"
    let priority: ModulePriority = .ambient

    var isEnabled: Bool = false {
        didSet {
            guard isEnabled != oldValue else { return }
            if isEnabled { monitor.start() } else { monitor.stop(); state.window = nil }
        }
    }

    /// Reached only by dragging a window to the notch, never glanced at.
    var wantsCompactDisplay: Bool { false }

    /// Asks whether the cursor is over the notch, and opens the picker if so.
    var onDragMoved: ((CGPoint) -> Bool)?
    /// The drag is over, placed or not; the notch can close.
    var onDragEnded: (() -> Void)?

    let state = WindowLayoutState()
    private let monitor = WindowDragMonitor()

    init() {
        monitor.onBegan = { [weak self] window in self?.dragBegan(window) }
        monitor.onMoved = { [weak self] point in self?.dragMoved(to: point) }
        monitor.onEnded = { [weak self] point in self?.dragEnded(at: point) }
    }

    func makeCompactView() -> AnyView { AnyView(EmptyView()) }

    func makeExpandedView() -> AnyView {
        AnyView(WindowLayoutPickerView(state: state))
    }

    /// Shows the system's Accessibility prompt if Astraea is not trusted yet.
    /// Called from the Settings toggle and from a drop made without trust —
    /// both direct user actions — never at launch.
    static func requestAccessibilityIfNeeded() {
        guard !AXIsProcessTrusted() else { return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        logger.notice("Accessibility requested for window layouts")
    }

    // MARK: - Drag

    private func dragBegan(_ window: DraggedWindow) {
        state.window = window
        state.hoveredZoneID = nil
        state.isTrusted = AXIsProcessTrusted()
    }

    private func dragMoved(to point: CGPoint) {
        let over = onDragMoved?(point) ?? false
        let zone = over ? state.anchors.zoneID(at: point) : nil
        guard zone != state.hoveredZoneID else { return }
        state.hoveredZoneID = zone
        Self.logger.notice("Hovered zone: \(zone ?? "none", privacy: .public)")
    }

    private func dragEnded(at point: CGPoint) {
        // Hit-tested again at the release point rather than trusting the last
        // move, which may be a few points stale.
        let over = onDragMoved?(point) ?? false
        let zoneID = over ? state.anchors.zoneID(at: point) : nil
        let window = state.window
        state.window = nil
        state.hoveredZoneID = nil
        onDragEnded?()

        guard let window, let zoneID,
              let zone = state.presets.lazy.flatMap(\.zones).first(where: { $0.id == zoneID }) else {
            Self.logger.notice("Window released \(over ? "over the notch, outside any zone" : "away from the notch", privacy: .public); not placed")
            return
        }
        guard AXIsProcessTrusted() else {
            Self.logger.notice("Window dropped on \(zoneID, privacy: .public) without Accessibility; asking")
            Self.requestAccessibilityIfNeeded()
            return
        }
        // After the window server has finished its own drag, or the app's
        // trailing move lands on top of ours.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            Self.place(window, in: zone)
        }
    }

    private static func place(_ window: DraggedWindow, in zone: LayoutZone) {
        guard let element = axWindow(for: window) else {
            logger.error("No Accessibility window found for \(window.ownerName, privacy: .public) (window \(window.windowID, privacy: .public)); not placed")
            return
        }
        let result = WindowMover.place(element, in: zone, originalFrameAX: window.startFrameAX)
        logger.notice("Placed \(window.ownerName, privacy: .public) in \(zone.id, privacy: .public): requested \(NSStringFromRect(result?.requested ?? .zero), privacy: .public), actual \(result?.actual.map(NSStringFromRect) ?? "none", privacy: .public)")
    }

    /// The Accessibility element for a window-server window. There is no
    /// public mapping between the two, so match on frame among the app's
    /// windows, and fall back to its focused window — pressing a title bar
    /// focuses the window, so that is nearly always the one.
    private static func axWindow(for window: DraggedWindow) -> AXUIElement? {
        let app = AXUIElementCreateApplication(window.pid)
        let current = WindowDragMonitor.boundsAX(of: window.windowID)
        var value: CFTypeRef?
        if let current,
           AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
           let windows = value as? [AXUIElement] {
            let match = windows.first { candidate in
                guard let frame = WindowMover.frame(of: candidate) else { return false }
                return abs(frame.minX - current.minX) <= 2 && abs(frame.minY - current.minY) <= 2
                    && abs(frame.width - current.width) <= 2 && abs(frame.height - current.height) <= 2
            }
            if let match { return match }
        }
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        // A CF type cannot be conditionally cast; the type ID check above is
        // what makes this one safe.
        return (focused as! AXUIElement)
    }
}

/// The picker's zone views, looked up by screen point.
///
/// Hit-testing asks each zone's backing NSView for its live on-screen frame
/// rather than caching SwiftUI geometry. The coordinator measures expanded
/// content by laying it out in a throwaway hosting view, and that probe
/// builds zone views too; any cached frame could come from the probe. A
/// probe view has no window, so asking the views themselves skips it, and
/// the panel's own resize animation can never leave a frame stale.
@MainActor
final class ZoneAnchors {
    private struct Entry {
        let zoneID: String
        weak var view: NSView?
    }

    private var entries: [Entry] = []

    func register(_ view: NSView, zoneID: String) {
        entries.removeAll { $0.view == nil || $0.view === view }
        entries.append(Entry(zoneID: zoneID, view: view))
    }

    /// The zone whose on-screen view contains the point, in AppKit screen
    /// coordinates. Views without a window — the measuring probe — never match.
    func zoneID(at point: CGPoint) -> String? {
        for entry in entries {
            guard let view = entry.view, let window = view.window else { continue }
            let frame = window.convertToScreen(view.convert(view.bounds, to: nil))
            if frame.contains(point) { return entry.zoneID }
        }
        return nil
    }
}
