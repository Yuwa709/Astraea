import AppKit
import SwiftUI
import os

/// Connects the arbiter's decisions to the panel on screen.
///
/// This is the only place that knows about both. `NotchArbiter` stays free of
/// AppKit so it can be tested; `NotchPanel` stays free of feature logic so it
/// only draws. Modules touch neither.
///
/// Owns: panel lifecycle, screen placement, hover, and the single expiry
/// timer. Registering a module here is the "one place" the Phase 2 goal
/// requires — adding a feature is one new file plus one `register` call.
@MainActor
final class NotchCoordinator {

    private static let logger = Logger(subsystem: "com.techie.Astraea", category: "Coordinator")

    private let arbiter: NotchArbiter
    private let settings: SettingsStore
    private var panel: NotchPanel?
    private var currentScreen: NSScreen?

    /// One-shot, scheduled only while an activity is running and invalidated
    /// the moment it is not. Hard rule 9: no timer exists at rest.
    private var expiryTimer: Timer?

    private var isHovered = false

    /// True while another app's window is being dragged over the notch.
    /// Counts as hover: the button is held in that app, so the panel's own
    /// tracking area never reports the cursor arriving.
    private var isWindowDragOver = false

    /// `arbiter` is injectable for tests. Defaulted via nil rather than
    /// `= NotchArbiter()`, because a default argument is evaluated in a
    /// nonisolated context and the arbiter is `@MainActor`.
    /// Panel-level, not module-level: keeping the Mac awake is a property of
    /// the app, not of anything the notch happens to be showing, so the
    /// control renders as panel chrome whenever the panel is expanded rather
    /// than living inside a module's view. Nil in tests.
    /// Where the expanded panel is, beyond what the arbiter chose.
    ///
    /// `.standby` is the arbitrated default (media, stats, live activities).
    /// Every other case is a full-panel screen a chrome control navigated
    /// to. Future screens add a case here and a branch in `content(for:)` —
    /// the reset-on-collapse and disabled-module fallbacks come for free.
    enum Destination: Equatable {
        case standby
        case clipboard
        case fileShelf
        case systemStats
        case appVolume
        /// The window layout picker. No door leads here: only a window
        /// dragged into the notch opens it.
        case windowLayout

        /// The module a screen belongs to, so the disabled-module fallbacks
        /// stay one rule rather than one branch per destination.
        var moduleID: ModuleID? {
            switch self {
            case .standby: nil
            case .clipboard: "clipboard"
            case .fileShelf: "file-shelf"
            case .systemStats: "system-stats"
            case .appVolume: "app-volume"
            case .windowLayout: "window-layout"
            }
        }
    }

    /// The two services the stats page reads, bundled so the coordinator
    /// takes one dependency rather than two. Nil in tests and wherever the
    /// page is not wired up, which hides its door rather than opening onto
    /// an empty screen.
    struct StatsPageServices {
        let stats: SystemStatsService
        let battery: BatteryService

        init(stats: SystemStatsService, battery: BatteryService) {
            self.stats = stats
            self.battery = battery
        }
    }

    /// Owned here because the coordinator already owns what the panel shows.
    /// Not persisted: a screen is a place you went, not a preference.
    ///
    /// The `didSet` is where the stats page's sampling is started and
    /// stopped. Destination is assigned from six places — `navigate`, the
    /// collapse reset in `applyState`, `setEnabled`, and three in the file
    /// drag path — and hanging the lifecycle on the property means none of
    /// them can forget, the same argument `applyState` makes for being the
    /// sole caller of `panel.setState`.
    private(set) var destination: Destination = .standby {
        didSet {
            guard oldValue != destination else { return }
            if oldValue == .systemStats { setStatsPageObserving(false) }
            if destination == .systemStats { setStatsPageObserving(true) }
            // Not a sampling lifecycle: watching is toggle-driven and
            // event-driven. This re-prunes the session rows, so an app that
            // quit since the last audio event is not still listed, and reads
            // Spotify's and Music's current volume for their rows.
            if destination == .appVolume { appVolume?.pageDidOpen() }
        }
    }

    /// Starts and stops the page's two subscriber-counted services together:
    /// one subscriber each while the page is open, zero when it closes.
    ///
    /// Nothing samples while the page is closed. The 24-hour charge history
    /// that used to keep sampling here was removed on 2026-10-07: it filled
    /// only while the page was open, and nobody keeps it open.
    private func setStatsPageObserving(_ observing: Bool) {
        guard let statsPage else { return }
        if observing {
            statsPage.stats.start()
            statsPage.battery.start()
            Self.logger.notice("Stats page opened; sampling started")
        } else {
            statsPage.stats.stop()
            statsPage.battery.stop()
            Self.logger.notice("Stats page closed; sampling stopped")
        }
    }

    /// The page the panel was on when it last collapsed, kept for the
    /// "Reopen last page" setting. Session only, like `destination`.
    ///
    /// Remembered rather than left in `destination`: the collapse reset
    /// still runs, so the stats page's sampling stops behind a closed notch
    /// (hard rule 9). The page is put back on the next hover instead.
    private var lastClosedDestination: Destination = .standby

