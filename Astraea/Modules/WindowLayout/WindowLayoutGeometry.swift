import CoreGraphics

/// Pure geometry for window placement. No AppKit globals: every screen value
/// is passed in, so all of it is unit-testable.
///
/// Two global coordinate systems meet here:
/// - AppKit (`NSScreen.frame`, `visibleFrame`): origin at the bottom-left of
///   the primary screen, y up.
/// - Accessibility (`AXPosition`/`AXSize`): origin at the top-left of the
///   primary screen, y down.
/// For a rect, `axY = primaryHeight - (appKitY + height)`; the inverse is the
/// same formula.
nonisolated enum WindowLayoutGeometry {

    static func axRect(fromAppKit r: CGRect, primaryHeight: CGFloat) -> CGRect {
        flip(r, primaryHeight: primaryHeight)
    }

    static func appKitRect(fromAX r: CGRect, primaryHeight: CGFloat) -> CGRect {
        flip(r, primaryHeight: primaryHeight)
    }

    private static func flip(_ r: CGRect, primaryHeight: CGFloat) -> CGRect {
        let r = r.standardized
        return CGRect(x: r.minX, y: primaryHeight - (r.minY + r.height),
                      width: r.width, height: r.height)
    }

    /// Index into `screenFrames` (AppKit coords) of the screen the window
    /// (AX coords) mostly sits on: largest intersection area; if it
    /// intersects none, the screen whose frame contains the window centre,
    /// else the nearest screen by centre distance. Ties go to the earlier
    /// index. nil only if `screenFrames` is empty.
    static func screenIndex(forWindowAX windowAX: CGRect, screenFrames: [CGRect],
                            primaryHeight: CGFloat) -> Int? {
        guard !screenFrames.isEmpty else { return nil }
        let window = appKitRect(fromAX: windowAX, primaryHeight: primaryHeight)

        var best: (index: Int, area: CGFloat)?
        for (i, frame) in screenFrames.enumerated() {
            let overlap = frame.intersection(window)
            guard !overlap.isNull else { continue }
            let area = overlap.width * overlap.height
            guard area > 0 else { continue }
            if area > (best?.area ?? 0) { best = (i, area) }
        }
        if let best { return best.index }

        let centre = CGPoint(x: window.midX, y: window.midY)
        if let containing = screenFrames.firstIndex(where: { $0.contains(centre) }) {
            return containing
        }

        var nearest = 0
        var nearestDistance = CGFloat.greatestFiniteMagnitude
        for (i, frame) in screenFrames.enumerated() {
            let dx = frame.midX - centre.x
            let dy = frame.midY - centre.y
            let distance = dx * dx + dy * dy
            if distance < nearestDistance {
                nearestDistance = distance
                nearest = i
            }
        }
        return nearest
    }

    /// The target frame in AX coords for a zone on a screen whose
    /// `visibleFrame` (AppKit coords, excludes menu bar and Dock) is given.
    ///
    /// The zone is laid out in AX space (top-left origin, matching
    /// `unitRect`), then rounded: origin to nearest, size down, so the far
    /// edge of a zone never passes the rounded near edge of its neighbour and
    /// adjacent zones never overlap (gaps are at most 1pt).
    static func targetAXFrame(unitRect: CGRect, visibleFrame: CGRect,
                              primaryHeight: CGFloat) -> CGRect {
        let area = axRect(fromAppKit: visibleFrame, primaryHeight: primaryHeight)
        let u = unitRect.standardized
        let x = area.minX + u.minX * area.width
        let y = area.minY + u.minY * area.height
        let maxX = area.minX + u.maxX * area.width
        let maxY = area.minY + u.maxY * area.height
        return CGRect(x: x.rounded(), y: y.rounded(),
                      width: (maxX - x).rounded(.down), height: (maxY - y).rounded(.down))
    }
}
