import AppKit
import SwiftUI
import os

/// A borderless panel that sits directly over the camera notch.
///
/// The three properties that make the overlay work at all:
/// - `styleMask` includes `.nonactivatingPanel` so interacting with the panel
///   never pulls focus from the frontmost app
/// - `level` is one step above the main menu bar so the panel draws over it
/// - `canBecomeKey` is false so the panel can never become the key window
@MainActor
final class NotchPanel: NSPanel {

    private static let logger = Logger(subsystem: "com.techie.Astraea", category: "NotchPanel")

    override var canBecomeKey: Bool { false }

    init(screen: NSScreen) {
        let notchRect = Self.notchRect(on: screen)
        super.init(
            contentRect: notchRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 1)

        // The third property the overlay depends on, alongside level and
        // styleMask. Without these the panel vanishes on Space switch
        // (.canJoinAllSpaces), disappears under fullscreen apps
        // (.fullScreenAuxiliary), and moves during Exposé transitions
        // (.stationary).
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        // Transparent panel; the SwiftUI shape draws the visible silhouette.
        // (The development-era solid red is gone with the verification lip.)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        // NSPanel defaults this to true, which would hide the overlay whenever
        // this background agent resigns active — it must stay up permanently.
        hidesOnDeactivate = false

        let hoverView = NotchHoverView()
        let hosting = NSHostingView(rootView: NotchOverlayView(neckHeight: notchRect.height))
        hosting.frame = hoverView.bounds
        hosting.autoresizingMask = [.width, .height]
        hoverView.addSubview(hosting)
        hostingView = hosting
        contentView = hoverView

        setFrame(notchRect, display: false)
    }

    /// Retained so the coordinator can swap what the notch displays without
    /// rebuilding the panel.
    private var hostingView: NSHostingView<NotchOverlayView>?

    /// Tracked so the haptic and the bounce fire only on the transition into
    /// expanded.
    private var currentState: State = .idle

    /// Bumped by every frame change `setState` starts, so an animation
    /// completion can tell whether it is still the latest. Replaces a
    /// `currentState == .expanded` check, which let an older bounce's settle
    /// apply its stale target over a newer expanded resize.
    private var animationGeneration = 0

    /// Replaces the notch's contents. All nil shows the bare silhouette.
    /// `reveal` plays the emerge-from-the-notch entrance — pass true only on
    /// the transition into expanded, not on content updates mid-display.
    func setContent(
        _ content: AnyView?,
        leadingWing: AnyView? = nil,
        trailingWing: AnyView? = nil,
        neckHeight: CGFloat,
        housingLocalRange: ClosedRange<CGFloat> = 0...0,
        panelWidth: CGFloat = 0,
        chromeGroups: ChromeGroupWidths = ChromeGroupWidths(),
        chromeOnly: Bool = false,
        reveal: Bool = false,
        topLeadingAccessory: AnyView? = nil,
        topTrailingAccessory: AnyView? = nil
    ) {
        hostingView?.rootView = NotchOverlayView(
            content: content,
            leadingWing: leadingWing,
            trailingWing: trailingWing,
            neckHeight: neckHeight,
            revealContent: reveal,
            topLeadingAccessory: topLeadingAccessory,
            topTrailingAccessory: topTrailingAccessory,
            housingLocalRange: housingLocalRange,
            panelWidth: panelWidth,
            chromeGroups: chromeGroups,
            chromeOnly: chromeOnly
        )
    }

    /// Seconds the cursor must dwell before hover reports true.
    var hoverEnterDelay: TimeInterval {
        get { (contentView as? NotchHoverView)?.enterDebounce ?? 0.35 }
        set { (contentView as? NotchHoverView)?.enterDebounce = newValue }
    }

    /// Debounced hover state from the tracking view. Task 7 wires
    /// expand/collapse here.
    var onHoverChange: ((Bool) -> Void)? {
        get { (contentView as? NotchHoverView)?.onHoverChange }
        set { (contentView as? NotchHoverView)?.onHoverChange = newValue }
    }

    /// True while the panel is the *source* of a drag. Set by AppDelegate
    /// from `FileShelfService.onDragOutChange`, so no module reaches into the
    /// panel or its `contentView`.
    var isDraggingOut: Bool {
        get { (contentView as? NotchHoverView)?.isDraggingOut ?? false }
        set { (contentView as? NotchHoverView)?.isDraggingOut = newValue }
    }

    /// A file drag arriving over the notch, or leaving it.
    var onFileDragChange: ((Bool) -> Void)? {
        get { (contentView as? NotchHoverView)?.onFileDragChange }
        set { (contentView as? NotchHoverView)?.onFileDragChange = newValue }
    }

