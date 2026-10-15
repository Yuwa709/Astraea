import AppKit
import os

/// Fills the notch panel and reports debounced hover state, from the cursor
/// or from a file drag.
///
/// Entry is debounced: the cursor must dwell `enterDebounce` seconds before
/// hover reports true, so passing traffic across the top of the screen does
/// not trigger it. Exit is verified: the panel resizes underneath the cursor
/// while animating, which makes AppKit fire spurious mouseExited events —
/// an exit only counts if the cursor is really outside the panel frame
/// `exitGrace` later.
///
/// A file drag opens the notch through exactly the same debounced path. A
/// tracking area sees only the pointer, and during a drag session AppKit
/// delivers dragging messages instead of mouse-entered ones, so without this
/// the panel stays shut and the shelf's drop zones are unreachable — there
/// is no way to drop a file into a panel that will not open. Routing drags
/// through `beginEnter`/`beginExit` rather than a parallel mechanism is what
/// keeps the debounce, the exit verification and the top-edge fix applying
/// identically to both.
final class NotchHoverView: NSView {

    private static let logger = Logger(subsystem: "com.techie.PopNotch", category: "Hover")

    /// User-tuned: 200ms let too much passing traffic through. Overridable
    /// from settings via `NotchPanel.hoverEnterDelay`.
    var enterDebounce: TimeInterval = 0.35
    private static let exitGrace: TimeInterval = 0.1

    /// Fires on every debounced state change.
    var onHoverChange: ((Bool) -> Void)?

    /// Fires the instant a file drag arrives over the notch, and again when
    /// it leaves — ahead of the debounced expansion, so a listener can choose
    /// what the panel should open *to* before it opens.
    ///
    /// Separate from `onHoverChange` on purpose: a pointer and a file
    /// arriving are different intents, and the panel should answer them
    /// differently. Folding this into the hover callback would make every
    /// listener re-derive which one happened.
    var onFileDragChange: ((Bool) -> Void)?

    private var isHovering = false
    private var pendingEnter: DispatchWorkItem?
    private var pendingExit: DispatchWorkItem?
    /// True between a file drag entering and leaving, so the exit path is
    /// only driven once per session however AppKit reports the ending.
    private var isDragActive = false

    /// True while this panel is the *source* of a drag rather than a
    /// destination for one.
    ///
    /// Collapse is suppressed for the duration: a drag-out leaves the panel
    /// bounds by design, and the normal exit rules would tear down the very
    /// view that started the drag. Clearing it re-evaluates collapse against
    /// the real cursor position — see the `didSet`, which is the re-arm that
    /// stops the panel hanging open after every drag-out.
    ///
    /// Driven by `ShelfDragSource`'s `draggingSession(_:willBeginAt:)` and
    /// `draggingSession(_:endedAt:operation:)` — the latter the one
    /// deterministic place a session is known to be over, however it ended —
    /// via `FileShelfService.onDragOutChange`, which AppDelegate routes
    /// through `NotchCoordinator.dragOutChanged` to the panel.
    var isDraggingOut = false {
        didSet {
            guard Self.clearingShouldRearmCollapse(was: oldValue, now: isDraggingOut) else { return }
            beginExit()
        }
    }

    /// Whether a change to `isDraggingOut` should re-evaluate collapse.
    ///
    /// Only the true -> false edge does. Factored out and `nonisolated` — the
    /// way `isInsideForExit` is — because the panel hanging open forever after
    /// a drag-out is precisely what a missing re-arm looks like, and that is
    /// worth a test rather than a reading of the `didSet`.
    nonisolated static func clearingShouldRearmCollapse(was: Bool, now: Bool) -> Bool {
        was && !now
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // File URLs only. Registering for everything would open the notch on
        // a text selection dragged across the menu bar.
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    // Tracking areas do not follow a resized or moved window. AppKit calls
    // this on every geometry change, so rebuilding here keeps the area
    // matched to the panel wherever reposition() puts it.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        ))
    }

