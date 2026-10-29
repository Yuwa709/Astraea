import CoreGraphics

/// One target region of a layout preset.
///
/// `unitRect` is expressed in fractions (0...1) of a screen's visible area
/// with a TOP-LEFT origin and y growing downward, the same orientation as
/// Accessibility coordinates, so "top" in a name means top on screen.
nonisolated struct LayoutZone: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let unitRect: CGRect
}

/// A named set of zones the user picks from when dropping a window on the notch.
nonisolated struct LayoutPreset: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let zones: [LayoutZone]

    /// Halves, Quarters, Thirds, Full, in that order.
    static let builtIn: [LayoutPreset] = [halves, quarters, thirds, full]

    static let halves = LayoutPreset(id: "halves", name: "Halves", zones: [
        LayoutZone(id: "halves.left", name: "Left", unitRect: CGRect(x: 0, y: 0, width: 0.5, height: 1)),
        LayoutZone(id: "halves.right", name: "Right", unitRect: CGRect(x: 0.5, y: 0, width: 0.5, height: 1)),
    ])

    static let quarters = LayoutPreset(id: "quarters", name: "Quarters", zones: [
        LayoutZone(id: "quarters.topLeft", name: "Top Left",
                   unitRect: CGRect(x: 0, y: 0, width: 0.5, height: 0.5)),
        LayoutZone(id: "quarters.topRight", name: "Top Right",
                   unitRect: CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5)),
        LayoutZone(id: "quarters.bottomLeft", name: "Bottom Left",
                   unitRect: CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5)),
        LayoutZone(id: "quarters.bottomRight", name: "Bottom Right",
                   unitRect: CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)),
    ])

    static let thirds = LayoutPreset(id: "thirds", name: "Thirds", zones: [
        LayoutZone(id: "thirds.left", name: "Left",
                   unitRect: CGRect(x: 0, y: 0, width: 1.0 / 3.0, height: 1)),
        LayoutZone(id: "thirds.centre", name: "Centre",
                   unitRect: CGRect(x: 1.0 / 3.0, y: 0, width: 1.0 / 3.0, height: 1)),
        LayoutZone(id: "thirds.right", name: "Right",
                   unitRect: CGRect(x: 2.0 / 3.0, y: 0, width: 1.0 / 3.0, height: 1)),
    ])

    static let full = LayoutPreset(id: "full", name: "Full", zones: [
        LayoutZone(id: "full.full", name: "Full", unitRect: CGRect(x: 0, y: 0, width: 1, height: 1)),
    ])
}