    /// The notch's frame in screen coordinates, derived from the gap between
    /// the auxiliary top-left and top-right areas. Falls back to a centered
    /// strip on screens without a notch so development on external displays
    /// still shows something.
    ///
    /// Reads the screen and hands off to the pure overload below, which is
    /// where the geometry lives and what the tests exercise. Logged at
    /// `.debug`: this runs two or three times per state change, so it is
    /// chatter; `NotchCoordinator.reposition` logs the rect at `.notice`
    /// once per real screen change.
    static func notchRect(on screen: NSScreen) -> NSRect {
        let menuBar = fallbackHeight(frame: screen.frame,
                                     visibleFrame: screen.visibleFrame,
                                     statusBarThickness: NSStatusBar.system.thickness)
        let rect = notchRect(frame: screen.frame,
                             topInset: screen.safeAreaInsets.top,
                             leftArea: screen.auxiliaryTopLeftArea,
                             rightArea: screen.auxiliaryTopRightArea,
                             fallbackHeight: menuBar)
        logger.debug("Computed notch rect \(NSStringFromRect(rect), privacy: .public) on screen \(screen.localizedName, privacy: .public)")
        return rect
    }

    /// Width of the notchless fallback strip.
    nonisolated static let fallbackWidth: CGFloat = 200

    /// Floor for the notchless strip's height. A notchless menu bar is 24pt,
    /// but `NSStatusBar.system.thickness` still reports the legacy 22
    /// (measured 2026-10-13), and the 24pt chrome buttons would overflow a
    /// 22pt chrome-only bar.
    nonisolated static let minimumFallbackHeight: CGFloat = 24

    /// The notchless strip's height: the screen's own menu bar, measured as
    /// the gap between the frame's top and the visible frame's top. That gap
    /// is 0 when the menu bar auto-hides or the screen carries none, and then
    /// the status bar's thickness stands in. Floored at
    /// `minimumFallbackHeight` either way.
    ///
    /// A fixed 32 used to sit here, which overhung a 24pt menu bar by 8pt in
    /// clamshell mode.
    nonisolated static func fallbackHeight(frame: NSRect, visibleFrame: NSRect,
                                           statusBarThickness: CGFloat) -> CGFloat {
        let menuBar = frame.maxY - visibleFrame.maxY
        return max(menuBar > 0 ? menuBar : statusBarThickness, minimumFallbackHeight)
    }

    /// The pure core of `notchRect(on:)`: every input the screen supplies,
    /// none of it read from AppKit, so the geometry is a test.
    ///
    /// Coordinate-free on purpose. `screen.frame` is in global coordinates,
    /// so the built-in display sits at a non-zero origin whenever an external
    /// monitor is primary — and `ScreenPolicy` targets the built-in even
    /// then. Only the auxiliary areas' *widths* are used: the left one spans
    /// from the screen's left edge to the housing and the right one from the
    /// housing to the right edge, so the housing lies between
    /// `frame.minX + leftArea.width` and `frame.maxX - rightArea.width`
    /// whatever space the areas' origins are reported in. At origin 0 that
    /// is identical to the old `leftArea.maxX` / `rightArea.minX`.
    nonisolated static func notchRect(frame: NSRect, topInset: CGFloat,
                                      leftArea: NSRect?, rightArea: NSRect?,
                                      fallbackHeight: CGFloat) -> NSRect {
        guard topInset > 0, let leftArea, let rightArea else {
            return NSRect(
                x: frame.midX - fallbackWidth / 2,
                y: frame.maxY - fallbackHeight,
                width: fallbackWidth,
                height: fallbackHeight
            )
        }

        // The gap between the auxiliary areas is not guaranteed symmetric —
        // on a 15" Air it measures 1pt wider on the right, which is visible
        // as a 2px overhang on Retina. The camera housing itself is always
        // centered, so symmetrize around midX using the tighter side.
        //
        // Then inset per side: user-verified on hardware that even the
        // symmetrized rect overhangs the housing by a pixel. Rule: always
        // undershoot — an edge inside the housing sits in the deadzone and
        // is invisible, an edge outside paints live pixels. A full point,
        // not half: AppKit snaps fractional window origins to integers,
        // which silently shifts the panel off the computed rect.
        let horizontalInset: CGFloat = 1.0
        let center = frame.midX
        let gapMinX = frame.minX + leftArea.width
        let gapMaxX = frame.maxX - rightArea.width
        let halfWidth = min(center - gapMinX, gapMaxX - center) - horizontalInset
        return NSRect(
            x: center - halfWidth,
            y: frame.maxY - topInset,
            width: halfWidth * 2,
            height: topInset
        )
    }