    /// Whether the cursor still counts as over the panel, for the purpose of
    /// confirming an exit.
    ///
    /// `NSRect.contains` is half-open on maxY, and this panel's top edge sits
    /// flush with the screen's maxY. A cursor pinned to the top screen edge
    /// therefore reports `y == maxY` and reads as *outside* in every panel
    /// state, at every size — measured 2026-08-29: enter fired with
    /// `contains=false`, the panel expanded, the verification agreed the
    /// cursor was outside, and it collapsed straight back, oscillating on a
    /// ~320ms cycle one pixel row from the top.
    ///
    /// The enter path uses the tracking area, which is inclusive at its edge;
    /// this test was exclusive. Closing that one-row disagreement is the
    /// entire fix. Nothing is widened downward or sideways: the x test keeps
    /// `contains`'s own half-open semantics, and the y extension reaches only
    /// from the panel's top to the screen's, which is normally the same row.
    nonisolated static func isInsideForExit(mouse: NSPoint,
                                            panel: NSRect,
                                            screenTop: CGFloat) -> Bool {
        if panel.contains(mouse) { return true }
        return mouse.x >= panel.minX && mouse.x < panel.maxX
            && mouse.y >= panel.maxY && mouse.y <= screenTop
    }

    override func mouseEntered(with event: NSEvent) {
        beginEnter(fromDrag: false)
    }

