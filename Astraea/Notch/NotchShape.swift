import AppKit
import SwiftUI

/// The expanded-notch silhouette: top edge flush with the screen top, concave
/// corners flaring into the menu bar, straight sides, convex rounded bottom
/// corners. The body is inset from the panel edges by `topRadius`; the flare
/// spans the full width at the very top.
///
/// Radii clamp to the available rect so the collapsed (exact-notch) size
/// stays drawable without artifacts.
struct NotchShape: Shape {

    /// Per-state radii, user-tuned: the open card is softer than the
    /// compact bar.
    /// Compact matches the physical housing's own corner tightness; the
    /// open card is much rounder, measured against the Sapphire reference.
    static let compactTopRadius: CGFloat = 8
    static let compactBottomRadius: CGFloat = 12
    static let expandedTopRadius: CGFloat = 14
    static let expandedBottomRadius: CGFloat = 34

    var topRadius: CGFloat = NotchShape.compactTopRadius
    var bottomRadius: CGFloat = NotchShape.compactBottomRadius

    /// Makes the radii interpolate rather than cut.
    ///
    /// A `Shape` without this gets `EmptyAnimatableData`, so a radius change
    /// is a hard swap even inside an animation — which is why the collapse
    /// repainted 14/34 as 8/12 in a single frame. Declaring the pair
    /// animatable is what lets the corners round down over the close;
    /// `AnimatedSilhouette` below decides when that interpolation runs.
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let topR = min(topRadius, rect.width / 4, rect.height / 2)
        let botR = min(bottomRadius, rect.width / 4, rect.height / 2)

        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        // Concave top-left fillet: full-width at the screen edge, easing
        // inward to the body.
        p.addQuadCurve(
            to: CGPoint(x: rect.minX + topR, y: rect.minY + topR),
            control: CGPoint(x: rect.minX + topR, y: rect.minY)
        )
        p.addLine(to: CGPoint(x: rect.minX + topR, y: rect.maxY - botR))
        // Convex bottom-left corner.
        p.addQuadCurve(
            to: CGPoint(x: rect.minX + topR + botR, y: rect.maxY),
            control: CGPoint(x: rect.minX + topR, y: rect.maxY)
        )
        p.addLine(to: CGPoint(x: rect.maxX - topR - botR, y: rect.maxY))
        // Convex bottom-right corner.
        p.addQuadCurve(
            to: CGPoint(x: rect.maxX - topR, y: rect.maxY - botR),
            control: CGPoint(x: rect.maxX - topR, y: rect.maxY)
        )
        p.addLine(to: CGPoint(x: rect.maxX - topR, y: rect.minY + topR))
        // Concave top-right fillet.
        p.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - topR, y: rect.minY)
        )
        p.closeSubpath()
        return p
    }
}

/// What the panel hosts: the silhouette, plus whatever the arbiter says
/// should be inside it.
///
/// The fill measures #000000 at the window buffer — the darkest displayable
/// value. Solid, no stroke; any residual mismatch against the bezel is LCD
/// backlight, not colour.
///
/// Content is inset below the menu bar band so it never renders behind the
/// physical camera housing, where it would be invisible.
struct NotchOverlayView: View {