    // MARK: - States

    /// The three sizes the panel occupies.
    enum State: String {
        /// Exactly the notch: invisible, the at-rest state.
        case idle
        /// Menu-bar-height wings flanking the housing — the "something is
        /// playing" indicator. Costs menu bar coverage on both sides; that
        /// trade-off is deliberate and shared by every notch app.
        case compact
        /// The open panel.
        case expanded
    }

    /// Wing widths, tuned by eye on hardware across four rounds. Asymmetric
    /// on purpose: with equal wings the right side consistently read as
    /// wider than the left (user-confirmed three times, most recently
    /// 2026-10-21 with the battery wings, after a brief try at 48/48) — the
    /// housing does not sit perfectly on the panel's center — so the left
    /// wing carries a few extra points to balance the appearance.
    nonisolated static let leadingWingWidth: CGFloat = 48
    nonisolated static let trailingWingWidth: CGFloat = 44

    /// The physical housing reads about 2pt left of the geometric screen
    /// center on this machine — confirmed independently in the compact state
    /// (equal wings looked right-heavy; +4 left balanced them) and the
    /// expanded state (right of the housing obviously wider). Anything that
    /// centers on the screen applies this to center on the *housing*.
    nonisolated static let opticalCenterOffset: CGFloat = -2

    /// Invisible hover halo: every state's frame extends this far beyond the
    /// visible silhouette (sides and below; the top is the screen edge), so
    /// the notch snaps open when the cursor gets near, not only dead-on.
    /// The overlay insets its drawing to match. Transparent pixels do not
    /// capture clicks, so the halo steals nothing from the menu bar.
    nonisolated static let hoverMargin: CGFloat = 10

    /// Extra black beyond the wings at each end of the compact panel —
    /// user-requested breathing room. The wing slots are inset by the same
    /// amount in the overlay, so widening this moves no content.
    nonisolated static let compactEdgeExtra: CGFloat = 2

    static func compactRect(on screen: NSScreen) -> NSRect {
        compactRect(housing: notchRect(on: screen))
    }

    /// The pure core of `compactRect(on:)`: a wing off each side of the
    /// housing, same height, never growing downward.
    nonisolated static func compactRect(housing base: NSRect) -> NSRect {
        NSRect(
            x: base.minX - leadingWingWidth - compactEdgeExtra,
            y: base.minY,
            width: base.width + leadingWingWidth + trailingWingWidth + compactEdgeExtra * 2,
            height: base.height
        )
    }

    /// The hovered frame, sized by what it will display: the coordinator
    /// measures the content and passes its size, so a player-only panel is
    /// snug and a player-plus-stats panel is taller — no guessed constants
    /// leaving voids (user-verified problem when stats were toggled off).
    ///
    /// Clamps keep degenerate measurements from producing a sliver or a
    /// window-sized slab, and coordinates stay integral: AppKit snaps
    /// fractional origins, which desyncs the computed and actual frames.
    /// Measured widths of the two chrome groups in the neck band, from the
    /// coordinator's throwaway layout pass. Never assumed: the leading group
    /// grows and shrinks with which doors are enabled.
    struct ChromeGroupWidths: Equatable {
        var leading: CGFloat = 0
        var trailing: CGFloat = 0
        var total: CGFloat { leading + trailing }
    }

    static func expandedRect(on screen: NSScreen, contentSize: CGSize,
                             chromeOnly: Bool = false,
                             chromeGroups: ChromeGroupWidths = ChromeGroupWidths()) -> NSRect {
        expandedRect(housing: notchRect(on: screen), contentSize: contentSize,
                     chromeOnly: chromeOnly, chromeGroups: chromeGroups)
    }

    /// The narrowest panel on which both chrome groups sit at
    /// `accessorySideInset` from their own corners without the housing
    /// clamp firing — i.e. the floor that keeps
    /// `NotchOverlayView.bandLayout` in its unclamped case.
    ///
    /// Derived rather than guessed. The panel centres on the housing's
    /// optical centre, so with the panel `W` wide the housing's leading
    /// edge sits at `W/2 - housingWidth/2 - opticalCenterOffset` in panel
    /// coordinates and its trailing edge `housingWidth` further along.
    /// Requiring `inset + group + gutter` to fit on each side and solving
    /// for `W` gives the two bounds below. The optical offset pushes the
    /// housing off centre, so it *costs* clearance on one side and grants
    /// it on the other — which is exactly the 4pt that a floor of
    /// `housing + 2·max(group) + 2·inset` came up short by, silently
    /// clamping the leading group on the stats-only panel.
    nonisolated static func bandMinWidth(housingWidth: CGFloat,
                                         groups: ChromeGroupWidths) -> CGFloat {
        let perSide = NotchOverlayView.accessorySideInset + NotchOverlayView.housingGutter
        let leadingNeed = groups.leading + opticalCenterOffset
        let trailingNeed = groups.trailing - opticalCenterOffset
        return housingWidth + 2 * (perSide + max(leadingNeed, trailingNeed))
    }