    /// Session-only pin. Nil in tests that do not care about it.
    private let pinState: PinState?

    /// Whether the notch is currently held open.
    var isPinned: Bool { pinState?.isPinned ?? false }

    /// Pins or unpins, then re-evaluates.
    ///
    /// Unpinning needs no cursor check of its own: hover bookkeeping keeps
    /// running underneath a pin (nothing suppresses it), so `isHovered` is
    /// already correct here. `applyState` therefore collapses when the cursor
    /// is away and holds when it is inside, which is exactly the required
    /// behaviour, for free.
    func setPinned(_ pinned: Bool) {
        guard let pinState, pinState.isPinned != pinned else { return }
        pinState.isPinned = pinned
        Self.logger.notice("Notch \(pinned ? "pinned open" : "unpinned", privacy: .public)")
        renderContent()
        applyState()
    }

    private let caffeinate: CaffeinateService?

    /// The stats page's services, or nil where the page is not wired up.
    private let statsPage: StatsPageServices?

    /// The mixer page's service, or nil where the page is not wired up —
    /// which hides its door, the same rule `statsPage` follows.
    private let appVolume: AppVolumeService?

    init(settings: SettingsStore,
         arbiter: NotchArbiter? = nil,
         caffeinate: CaffeinateService? = nil,
         pinState: PinState? = nil,
         statsPage: StatsPageServices? = nil,
         appVolume: AppVolumeService? = nil) {
        self.settings = settings
        self.pinState = pinState
        self.caffeinate = caffeinate
        self.statsPage = statsPage
        self.appVolume = appVolume
        self.arbiter = arbiter ?? NotchArbiter()
        self.arbiter.onPresentationChange = { [weak self] presentation in
            self?.presentationChanged(presentation)
        }
        self.arbiter.onExpiryChange = { [weak self] in
            self?.scheduleExpiry()
        }
        // The mixer page's height follows its row count, and rows come and
        // go with audio events while the page is open — re-measure then, or
        // a new row draws into a panel sized for one fewer. Guarded to the
        // page itself so audio events never re-render other screens.
        appVolume?.onRowsChange = { [weak self] in
            guard let self, self.destination == .appVolume else { return }
            self.renderContent()
            self.applyState()
        }
    }

    deinit {
        expiryTimer?.invalidate()
    }

    // MARK: - Lifecycle

    func start() {
        guard let screen = ScreenPolicy.targetScreen() else {
            Self.logger.error("No target screen; panel not created")
            return
        }

        let panel = NotchPanel(screen: screen)
        panel.hoverEnterDelay = settings.settings.hoverEnterDelay
        panel.onFileDragChange = { [weak self] active in
            self?.fileDragChanged(active)
        }
        panel.onHoverChange = { [weak self] hovering in
            self?.hoverChanged(hovering)
        }
        self.panel = panel
        reposition(reason: "launch")

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    func stop() {
        NotificationCenter.default.removeObserver(self)
        expiryTimer?.invalidate()
        expiryTimer = nil
    }

    /// Registers a feature. The one place adding a module touches.
    ///
    /// The stored preference is applied here rather than by the caller, so a
    /// module can never be registered in a state that disagrees with what the
    /// user chose.
    func register(_ module: any NotchModule, enabledByDefault: Bool = true) {
        module.isEnabled = settings.isEnabled(module.id, default: enabledByDefault)
        arbiter.register(module)
    }

    /// What Settings lists: one row per registered module.
    var moduleSummaries: [(id: ModuleID, displayName: String, isEnabled: Bool)] {
        arbiter.registeredModules.map { ($0.id, $0.displayName, $0.isEnabled) }
    }

    /// Toggles a module from Settings: persists the choice, updates the live
    /// module, and re-runs arbitration so the notch reflects it immediately.
    func setEnabled(_ enabled: Bool, for id: ModuleID) {
        guard let module = arbiter.module(for: id) else { return }
        module.isEnabled = enabled
        settings.setEnabled(enabled, for: id)
        if !enabled, destination.moduleID == id {
            destination = .standby
        }
        arbiter.enablementDidChange()
        renderContent()
        applyState()
    }

    func requestLiveActivity(_ request: LiveActivityRequest) {
        arbiter.requestLiveActivity(request)
    }

    /// From Settings. Read at the next hover, so nothing on screen changes.
    func setReopenLastPage(_ enabled: Bool) {
        settings.update { $0.reopenLastPage = enabled }
        Self.logger.notice("Reopen last page \(enabled ? "on" : "off", privacy: .public)")
    }

    /// From Settings: persists and applies to the live panel immediately.
    func setHoverDelay(_ delay: TimeInterval) {
        settings.update { $0.hoverEnterDelay = delay }
        panel?.hoverEnterDelay = delay
    }

    // MARK: - Screen placement

    @objc private func screenParametersDidChange(_ notification: Notification) {
        reposition(reason: "screen parameters changed")
    }

    /// Recomputes the target screen and geometry. A display change collapses
    /// the panel: hover is invalid across a reconfiguration anyway.
    private func reposition(reason: String) {
        guard let panel else { return }

        // Both the coordinator's hover flag and the hover view's: clearing
        // only this one left the view believing it was still hovered, and
        // its enter guard then refused to open the notch until the cursor
        // left and came back.
        isHovered = false
        panel.resetHover()

        guard let screen = ScreenPolicy.targetScreen() else {
            Self.logger.error("Reposition (\(reason, privacy: .public)): no target screen; hiding panel")
            currentScreen = nil
            panel.orderOut(nil)
            // Off screen counts as collapsed. `applyState` cannot run without
            // a screen, so its collapse bookkeeping runs here instead —
            // modules hear `notchDidCollapse` and a navigated screen resets —
            // or stats sampling would keep running behind a hidden panel.
            resetOnCollapse(to: .idle)
            lastAppliedState = .idle
            // And nothing may poll for a hidden panel.
            arbiter.panelDidApply(.collapsed)
            return
        }

        currentScreen = screen
        let frame = NotchPanel.notchRect(on: screen)
        panel.setFrame(frame, display: true)
        renderContent()

        // orderFrontRegardless, not orderFront: this background agent is never
        // the active app, and must never become it (hard rule 4).
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }

        // The one `.notice` record of the notch geometry: `notchRect(on:)`
        // runs several times per state change and logs at `.debug`; this
        // runs once per real screen change.
        let leftWidth = screen.auxiliaryTopLeftArea?.width ?? -1
        let rightWidth = screen.auxiliaryTopRightArea?.width ?? -1
        Self.logger.notice("Reposition (\(reason, privacy: .public)): notch rect \(NSStringFromRect(frame), privacy: .public) on \(screen.localizedName, privacy: .public) (screen frame \(NSStringFromRect(screen.frame), privacy: .public), visible frame \(NSStringFromRect(screen.visibleFrame), privacy: .public), safeAreaInsets.top \(screen.safeAreaInsets.top, privacy: .public), auxiliary widths \(leftWidth, privacy: .public)/\(rightWidth, privacy: .public); -1 = none)")
        applyState()
    }

