import AppKit
import ApplicationServices
import os

/// The outcome of a placement, both rects in AX coordinates (top-left origin
/// of the primary screen, y down). `actual` is nil when the window was
/// skipped (minimised, fullscreen) or its frame could not be read back.
nonisolated struct WindowMoveResult: Equatable, Sendable {
    let requested: CGRect
    let actual: CGRect?
}

/// Moves and resizes another app's window through the Accessibility API.
///
/// Does not check or request Accessibility trust; the caller does that.
@MainActor
enum WindowMover {

    private static let logger = Logger(subsystem: "com.techie.Astraea", category: "WindowLayout")

    // MARK: - Placement

    /// Places `window` in `zone` on the screen the window came from.
    ///
    /// `originalFrameAX` is the window's frame recorded at drag start; the
    /// window has since been dragged up to the notch, possibly onto another
    /// screen, so its current frame would pick the wrong screen. Falls back
    /// to the current frame when nil. Returns nil when no frame or no screen
    /// is available.
    static func place(_ window: AXUIElement, in zone: LayoutZone,
                      originalFrameAX: CGRect?) -> WindowMoveResult? {
        guard let sourceFrame = originalFrameAX ?? frame(of: window) else {
            logger.notice("place \(zone.id, privacy: .public): no source frame, skipped")
            return nil
        }
        guard let target = targetFrame(forWindowAX: sourceFrame, zone: zone) else {
            logger.notice("place \(zone.id, privacy: .public): no screens, skipped")
            return nil
        }
        logger.notice("place \(zone.id, privacy: .public): source \(describe(sourceFrame), privacy: .public) -> target \(describe(target), privacy: .public)")
        return apply(target, to: window)
    }

    /// The AX target frame for `zone` on the screen `windowAX` mostly sits
    /// on, using the live `NSScreen` list. nil if there are no screens.
    static func targetFrame(forWindowAX windowAX: CGRect, zone: LayoutZone) -> CGRect? {
        let screens = NSScreen.screens
        guard let primaryHeight = screens.first?.frame.height else { return nil }
        guard let index = WindowLayoutGeometry.screenIndex(
            forWindowAX: windowAX, screenFrames: screens.map(\.frame), primaryHeight: primaryHeight
        ), screens.indices.contains(index) else { return nil }
        return WindowLayoutGeometry.targetAXFrame(
            unitRect: zone.unitRect, visibleFrame: screens[index].visibleFrame, primaryHeight: primaryHeight)
    }

    /// Applies `target` (AX coords) to `window`: position, size, position
    /// again (a window clamped at a screen edge may refuse the full size
    /// until it has moved), then reads the frame back. A mismatch between
    /// requested and actual is expected for apps with minimum sizes.
    @discardableResult
    static func apply(_ target: CGRect, to window: AXUIElement) -> WindowMoveResult {
        if boolAttribute(kAXMinimizedAttribute as String, of: window) == true {
            logger.notice("apply: window is minimised, skipped")
            return WindowMoveResult(requested: target, actual: nil)
        }
        if boolAttribute("AXFullScreen", of: window) == true {
            logger.notice("apply: window is fullscreen, skipped")
            return WindowMoveResult(requested: target, actual: nil)
        }

        let positionSettable = isSettable(kAXPositionAttribute as String, of: window)
        let sizeSettable = isSettable(kAXSizeAttribute as String, of: window)
        if !positionSettable { logger.notice("apply: AXPosition not settable") }
        if !sizeSettable { logger.notice("apply: AXSize not settable") }

        if positionSettable { setPosition(target.origin, of: window) }
        if sizeSettable { setSize(target.size, of: window) }
        if positionSettable { setPosition(target.origin, of: window) }

        let actual = frame(of: window)
        if let actual {
            let matches = actual == target
            logger.notice("apply: requested \(describe(target), privacy: .public) actual \(describe(actual), privacy: .public)\(matches ? "" : " (mismatch)", privacy: .public)")
        } else {
            logger.notice("apply: requested \(describe(target), privacy: .public), actual frame unreadable")
        }
        return WindowMoveResult(requested: target, actual: actual)
    }

    // MARK: - Reading

    /// The window's frame in AX coords from AXPosition and AXSize, or nil if
    /// either cannot be read.
    static func frame(of window: AXUIElement) -> CGRect? {
        guard let origin = pointAttribute(kAXPositionAttribute as String, of: window),
              let size = sizeAttribute(kAXSizeAttribute as String, of: window) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private static func copyValue(_ attribute: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success else {
            if error != .noValue && error != .attributeUnsupported {
                logger.notice("read \(attribute, privacy: .public) failed: AXError \(error.rawValue)")
            }
            return nil
        }
        return value
    }

    private static func axValue(_ attribute: String, of element: AXUIElement) -> AXValue? {
        guard let value = copyValue(attribute, of: element),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        // Type ID checked above; CF types cannot be conditionally cast in Swift.
        return unsafeDowncast(value, to: AXValue.self)
    }

    private static func pointAttribute(_ attribute: String, of element: AXUIElement) -> CGPoint? {
        guard let value = axValue(attribute, of: element), AXValueGetType(value) == .cgPoint else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value, .cgPoint, &point) ? point : nil
    }

    private static func sizeAttribute(_ attribute: String, of element: AXUIElement) -> CGSize? {
        guard let value = axValue(attribute, of: element), AXValueGetType(value) == .cgSize else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value, .cgSize, &size) ? size : nil
    }

    private static func boolAttribute(_ attribute: String, of element: AXUIElement) -> Bool? {
        guard let value = copyValue(attribute, of: element) else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    private static func isSettable(_ attribute: String, of element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        let error = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
        guard error == .success else {
            logger.notice("settable check \(attribute, privacy: .public) failed: AXError \(error.rawValue)")
            return false
        }
        return settable.boolValue
    }

    // MARK: - Writing

    private static func setPosition(_ point: CGPoint, of element: AXUIElement) {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else {
            logger.notice("set AXPosition: AXValueCreate failed")
            return
        }
        set(kAXPositionAttribute as String, to: value, of: element)
    }

    private static func setSize(_ size: CGSize, of element: AXUIElement) {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else {
            logger.notice("set AXSize: AXValueCreate failed")
            return
        }
        set(kAXSizeAttribute as String, to: value, of: element)
    }

    private static func set(_ attribute: String, to value: AXValue, of element: AXUIElement) {
        let error = AXUIElementSetAttributeValue(element, attribute as CFString, value)
        if error != .success {
            logger.notice("set \(attribute, privacy: .public) failed: AXError \(error.rawValue)")
        }
    }

    private static func describe(_ r: CGRect) -> String {
        String(format: "(%.0f, %.0f, %.0fx%.0f)", r.minX, r.minY, r.width, r.height)
    }
}