    /// The pure core, split from the screen-taking wrapper so the geometry
    /// is a test rather than a hardware session (`notchRect` symmetrizes
    /// the housing around the screen's midX, so `housing.midX` stands in
    /// for it here).
    ///
    /// The width floor covers the chrome band in EVERY expanded state, not
    /// only chrome-only: the band anchors both groups to the housing, so
    /// the panel must always span housing + the wider group mirrored on
    /// both sides + the corner insets. The first version floored only the
    /// chrome-only bar, and the stats-only standby panel — same width, real
    /// content — put the shelf button back under the camera
    /// (photo-confirmed 2026-09-01).
    ///
    /// Chrome-only differs in height alone: exactly the neck, no downward
    /// growth. Width and placement are shared with every other expanded
    /// state, so the bar and a floor-width card sit at the same frame and
    /// the transition between them is a pure height change.
    nonisolated static func expandedRect(housing: NSRect, contentSize: CGSize,
                                         chromeOnly: Bool = false,
                                         chromeGroups: ChromeGroupWidths = ChromeGroupWidths()) -> NSRect {
        let legacyMinWidth = housing.width + (leadingWingWidth + 24) * 2
        let minWidth = max(legacyMinWidth, bandMinWidth(housingWidth: housing.width,
                                                        groups: chromeGroups))
        // Ceiling raised from 540 for the shelf redesign (2026-08-30): the
        // reference layout puts the resting shelf at ~687pt measured from
        // full-screen captures at this display's 0.735 px-to-point scale.
        let width = (min(max(chromeOnly ? 0 : contentSize.width, minWidth), 690)).rounded(.up)
        let height: CGFloat
        if chromeOnly {
            height = housing.height
        } else {
            let minHeight = housing.height + 56
            // Ceiling raised from 300: the lyrics takeover needs more, and
            // clamping below the content's real height compressed it upward
            // (badge slid under the bezel) and spilled it past the rounded
            // silhouette, where the square window edge cut it into a hard box.
            height = (min(max(contentSize.height, minHeight), 460)).rounded(.up)
        }
        return NSRect(
            x: (housing.midX + opticalCenterOffset - width / 2).rounded(),
            y: housing.maxY - height,
            width: width,
            height: height
        )
    }

    /// The close's timing, named so the silhouette can round its corners
    /// down on exactly the clock the window shrinks on
    /// (`NotchOverlayView.collapseAnimation` reads these). The values are the
    /// tuned originals, lifted out of the animation block below unchanged —
    /// this names them, it does not retime anything.
    nonisolated static let collapseDuration: TimeInterval = 0.22
    nonisolated static let collapseCurve: (x1: Float, y1: Float, x2: Float, y2: Float)
        = (0.30, 0.90, 0.55, 1.0)

    /// Animates the panel frame to a state's rect. Resizes the panel itself,
    /// not the inner view — the hosting view and tracking area follow via
    /// autoresizing and updateTrackingAreas.
    ///
    /// Once the frame has settled, the hover view re-checks the cursor
    /// against it: a resize can strand a stationary cursor outside the panel
    /// with no mouseExited to say so. See
    /// `NotchHoverView.reevaluateHoverAfterFrameChange`.
    func setState(_ state: State, on screen: NSScreen,
                  expandedContentSize: CGSize = .zero,
                  chromeOnly: Bool = false,
                  chromeGroups: ChromeGroupWidths = ChromeGroupWidths()) {
        let visible: NSRect
        switch state {
        case .idle: visible = Self.notchRect(on: screen)
        case .compact: visible = Self.compactRect(on: screen)
        case .expanded: visible = Self.expandedRect(on: screen, contentSize: expandedContentSize,
                                                    chromeOnly: chromeOnly, chromeGroups: chromeGroups)
        }
        let label = state.rawValue + (chromeOnly && state == .expanded ? " (chrome only)" : "")
        // Inflate by the hover halo: sides and downward, top stays flush.
        var target = visible
        target.origin.x -= Self.hoverMargin
        target.size.width += Self.hoverMargin * 2
        target.origin.y -= Self.hoverMargin
        target.size.height += Self.hoverMargin

        // The overlay must fit the frame it is being given. SwiftUI offers
        // no complaint when it does not: NSHostingView centres an oversized
        // root, which visibly shoves everything up under the screen edge
        // while logging nothing — that silence is what let the chrome-only
        // bar ship clipped. `.error`, so it persists in release builds.
        if let fitting = hostingView?.fittingSize.height,
           fitting > target.height + 0.5 {
            Self.logger.error("Overlay overflows the panel: fitting height \(fitting, privacy: .public) > frame height \(target.height, privacy: .public) in state \(label, privacy: .public)")
        }

        let wasExpanded = currentState == .expanded
        currentState = state
        // The trackpad ticks as the notch snaps open — only on the way in,
        // and only when the hand is on the trackpad (the system's rule).
        if state == .expanded && !wasExpanded {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
        }

        guard target != frame else { return }

        // Every frame change from here on supersedes any animation still in
        // flight; a completion only acts if it belongs to the latest one.
        animationGeneration &+= 1
        let generation = animationGeneration

        // Hard rule 8: with Reduce Motion on, snap instead of animating.
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            setFrame(target, display: true)
            Self.logger.notice("State \(label, privacy: .public) (reduced motion) at \(NSStringFromRect(target), privacy: .public)")
            reevaluateHoverAfterFrameChange()
            return
        }