    // MARK: - Presentation

    private func hoverChanged(_ hovering: Bool) {
        isHovered = hovering
        if hovering { reopenLastPageIfWanted() }
        // Content depends on expansion, not just presentation: an expanded
        // notch shows each module's richer view.
        renderContent()
        applyState()
    }

    private func presentationChanged(_ presentation: NotchPresentation) {
        renderContent()
        applyState()
    }

    /// Re-evaluates size and content. Public for modules whose collapsed
    /// presence changes — e.g. music starting or stopping flips the panel
    /// between invisible and the compact wings.
    func refreshPresentation() {
        renderContent()
        applyState()
    }

    /// Expanded while hovered or during a live activity; compact wings when
    /// a standby module has something worth flanking the housing with;
    /// otherwise invisible.
    /// The one place expansion is decided, and therefore the one place the
    /// pin is honoured.
    ///
    /// Every collapse in the app — hover exit, `endDrag`, the drag-out
    /// re-arm, an arbiter presentation change, a module toggle, navigation,
    /// a screen reconfiguration, a shelf mode swap — routes through
    /// `applyState`, which is the sole caller of `panel.setState`. Guarding
    /// here covers all of them; guarding at each trigger would mean nine
    /// checks and one of them eventually missed.
    private func desiredState() -> NotchPanel.State {
        if Self.shouldExpand(isPinned: isPinned,
                             isHovered: isHovered || isWindowDragOver,
                             hasLiveActivity: isShowingLiveActivity) { return .expanded }
        if standbyWings() != nil { return .compact }
        return .idle
    }

    /// Factored out and `nonisolated` — the way `isInsideForExit` is — so the
    /// pin's precedence over every other input is a test rather than a
    /// reading of the branch above.
    nonisolated static func shouldExpand(isPinned: Bool,
                                         isHovered: Bool,
                                         hasLiveActivity: Bool) -> Bool {
        isPinned || isHovered || hasLiveActivity
    }

    /// Measured size of the current expanded content, set by renderContent.
    private var expandedContentSize: CGSize = .zero

    /// Measured widths of the two chrome groups, set alongside
    /// `expandedContentSize`; the chrome-only frame is sized from them.
    private var chromeGroups = NotchPanel.ChromeGroupWidths()

    /// Whether the expanded panel is chrome alone, as last rendered.
    private var isChromeOnly = false

    /// The state most recently applied to the panel, so renderContent can
    /// tell an entrance (play the reveal) from an in-place update (do not).
    private var lastAppliedState: NotchPanel.State = .idle