    /// The one way the notch opens, whether the pointer or a file arrived.
    private func beginEnter(fromDrag: Bool) {
        // Re-entry cancels a pending exit — the cursor never really left.
        pendingExit?.cancel()
        pendingExit = nil
        guard !isHovering else { return }

        pendingEnter?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isHovering else { return }
            self.isHovering = true
            Self.logger.notice("\(fromDrag ? "Drag expanded the notch" : "Hover began", privacy: .public)")
            self.onHoverChange?(true)
        }
        pendingEnter = work
        DispatchQueue.main.asyncAfter(deadline: .now() + enterDebounce, execute: work)
    }

    override func mouseExited(with event: NSEvent) {
        beginExit()
    }

    private func beginExit() {
        // A drag-out is the panel acting as a source; the cursor being outside
        // is the whole gesture, not a reason to close. The clear in
        // `isDraggingOut` runs this again once the session really ends.
        guard !isDraggingOut else { return }
        pendingEnter?.cancel()
        pendingEnter = nil
        guard isHovering else { return }

        // Verify before collapsing: mid-animation resizes fire exits even
        // though the cursor is still over the panel.
        pendingExit?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isHovering, let window = self.window else { return }
            // The screen the panel is on; falling back to the panel's own top
            // still closes the exact-maxY case, which is the one that breaks.
            let screenTop = window.screen?.frame.maxY ?? window.frame.maxY
            guard !Self.isInsideForExit(mouse: NSEvent.mouseLocation,
                                        panel: window.frame,
                                        screenTop: screenTop) else {
                Self.logger.debug("Spurious exit ignored; cursor still inside panel")
                return
            }
            self.isHovering = false
            Self.logger.notice("Hover ended")
            self.onHoverChange?(false)
        }
        pendingExit = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.exitGrace, execute: work)
    }

    /// The panel settled at a new frame: re-check the cursor against it once.
    ///
    /// A resize can strand a stationary cursor outside the panel without
    /// AppKit saying so. The tracking area is rebuilt for the new bounds and
    /// a cursor that was never inside the new area gets no mouseExited; or
    /// an exit fires mid-animation, is verified against the still-moving
    /// frame, reads as spurious, and the panel finishes moving with the
    /// cursor outside and nothing left to fire. Either way the notch hangs
    /// open until the cursor wanders back in and out again — the chrome-only
    /// bar makes this routine, since media stopping under the cursor drops
    /// the panel from the full card to the neck.
    ///
    /// Inside is judged by the same test the verified exit uses, top-edge
    /// carve-out included, so a cursor pinned to the screen top stays inside.
    /// Nothing is synthesized when it is: a verified exit already pending
    /// will find the cursor inside and drop itself. Outside goes through
    /// `beginExit`, which re-verifies after its own grace, so this never
    /// forces a collapse by itself.
    ///
    /// The mirror case: the panel *grows* under a cursor that is not
    /// hovering — a live activity opening it while the pointer rests on the
    /// notch. A tracking area created around a cursor already inside it
    /// sends no mouseEntered, so without this the hover never registers and
    /// the panel collapses at the activity's timeout with the cursor still
    /// on it. `adoptStationaryCursor` limits that to the expanded panel: the
    /// compact wings appearing under a pointer parked in the menu bar must
    /// not open the notch. It goes through `beginEnter`, so the usual dwell
    /// still applies.
    func reevaluateHoverAfterFrameChange(adoptStationaryCursor: Bool) {
        guard !isDraggingOut, let window else { return }
        let screenTop = window.screen?.frame.maxY ?? window.frame.maxY
        let inside = Self.isInsideForExit(mouse: NSEvent.mouseLocation,
                                          panel: window.frame,
                                          screenTop: screenTop)
        switch (isHovering, inside) {
        case (true, false):
            Self.logger.notice("Frame changed under the cursor; cursor is outside the new frame, collapsing by the normal exit rules")
            beginExit()
        case (false, true) where adoptStationaryCursor:
            Self.logger.notice("Panel opened under a resting cursor; treating it as hover by the normal enter rules")
            beginEnter(fromDrag: false)
        default:
            return
        }
    }

    /// Forgets hover entirely, reporting nothing: cancels a pending enter or
    /// exit and clears `isHovering`. The coordinator calls this through the
    /// panel on a screen change, where it has already reset its own hover
    /// flag. Without it `isHovering` stayed true, `beginEnter` early-returned
    /// on its guard, and the notch would not open again until the cursor
    /// left and re-entered.
    func resetHover() {
        pendingEnter?.cancel()
        pendingEnter = nil
        pendingExit?.cancel()
        pendingExit = nil
        if isHovering {
            isHovering = false
            Self.logger.notice("Hover reset by a screen change")
        }
    }

    deinit {
        pendingEnter?.cancel()
        pendingExit?.cancel()
    }

    // MARK: - Dragging destination

    /// A file drag arriving over the collapsed notch opens it, so the
    /// shelf's drop zones become reachable.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard Self.carriesFiles(sender) else { return [] }
        // A drag that started on this panel's own shelf: skip the drag
        // bookkeeping entirely, so the chooser never replaces the homepage
        // whose AirDrop bar is the drop target. The chooser is for files
        // *arriving* at the notch. `.copy` still keeps the session tracking
        // us so the shelf's own zones receive the drop.
        guard !isDraggingOut else { return .copy }
        isDragActive = true
        Self.logger.notice("Drag entered the notch")
        // Announced before the expansion is scheduled, so the destination is
        // already chosen by the time the panel opens.
        onFileDragChange?(true)
        beginEnter(fromDrag: true)
        // `.copy` keeps the session tracking us so `draggingExited` arrives.
        // It does not mean this view will take the drop: that is refused
        // below, leaving the expanded content's own zones to accept it.
        return .copy
    }

    /// AppKit sends `draggingExited` to an outer destination the moment the
    /// drag descends into a destination nested inside it — measured 18ms
    /// after `draggingEntered`, session still live. Believing it tore the
    /// chooser down exactly when the cursor reached one of its zones. So an
    /// exit only counts if the cursor has really left the panel, using the
    /// same inclusive top-edge carve-out the hover exit is documented with
    /// (`contains` is half-open on maxY, and the panel tops out at the
    /// screen edge).
    override func draggingExited(_ sender: NSDraggingInfo?) {
        if let window, Self.isInsideForExit(
            mouse: NSEvent.mouseLocation,
            panel: window.frame,
            screenTop: window.screen?.frame.maxY ?? window.frame.maxY) {
            Self.logger.debug("Drag exit ignored; cursor still over the panel")
            return
        }
        endDrag(reason: "exited")
    }

    /// Belt and braces: a session that ends by dropping elsewhere, or is
    /// cancelled, may not send `draggingExited`. Without this the notch
    /// would stay open until the pointer happened to leave.
    override func draggingEnded(_ sender: NSDraggingInfo) {
        endDrag(reason: "ended")
    }

    private func endDrag(reason: String) {
        guard isDragActive else { return }
        isDragActive = false
        Self.logger.notice("Drag \(reason, privacy: .public); collapsing by the normal exit rules")
        onFileDragChange?(false)
        // The same verified, grace-delayed exit the pointer uses, so the
        // top-edge fix and the spurious-exit guard apply unchanged.
        beginExit()
    }

    /// This view never consumes a drop. It exists to open the panel; the
    /// shelf's own zones, which sit above it once expanded, do the accepting.
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { false }

    static func carriesFiles(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingPasteboard.canReadObject(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }
}