    var content: AnyView?
    /// Compact-state wing contents, drawn in the menu bar band flanking the
    /// housing. The gap between them is exactly the housing's deadzone.
    var leadingWing: AnyView?
    var trailingWing: AnyView?
    /// The menu bar band, which the housing occupies. Content starts below it.
    var neckHeight: CGFloat = 32
    /// Play the emerge-from-the-notch entrance on this content.
    var revealContent: Bool = false
    /// Panel-level chrome for the expanded state, drawn in the band beside
    /// the housing. That band is free here: the wings that use it render
    /// only while compact, and these render only while expanded, so the two
    /// can never overlap. Leading holds navigation (clipboard, back);
    /// trailing holds caffeinate.
    var topLeadingAccessory: AnyView?
    var topTrailingAccessory: AnyView?
    /// The camera housing's x-range in this overlay's own coordinates
    /// (origin at the visible rect's leading edge). The chrome band is
    /// positioned from it: the leading group ends a gutter before
    /// `lowerBound`, the trailing group starts a gutter after `upperBound`,
    /// so no button can be laid out behind the housing, where it would be
    /// invisible and unclickable.
    ///
    /// A *clamp*, not an anchor: the groups hang off the panel's corners
    /// and are pushed inward only if they would otherwise reach the
    /// housing. Anchoring to the housing instead put the trailing group
    /// well inside the panel's trailing edge (user-observed 2026-09-01) —
    /// correct clearance, wrong place. The width floor is sized so the
    /// clamp never fires; `NotchCoordinator` logs at `.error` if it does.
    ///
    /// On a screen with no notch the coordinator derives this from the
    /// fallback strip, the app's stand-in for a housing.
    var housingLocalRange: ClosedRange<CGFloat> = 0...0
    /// The panel's visible width, and the measured chrome group widths:
    /// what `bandLayout` needs to place both groups from the corners in.
    var panelWidth: CGFloat = 0
    var chromeGroups = NotchPanel.ChromeGroupWidths()
    /// The panel is open but has nothing to show below the neck: the band
    /// is the only row. The content region must not render — its fixed
    /// neck+40 of padding survives even an empty view, inflates the root
    /// past the neck-height frame, and NSHostingView silently centres the
    /// overflow, shoving the band up under the screen edge (the clipped-
    /// buttons bug, measured 2026-09-01: root 82pt in a 42pt window).
    var chromeOnly: Bool = false

    var body: some View {
        // Expanded (has content) draws the softer card; compact, idle and
        // the chrome-only bar keep the tighter silhouette — chrome-only is
        // neck-height, where the 34pt expanded bottom radius reads as a
        // blob rather than a bar.
        let expanded = content != nil
        ZStack(alignment: .top) {
            AnimatedSilhouette(soft: expanded && !chromeOnly)
            if leadingWing != nil || trailingWing != nil {
                wingsRow
            }
            if expanded, topLeadingAccessory != nil || topTrailingAccessory != nil {
                chromeBand
            }
            if let content, !chromeOnly {
                // Horizontal padding is the panel's visible side border;
                // keep in lockstep with the coordinator's measuring probe.
                content
                    .padding(.top, neckHeight + 20)
                    .padding(.horizontal, Self.contentSideInset)
                    .padding(.bottom, 20)
                    .modifier(RevealFromNotch(enabled: revealContent))
            }
        }
        // The hover halo: the panel frame is inflated by this margin, and
        // the drawing insets back, leaving transparent hover-sensitive
        // pixels around the silhouette. Top stays flush with the screen.
        .padding(.horizontal, NotchPanel.hoverMargin)
        .padding(.bottom, NotchPanel.hoverMargin)
        .ignoresSafeArea()
    }
}

// MARK: - Rows

extension NotchOverlayView {

    /// The compact wings. Centered in each wing: hugging the outer corners
    /// looked crowded, hugging the housing looked glued to it (both
    /// user-verified on hardware, the latter by photo). Center splits the
    /// margin evenly.
    private var wingsRow: some View {
        HStack(spacing: 0) {
            wing(leadingWing, width: NotchPanel.leadingWingWidth)
            Spacer(minLength: 0)
            wing(trailingWing, width: NotchPanel.trailingWingWidth)
        }
        // Matches compactEdgeExtra: the panel is wider than the
        // wings by this per side, so content stays put as it grows.
        .padding(.horizontal, NotchPanel.compactEdgeExtra)
        .frame(height: neckHeight)
    }

    /// The expanded chrome band. Both groups hang off their own corner at
    /// the same inset — the housing only pushes them in if they would
    /// otherwise reach it, which the width floor prevents. See `bandLayout`.
    private var chromeBand: some View {
        let band = Self.bandLayout(panelWidth: panelWidth,
                                   housingLocal: housingLocalRange,
                                   groups: chromeGroups)
        return HStack(spacing: 0) {
            if let topLeadingAccessory { topLeadingAccessory }
            Spacer(minLength: 0)
            if let topTrailingAccessory { topTrailingAccessory }
        }
        .padding(.leading, band.leadingInset)
        .padding(.trailing, band.trailingInset)
        .frame(height: neckHeight)
    }