    /// A file drag opens the notch straight to the shelf, because opening to
    /// the home screen would be useless: there is nowhere on it to drop.
    ///
    /// The destination is set rather than navigated to. At this moment the
    /// panel is still collapsed — the debounced expansion has only been
    /// scheduled — so `navigate` would render compact content that the
    /// expansion immediately replaces. Setting it means the panel opens
    /// already showing the shelf.
    /// Fed the raw drag-over state so the shelf can swap between its resting
    /// screen and the drop chooser. Set by AppDelegate; the coordinator does
    /// not know the service, only that someone wants the signal.
    var onFileDragActive: ((Bool) -> Void)?

    /// The reverse direction: a drag *out of* the panel holds collapse off
    /// until the session ends. Forwarded here so the shelf module never
    /// references the panel; wired by AppDelegate.
    func dragOutChanged(_ active: Bool) {
        panel?.isDraggingOut = active
    }

    func fileDragChanged(_ active: Bool) {
        // Before any render below, so a re-measure already sees the mode the
        // view is about to display.
        onFileDragActive?(active)
        guard active else {
            // A drag that leaves before the panel ever opened set a
            // destination for a screen nobody saw. Clear it, or the next
            // plain hover would open to the shelf. Once expanded, the normal
            // collapse reset in `applyState` owns this instead.
            if lastAppliedState != .expanded, destination != .standby {
                destination = .standby
                Self.logger.notice("Drag left before opening; destination reset")
            }
            // The chooser just swapped back to the resting shelf, which is a
            // different size; re-measure or the panel keeps the old frame.
            remeasureShelfIfShowing()
            return
        }
        guard let moduleID = Destination.fileShelf.moduleID,
              arbiter.module(for: moduleID)?.isEnabled == true else {
            // Shelf switched off: a file drag is just a hover, and the panel
            // opens home as usual.
            return
        }
        if destination != .fileShelf {
            destination = .fileShelf
            Self.logger.notice("File drag; opening to the shelf")
            // Panel already expanded on another screen when the drag arrived:
            // swap to the shelf now. This is the chooser *appearing* — the
            // one resize a live drag wants, and the cursor is still at the
            // panel edge when it happens. Every later flip while the session
            // is live re-renders by observation alone; resizing the panel
            // mid-drag would move drop targets under the cursor.
            remeasureShelfIfShowing()
        }
    }

    /// Re-renders the shelf screen in place. The chooser and the resting
    /// shelf are different widths, and the panel only resizes when someone
    /// re-measures; destination changes do that, an in-place mode swap does
    /// not.
    private func remeasureShelfIfShowing() {
        guard lastAppliedState == .expanded, destination == .fileShelf else { return }
        renderContent()
        applyState()
    }

    // MARK: - Window drags

    /// How far either side of the housing a dragged window's cursor still
    /// opens the picker. The housing alone is a small target to hit while
    /// hauling a window; this is wider, never taller.
    nonisolated static let windowDragSlop: CGFloat = 40

    /// A window drag's cursor moved, in AppKit screen coordinates. Opens the
    /// picker when it reaches the notch and closes it when it leaves.
    /// Returns whether the cursor is over the notch.
    ///
    /// Opens immediately, with no hover dwell: hauling a window to the top
    /// of the screen is not passing traffic.
    @discardableResult
    func windowDragMoved(to point: CGPoint) -> Bool {
        guard let panel, let screen = currentScreen, isDoorAvailable(.windowLayout) else {
            return false
        }
        let housing = NotchPanel.notchRect(on: screen).insetBy(dx: -Self.windowDragSlop, dy: 0)
        // Once open, the whole panel counts — the zones hang below the
        // housing. The union keeps a cursor in the slop inside while the
        // panel is still growing past it.
        let target = isWindowDragOver ? panel.frame.union(housing) : housing
        let over = NotchHoverView.isInsideForExit(mouse: point, panel: target,
                                                  screenTop: screen.frame.maxY)
        guard over != isWindowDragOver else { return over }
        isWindowDragOver = over
        if over {
            destination = .windowLayout
            Self.logger.notice("Window dragged over the notch; opening the layout picker")
        } else {
            leaveWindowLayoutIfStillOpen()
            Self.logger.notice("Window dragged off the notch; closing the layout picker")
        }
        renderContent()
        applyState()
        return over
    }

    /// The window drag is over: the notch closes by the usual rules.
    func windowDragEnded() {
        guard isWindowDragOver || destination == .windowLayout else { return }
        isWindowDragOver = false
        leaveWindowLayoutIfStillOpen()
        renderContent()
        applyState()
    }

    /// When the panel stays open without the drag — pinned, or the hover
    /// view saw the cursor — go home rather than leave an empty picker up.
    /// A collapse needs nothing: `resetOnCollapse` resets the destination.
    private func leaveWindowLayoutIfStillOpen() {
        guard destination == .windowLayout,
              Self.shouldExpand(isPinned: isPinned, isHovered: isHovered,
                                hasLiveActivity: isShowingLiveActivity) else { return }
        destination = .standby
    }