        // The bounce is the *opening*: only on the way into expanded, like
        // the haptic. An expanded-to-expanded resize (content re-measured,
        // a navigation) takes the tidy curve below instead.
        if state == .expanded && !wasExpanded {
            // Two-stage bounce: overshoot past the target in BOTH axes, then
            // settle back. Explicit stages because window-frame animation
            // clamps overshooting timing curves (control-point y > 1 was
            // silently flattened — user never felt the bounce it promised).
            // The sideways component of the overshoot is what makes opening
            // read as blooming outward, not just dropping down.
            // User-tuned subtle: half the first attempt's travel.
            var overshoot = target
            overshoot.origin.x -= 4
            overshoot.size.width += 8
            overshoot.origin.y -= 5
            overshoot.size.height += 5

            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.21
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.90, 0.45, 1.0)
                self.animator().setFrame(overshoot, display: true)
            }, completionHandler: { [weak self] in
                // AppKit invokes animation completions on the main thread;
                // assumeIsolated states that fact to the compiler (and traps
                // if it were ever violated) without deferring a runloop turn
                // the way Task would — the settle must start this tick or
                // the bounce reads as a hitch.
                MainActor.assumeIsolated {
                    // A newer setState has taken over: settling to this
                    // target now would drag the panel back to a stale frame.
                    guard let self, self.animationGeneration == generation else { return }
                    NSAnimationContext.runAnimationGroup({ context in
                        context.duration = 0.13
                        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                        self.animator().setFrame(target, display: true)
                    }, completionHandler: { [weak self] in
                        MainActor.assumeIsolated { self?.settleCompleted(generation) }
                    })
                }
            })
        } else {
            NSAnimationContext.runAnimationGroup({ context in
                // Closing, wing transitions and expanded resizes ease out
                // with no bounce so they read as tidy.
                context.duration = Self.collapseDuration
                let c = Self.collapseCurve
                context.timingFunction = CAMediaTimingFunction(controlPoints: c.x1, c.y1, c.x2, c.y2)
                animator().setFrame(target, display: true)
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated { self?.settleCompleted(generation) }
            })
        }
        Self.logger.notice("State \(label, privacy: .public) at \(NSStringFromRect(target), privacy: .public)")
    }

    /// The frame has settled somewhere new; let the hover view judge the
    /// cursor against it. Routed through the panel so the animation
    /// completions above do not reach into `contentView` themselves.
    private func reevaluateHoverAfterFrameChange() {
        (contentView as? NotchHoverView)?.reevaluateHoverAfterFrameChange(
            adoptStationaryCursor: currentState == .expanded)
    }

    /// An animation finished. Only the latest one's frame is where the panel
    /// is staying, so only it re-checks the cursor; a superseded one's
    /// completion (AppKit fires it when the newer animation cuts it short)
    /// would judge the cursor against a frame in mid-flight.
    private func settleCompleted(_ generation: Int) {
        guard generation == animationGeneration else { return }
        reevaluateHoverAfterFrameChange()
    }

    /// Clears hover outright: cancels any pending enter or exit and drops the
    /// hovering flag without reporting a change. For a screen
    /// reconfiguration, where the coordinator has already discarded its own
    /// hover state and the cursor's relation to the moved panel is unknown.
    func resetHover() {
        (contentView as? NotchHoverView)?.resetHover()
    }
}