    @ViewBuilder
    private func wing(_ view: AnyView?, width: CGFloat) -> some View {
        Group {
            if let view { view } else { Color.clear }
        }
        .frame(width: width, height: neckHeight, alignment: .center)
    }
}

// MARK: - Layout constants and band geometry

extension NotchOverlayView {

    /// The panel's visible side border, used by the content column.
    ///
    /// Must stay in lockstep with the coordinator's measuring probe, which
    /// hardcodes the same 32 — they disagree and the measured panel no longer
    /// fits the rendered content.
    nonisolated static let contentSideInset: CGFloat = 32

    /// The chrome band sits nearer the corners than the content column does
    /// (user-requested). Its own constant rather than a smaller
    /// `contentSideInset`, because that one is pinned to the measuring probe
    /// and the band does not feed measurement at all.
    ///
    /// Floored by the corner: `expandedTopRadius` is 14, so anything below
    /// roughly 20 puts a 24pt control into the curve and clips it — the
    /// failure the old comment here recorded when this was tried at 2pt.
    nonisolated static let accessorySideInset: CGFloat = 24

    /// The close, as SwiftUI states it: the same duration and control points
    /// `NotchPanel.setState` gives the frame animation, read from there
    /// rather than restated, so the corners cannot round down on a different
    /// clock than the window shrinks on.
    nonisolated static var collapseAnimation: Animation {
        let c = NotchPanel.collapseCurve
        return .timingCurve(Double(c.x1), Double(c.y1), Double(c.x2), Double(c.y2),
                            duration: NotchPanel.collapseDuration)
    }

    /// Breathing room the clamp keeps between a chrome group and the
    /// housing. 6pt: the buttons carry ~6pt of internal padding around
    /// their glyphs already, so the visible glyph-to-housing gap would read
    /// as ~12pt. Only reachable if the clamp fires, which the width floor
    /// is sized to prevent.
    nonisolated static let housingGutter: CGFloat = 6

    /// The band's keep-out span: the housing plus a gutter each side, in
    /// overlay-local x. Pure and `nonisolated` so the clearance tests
    /// exercise the exact geometry the view lays out, not a re-derivation.
    nonisolated static func bandGapRange(housingLocal: ClosedRange<CGFloat>) -> ClosedRange<CGFloat> {
        (housingLocal.lowerBound - housingGutter)...(housingLocal.upperBound + housingGutter)
    }

    /// Where each chrome group sits, as insets from its own panel edge.
    ///
    /// Both default to `accessorySideInset`, mirrored — the band reads as
    /// belonging to the panel's corners, and the two sides are visibly
    /// equidistant. The housing is a clamp on top of that: a group is
    /// pushed inward only if it would otherwise come within
    /// `housingGutter` of the camera, where it would be invisible.
    ///
    /// `NotchPanel.expandedRect`'s width floor is derived so that neither
    /// clamp can fire in any expanded state; the coordinator logs at
    /// `.error` if one does, because that means the floor and this
    /// function have drifted apart.
    struct BandLayout: Equatable {
        var leadingInset: CGFloat
        var trailingInset: CGFloat
        var leadingClamped = false
        var trailingClamped = false
        var isClamped: Bool { leadingClamped || trailingClamped }
    }

    nonisolated static func bandLayout(panelWidth: CGFloat,
                                       housingLocal: ClosedRange<CGFloat>,
                                       groups: NotchPanel.ChromeGroupWidths) -> BandLayout {
        let gap = bandGapRange(housingLocal: housingLocal)
        var layout = BandLayout(leadingInset: accessorySideInset,
                                trailingInset: accessorySideInset)

        if accessorySideInset + groups.leading > gap.lowerBound {
            layout.leadingInset = max(0, gap.lowerBound - groups.leading)
            layout.leadingClamped = true
        }
        let trailingGroupMinX = panelWidth - accessorySideInset - groups.trailing
        if trailingGroupMinX < gap.upperBound {
            layout.trailingInset = max(0, panelWidth - gap.upperBound - groups.trailing)
            layout.trailingClamped = true
        }
        return layout
    }
}