    /// Chrome controls call this; it re-renders and re-measures, since
    /// destinations differ in size.
    func navigate(to destination: Destination) {
        guard destination != self.destination else { return }
        self.destination = destination
        renderContent()
        applyState()
    }

    private func applyState() {
        guard let panel, let screen = currentScreen else { return }
        let state = desiredState()
        resetOnCollapse(to: state)
        panel.setState(state, on: screen,
                       expandedContentSize: expandedContentSize,
                       chromeOnly: isChromeOnly,
                       chromeGroups: chromeGroups)
        lastAppliedState = state
        // Visibility follows what the panel now shows, not what the arbiter
        // presented: behind the collapsed wings or a navigated screen, the
        // standby modules are off screen and their timers stop (hard rule 9).
        arbiter.panelDidApply(surface(for: state))
        // The audio visualiser follows from the line above: MediaModule hears
        // its visibility there, and allows capture only while the player
        // screen, whose progress row draws the spectrum, is on screen.
    }

    /// The collapse bookkeeping, run on the way out of expanded: modules hear
    /// `notchDidCollapse`, and the destination resets. Shared by `applyState`
    /// and the no-screen branch of `reposition`, which hides the panel
    /// without being able to call `applyState`.
    private func resetOnCollapse(to state: NotchPanel.State) {
        guard lastAppliedState == .expanded && state != .expanded else { return }
        arbiter.registeredModules.forEach { $0.notchDidCollapse() }
        // The picker is not a page to come back to: reopening it on the next
        // hover would show zones with no window to place.
        // A screen is not a place to still be on the next hover — the
        // panel reopens on the arbitrated default, matching how the
        // full-lyrics takeover resets. Unless the user asked otherwise:
        // `reopenLastPageIfWanted` puts it back on the way in.
        if destination != .windowLayout {
            lastClosedDestination = destination
        }
        destination = .standby
    }

    /// Restores the page the panel last closed on, when the setting is on
    /// and the hover is what is opening the panel.
    private func reopenLastPageIfWanted() {
        guard let page = Self.pageToReopen(
            settingEnabled: settings.settings.reopenLastPage,
            remembered: lastClosedDestination,
            current: destination,
            panelAlreadyOpen: lastAppliedState == .expanded,
            isAvailable: isDoorAvailable(lastClosedDestination)) else { return }
        destination = page
        Self.logger.notice("Hover reopened the last page: \(String(describing: page), privacy: .public)")
    }

    /// The page a hover should reopen, or nil to open as usual.
    ///
    /// Nil when the panel is already open — a live activity or the pin got
    /// there first and the user is looking at it — and when something has
    /// already chosen a page: a file drag sets the shelf before the hover
    /// it triggers lands. Nil too for a page whose module was switched off
    /// since, which would otherwise fall through to the stack anyway.
    /// Factored out so those rules are tests rather than a reading.
    static func pageToReopen(settingEnabled: Bool,
                             remembered: Destination,
                             current: Destination,
                             panelAlreadyOpen: Bool,
                             isAvailable: Bool) -> Destination? {
        guard settingEnabled, !panelAlreadyOpen, current == .standby,
              remembered != .standby, isAvailable else { return nil }
        return remembered
    }

    /// Open on a navigated screen only when `content(for:)` really shows
    /// it. `isDoorAvailable` is the same registered-and-enabled test that
    /// function falls through to the stack on, so the two cannot disagree.
    private func surface(for state: NotchPanel.State) -> PanelSurface {
        guard state == .expanded else { return .collapsed }
        return isDoorAvailable(destination) ? .navigated : .expanded
    }

    /// Measures what the expanded panel is about to display by laying the
    /// same padded content out in a throwaway hosting view. Synchronous and
    /// cheap at this size; runs only on content changes, never per frame.
    private func measureExpandedContent(_ content: AnyView?, neck: CGFloat) -> CGSize {
        guard let content else { return .zero }
        // Padding mirrors NotchOverlayView's exactly, or the measured panel
        // will not fit the rendered content.
        let probe = NSHostingView(rootView:
            content
                .padding(.top, neck + 20)
                .padding(.horizontal, 32)
                .padding(.bottom, 20)
        )
        return probe.fittingSize
    }

    /// Measures a chrome group the way `measureExpandedContent` measures
    /// content: one throwaway layout pass. Measured, never assumed — the
    /// leading group changes with which doors are enabled.
    private static func measureAccessoryWidth(_ view: AnyView?) -> CGFloat {
        guard let view else { return 0 }
        return NSHostingView(rootView: view).fittingSize.width
    }

    /// Chrome alone: nothing navigated to, and no module on the notch has
    /// anything to show in its expanded view. The modules asked are the
    /// ones the arbiter is presenting — the doors' modules are never in
    /// standby (`wantsCompactDisplay` is false) and are reached only by
    /// navigating, which the first clause already covers.
    private func chromeOnly() -> Bool {
        guard destination == .standby else { return false }
        return !presentedModules().contains { $0.hasExpandedContent }
    }