/// The silhouette, easing its corners down when they tighten.
///
/// `NotchShape.animatableData` makes the radii interpolable; this decides
/// when that runs. Only the tightening is animated. The collapse used to
/// repaint the open card's 14/34 as the compact 8/12 in one frame, at the
/// moment the content went, so the panel visibly went sharp-cornered before
/// it closed. Rounding *up* still snaps, which leaves the expand path drawing
/// exactly as it always has.
///
/// Direction is read from the value itself rather than passed in, so nothing
/// outside this view has to tell it which way the panel is going.
///
/// The `@State` lives here rather than on `NotchOverlayView` because a
/// private stored property would make that struct's memberwise initialiser
/// private too, and every call site — the panel and two test suites — uses
/// it.
private struct AnimatedSilhouette: View {

    /// Whether the softer open-card radii are wanted: expanded, with content
    /// below the neck.
    let soft: Bool

    /// What is actually drawn, which lags `soft` for the length of a
    /// collapse. Nil until the first layout, when it adopts whatever state
    /// the panel already has instead of animating into it.
    @State private var drawnSoft: Bool?
    /// The open card's drop shadow, separate from `drawnSoft` because it
    /// eases in on expand, where the corners snap.
    @State private var shadowShown = false

    /// The shadow must stay inside the hover halo, the only transparent
    /// space the panel has around the silhouette: past it, the window edge
    /// cuts the falloff into a hard line. The falloff reaches about twice
    /// the radius, so 2 × radius + offset must stay under hoverMargin: 6/3
    /// overran it and showed the line on a light background (2026-10-29).
    private static let shadowRadius: CGFloat = 2.5
    private static let shadowOffset: CGFloat = 1.5

    var body: some View {
        let drawn = drawnSoft ?? soft
        NotchShape(
            topRadius: drawn ? NotchShape.expandedTopRadius : NotchShape.compactTopRadius,
            bottomRadius: drawn ? NotchShape.expandedBottomRadius : NotchShape.compactBottomRadius
        )
        .fill(Color.black)
        .shadow(color: .black.opacity(shadowShown ? 0.6 : 0),
                radius: Self.shadowRadius, y: Self.shadowOffset)
        .onAppear {
            drawnSoft = soft
            shadowShown = soft
        }
        .onChange(of: soft) { _, wantsSoft in
            // Hard rule 8: with Reduce Motion on, the frame snaps, so the
            // corners and shadow must snap with it rather than easing.
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                drawnSoft = wantsSoft
                shadowShown = wantsSoft
            } else if wantsSoft {
                drawnSoft = true
                withAnimation(.easeOut(duration: 0.25)) { shadowShown = true }
            } else {
                withAnimation(NotchOverlayView.collapseAnimation) {
                    drawnSoft = false
                    shadowShown = false
                }
            }
        }
    }
}

/// The entrance for expanded content: pulled out of the notch with the
/// panel's own growth — scaling from the top center — with a fast fade and
/// a settling blur standing in for motion blur. Timed to the expand
/// animation so content and silhouette move as one.
private struct RevealFromNotch: ViewModifier {
    let enabled: Bool
    @State private var revealed = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(revealed || !enabled ? 1 : 0.55, anchor: .top)
            .opacity(revealed || !enabled ? 1 : 0)
            .blur(radius: revealed || !enabled ? 0 : 14)
            .onAppear {
                guard enabled, !revealed else { return }
                // About half the panel's grow+settle, so content is locked
                // in before the silhouette is. Was 0.17 against a 0.34s
                // open; the open is now gentler and longer, and this follows.
                let open = NotchPanel.openGrowDuration + NotchPanel.openSettleDuration
                withAnimation(.easeOut(duration: open * 0.5)) {
                    revealed = true
                }
            }
    }
}