    /// The enabled modules whose expanded views `content(for:)` stacks.
    private func presentedModules() -> [any NotchModule] {
        let ids: [ModuleID]
        switch arbiter.presentation {
        case .standby(let standby): ids = standby
        case .liveActivity(let id): ids = [id]
        }
        return ids.compactMap { arbiter.module(for: $0) }.filter { $0.isEnabled }
    }

    private var isShowingLiveActivity: Bool {
        if case .liveActivity = arbiter.presentation { return true }
        return false
    }

    /// The first standby module offering wing content provides both wings.
    private func standbyWings() -> (leading: AnyView?, trailing: AnyView?)? {
        guard case .standby(let ids) = arbiter.presentation else { return nil }
        for id in ids {
            guard let module = arbiter.module(for: id) else { continue }
            let leading = module.makeCompactLeadingView()
            let trailing = module.makeCompactTrailingView()
            if leading != nil || trailing != nil {
                return (leading, trailing)
            }
        }
        return nil
    }

    private func renderContent() {
        guard let panel, let screen = currentScreen else { return }
        let housing = NotchPanel.notchRect(on: screen)
        let neck = housing.height
        switch desiredState() {
        case .expanded:
            let chromeOnly = chromeOnly()
            // Chrome-only still hands the overlay a content view, empty or
            // not: nil is what tells it to draw the compact silhouette and
            // drop the band, and the band is the whole point of the state.
            // The overlay suppresses the content region itself, padding and
            // all, on the flag — an "empty" view still carries neck+40 of
            // fixed padding, which is taller than the whole chrome-only bar.
            let view = content(for: arbiter.presentation) ?? AnyView(EmptyView())
            expandedContentSize = measureExpandedContent(view, neck: neck)
            let leading = leadingAccessory()
            let trailing = trailingAccessory()
            chromeGroups = NotchPanel.ChromeGroupWidths(
                leading: Self.measureAccessoryWidth(leading),
                trailing: Self.measureAccessoryWidth(trailing))
            if chromeOnly != isChromeOnly {
                Self.logger.notice("Expanded panel \(chromeOnly ? "chrome-only, nothing to show" : "showing content", privacy: .public); chrome groups \(self.chromeGroups.leading, privacy: .public) + \(self.chromeGroups.trailing, privacy: .public)")
            }
            isChromeOnly = chromeOnly
            // Where the housing lands inside the frame the panel is about
            // to occupy, so the band can flank it by position. Computed
            // from the same pure function `setState` uses with the same
            // inputs, so the two cannot disagree.
            let rect = NotchPanel.expandedRect(housing: housing,
                                               contentSize: expandedContentSize,
                                               chromeOnly: chromeOnly,
                                               chromeGroups: chromeGroups)
            let housingLocal = (housing.minX - rect.minX)...(housing.maxX - rect.minX)
            // The floor in `expandedRect` is derived so the housing clamp
            // never fires. If it does, the floor and the band layout have
            // drifted apart and a button is sitting somewhere other than
            // its corner — visible, but easy to mistake for a design choice
            // (which is how the last two band bugs survived).
            let band = NotchOverlayView.bandLayout(panelWidth: rect.width,
                                                   housingLocal: housingLocal,
                                                   groups: chromeGroups)
            if band.isClamped {
                Self.logger.error("Chrome band clamped off the panel corner: panel \(rect.width, privacy: .public)pt, groups \(self.chromeGroups.leading, privacy: .public)+\(self.chromeGroups.trailing, privacy: .public), insets \(band.leadingInset, privacy: .public)/\(band.trailingInset, privacy: .public), floor \(NotchPanel.bandMinWidth(housingWidth: housing.width, groups: self.chromeGroups), privacy: .public)")
            }
            // The emerge entrance plays only when the panel is opening —
            // content swaps mid-display (lyrics arriving, hover re-renders)
            // must not re-bloom. Hard rule 8: skipped under Reduce Motion.
            let entering = lastAppliedState != .expanded
                && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            panel.setContent(view, neckHeight: neck,
                             housingLocalRange: housingLocal,
                             panelWidth: rect.width,
                             chromeGroups: chromeGroups,
                             chromeOnly: chromeOnly,
                             reveal: entering,
                             topLeadingAccessory: leading,
                             topTrailingAccessory: trailing)
        case .compact:
            isChromeOnly = false
            let wings = standbyWings()
            panel.setContent(nil, leadingWing: wings?.leading, trailingWing: wings?.trailing,
                             neckHeight: neck)
        case .idle:
            isChromeOnly = false
            panel.setContent(nil, neckHeight: neck)
        }
    }

    /// Top-left chrome: the way back out of a navigated screen, or the way
    /// into Settings while in standby.
    private func leadingAccessory() -> AnyView? {
        guard destination == .standby else {
            return AnyView(PanelChromeButton(symbol: "chevron.backward", help: "Back") {
                [weak self] in self?.navigate(to: .standby)
            })
        }
        // Settings first, then a door per enabled screen. Doors are
        // navigation and so is Back, which replaces this whole group on a
        // navigated screen — they belong on the same side, not opposite the
        // control that undoes them.
        let doors = availableDoors()
        return AnyView(HStack(spacing: 2) {
            PanelChromeButton(symbol: "gearshape", help: "Settings") {
                [weak self] in self?.openSettings()
            }
            ForEach(doors, id: \.1) { destination, symbol, help in
                PanelChromeButton(symbol: symbol, help: help) {
                    [weak self] in self?.navigate(to: destination)
                }
            }
        })
    }

    /// Screens reachable right now: a door only exists while the feature
    /// behind it is on. The mixer door additionally requires the service —
    /// nil in tests and wherever the page is not wired up, the same rule as
    /// the stats door's `statsPage` check.
    private func availableDoors() -> [(Destination, String, String)] {
        var doors: [(Destination, String, String)] = [
            (.clipboard, "doc.on.clipboard", "Clipboard history"),
            (.fileShelf, "tray.full", "File shelf"),
        ]
        if appVolume != nil {
            // Not the player's speaker: the door is the whole mixer, the
            // speaker is one player's volume, and one glyph for both read as
            // a duplicate control.
            doors.append((.appVolume, "slider.horizontal.3", "App volume"))
        }
        return doors.filter { isDoorAvailable($0.0) }
    }

    /// Whether a destination's module is registered and switched on. The one
    /// rule both accessory groups filter by, so the trailing stats door
    /// disappears from Settings exactly the way the leading doors do.
    private func isDoorAvailable(_ destination: Destination) -> Bool {
        guard let moduleID = destination.moduleID else { return false }
        return arbiter.module(for: moduleID)?.isEnabled == true
    }

    /// Opens the settings window from the panel's gear.
    ///
    /// **`@Environment(\.openSettings)` does not work here.** SwiftUI fills
    /// that value in for views inside the `App`'s scene graph, next to the
    /// `Settings` scene that services it. This panel is not in that graph:
    /// `AppDelegate` builds `NotchPanel` itself and hosts its SwiftUI in an
    /// `NSHostingView`, so the environment value is never populated and
    /// calling it does nothing at all. The selector is the only route from
    /// here. `SettingsMenuItem` in AstraeaApp.swift *can* use the
    /// environment, because it genuinely is in the scene graph.
    private func openSettings() {
        // Hard rule 4 carve-out, the same narrow one SettingsMenuItem
        // documents: activation is a direct response to the user clicking
        // this button, and without it the window opens behind the frontmost
        // app. No hover path activates anything, ever.
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .astraeaOpenSettings, object: nil)
        // Verify by looking for the window, not by trusting a return value.
        // The previous implementation logged `sendAction`'s Bool, which
        // measured **true while creating no window at all** — it reported
        // eleven successes for a button the user was watching do nothing.
        // A signal that cannot fail is not a signal.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            if Self.settingsWindow() != nil {
                Self.logger.notice("Settings opened from panel chrome")
            } else {
                Self.logger.error("Settings did not open; no settings window exists")
            }
        }
    }

    /// SwiftUI names its `Settings` scene window with a stable identifier.
    nonisolated static func settingsWindow() -> NSWindow? {
        MainActor.assumeIsolated {
            NSApp.windows.first {
                ($0.identifier?.rawValue ?? "").contains("Settings")
                    || $0.title.localizedCaseInsensitiveContains("settings")
            }
        }
    }

    /// Top-right chrome: the panel-level toggles, hard into the corner.
    ///
    /// Shown for the whole expanded state, independent of which modules are
    /// on screen or whether anything is playing. Navigation lives on the
    /// leading side; these two change how the panel itself behaves.
    private func trailingAccessory() -> AnyView? {
        // Bound outside the ViewBuilder so the view captures the service, not
        // this coordinator: the panel retains the view, and the coordinator
        // retains the panel.
        let keepAwake = caffeinate
        let pinned = isPinned
        let canPin = pinState != nil
        // The stats door, like the leading doors, exists only while the
        // feature behind it is on — and only where the page has services to
        // read. Unlike them it lives here, and it stays put while its own
        // screen is open rather than being replaced by the back chevron.
        let showStats = statsPage != nil && isDoorAvailable(.systemStats)
        let onStatsPage = destination == .systemStats
        guard showStats || keepAwake != nil || canPin else { return nil }
        return AnyView(HStack(spacing: 2) {
            if showStats {
                PanelChromeButton(symbol: "chart.bar.xaxis",
                                  help: onStatsPage ? "System stats (showing)" : "System stats",
                                  isActive: !onStatsPage) { [weak self] in
                    self?.navigate(to: .systemStats)
                }
            }
            if let keepAwake {
                CaffeinateControl(service: keepAwake)
            }
            if canPin {
                PinControl(isPinned: pinned) { [weak self] in
                    self?.setPinned(!pinned)
                }
            }
        })
    }

    /// Builds the SwiftUI content for the open panel.
    ///
    /// In standby the modules' expanded views stack; a live activity gets the
    /// notch to itself. Only `renderContent`'s expanded branch calls this —
    /// the collapsed panel draws wings, not content — so the compact-view
    /// branch at the bottom is unreachable today. Kept, not deleted.
    private func content(for presentation: NotchPresentation) -> AnyView? {
        // Ahead of the arbiter: a window held over the notch is the user
        // acting right now, and must not be hidden behind a track change.
        if isWindowDragOver, destination == .windowLayout,
           let module = arbiter.module(for: "window-layout"), module.isEnabled {
            return module.makeExpandedView()
        }
        switch presentation {
        case .standby(let ids):
            let modules = ids.compactMap { arbiter.module(for: $0) }
            guard !modules.isEmpty else { return nil }
            // Expanded content whenever the panel is expanded for ANY reason
            // — hover, live activity, or a pinned takeover. Keying this off
            // the cursor alone swapped in compact content (and shrank the
            // panel around it) the moment the cursor left a pinned lyrics
            // view: user-observed bug.
            if desiredState() == .expanded {
                // The stats page is composed here rather than by the module,
                // because it reads three services and `SystemStatsModule`
                // owns only one of them. The enabled check is the same one
                // every other door gets, so disabling system stats still
                // falls through to standby rather than showing a dead screen.
                if destination == .systemStats, let statsPage,
                   isDoorAvailable(.systemStats) {
                    return AnyView(SystemStatsPageView(stats: statsPage.stats,
                                                       battery: statsPage.battery))
                }
                // The mixer page, composed here like the stats page: the
                // engine is AppDelegate's service, not the module's
                // (decision 4), so the module has no view to offer. With no
                // service the generic branch below would render the module's
                // empty placeholder, so this destination skips it and falls
                // through to the stack instead.
                if destination == .appVolume {
                    if let appVolume, isDoorAvailable(.appVolume) {
                        return AnyView(AppVolumePageView(service: appVolume))
                    }
                }
                // A navigated screen replaces the arbitrated stack wholesale.
                // Falls through if its module got disabled underneath it, so
                // the panel can never show a screen whose feature is off.
                else if let moduleID = destination.moduleID,
                        let module = arbiter.module(for: moduleID), module.isEnabled {
                    return module.makeExpandedView()
                }
                // Stacked, not side by side: several expanded modules in a row
                // overflow the panel and truncate (observed with media plus
                // five stats). The notch grows downward, so height is the
                // dimension there is room in.
                //
                // Modules with nothing to show are dropped rather than
                // stacked as empty views: `VStack` spacing applies between
                // an empty element and its neighbour just as it would for a
                // real one, so an unfiltered stack leaves a phantom 8pt gap
                // under the last visible card. Same flag `chromeOnly()`
                // reads, so the two can never disagree about what is on
                // screen.
                let views = modules.filter(\.hasExpandedContent).map { $0.makeExpandedView() }
                return AnyView(
                    VStack(spacing: 8) {
                        ForEach(Array(views.enumerated()), id: \.offset) { $0.element }
                    }
                )
            }
            let views = modules.map { $0.makeCompactView() }
            return AnyView(
                HStack(spacing: 12) {
                    ForEach(Array(views.enumerated()), id: \.offset) { $0.element }
                }
            )
        case .liveActivity(let id):
            return arbiter.module(for: id)?.makeExpandedView()
        }
    }

    // MARK: - Expiry

    /// When the expiry timer will fire, or nil when none is scheduled.
    /// Exposed so "an activity always has a timer behind it" is a test.
    var expiryFireDate: Date? {
        guard let expiryTimer, expiryTimer.isValid else { return nil }
        return expiryTimer.fireDate
    }

    /// Schedules exactly one timer, at the moment the activity yields. No
    /// polling, and nothing scheduled at all when the notch is idle.
    ///
    /// Driven by the arbiter's `onExpiryChange`, which fires whenever the
    /// active activity starts, is refreshed or replaced, or ends — including
    /// when the presentation does not change, which is how a module
    /// refreshing its own activity used to leave the notch stuck open.
    private func scheduleExpiry() {
        expiryTimer?.invalidate()
        expiryTimer = nil

        guard let remaining = arbiter.timeUntilExpiry else { return }
        // Added in `.common` modes rather than via `scheduledTimer`, which
        // uses the default mode only: that mode does not run while a menu is
        // tracking, and an open menu would otherwise hold the notch open.
        let timer = Timer(timeInterval: remaining, repeats: false) { [weak self] _ in
            // Scheduled on the main run loop, so this fires on the main
            // thread; no hop, so nothing can reschedule in between.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.expiryTimer = nil
                self.arbiter.tick()
                // tick() reschedules through `onExpiryChange` whenever it
                // ends or promotes an activity. If it changed nothing — the
                // timer fired a hair before the arbiter's clock agreed — the
                // activity is still running and needs a timer behind it.
                if self.expiryTimer == nil {
                    self.scheduleExpiry()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        expiryTimer = timer
    }
}
