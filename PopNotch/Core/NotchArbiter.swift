import Foundation
import os

/// What the notch should be showing.
enum NotchPresentation: Equatable {
    /// No live activity: the compact views of enabled always-on modules,
    /// in registration order.
    case standby([ModuleID])
    /// One module has temporarily taken the notch.
    case liveActivity(ModuleID)
}

/// What the panel is physically showing, as the coordinator last applied it.
///
/// Visibility needs this as well as the presentation, because being
/// arbitrated onto the notch is not the same as being on screen. Treating
/// standby membership as "visible" told every always-on module it was on
/// screen at launch and never otherwise, so their timers ran for the life of
/// the process (zero `didResignVisible` calls under lldb, 2026-09-13).
enum PanelSurface: Equatable {
    /// Idle, or showing the compact wings. Nothing collapsed counts as
    /// visible: wing content is push-driven and must never need a timer.
    case collapsed
    /// Open on the arbitrated default — the standby stack, or a live
    /// activity's view.
    case expanded
    /// Open on a screen a chrome control navigated to. It replaces the
    /// standby stack wholesale and owns its own sampling lifecycle.
    case navigated
}

/// Decides what the notch displays.
///
/// Deliberately free of AppKit: this type is pure decision logic so it can be
/// tested without a screen, which is most of what is machine-verifiable in
/// this project. A separate coordinator subscribes to `onPresentationChange`
/// and drives `NotchPanel`.
///
/// ## Rules
/// - A request's priority is capped at its module's own `priority`
/// - Higher priority interrupts lower; the interrupted activity is dropped
/// - Equal or lower priority queues, FIFO within a priority
/// - A module holds at most one slot: re-requesting while active refreshes
///   the active activity in place, and re-requesting while queued replaces
///   the queued entry where it stands
/// - An activity yields when its duration elapses; the highest-priority
///   queued request takes over, otherwise the notch returns to standby
/// - A module is visible only while its expanded view is on screen (see
///   `PanelSurface`); off screen, it is told so and must stop its timers
///
/// Time is injected so tests are deterministic and never sleep.
@MainActor
final class NotchArbiter {

    private static let logger = Logger(subsystem: "com.techie.PopNotch", category: "Arbiter")

    private(set) var presentation: NotchPresentation = .standby([])

    /// Fires whenever `presentation` actually changes.
    var onPresentationChange: ((NotchPresentation) -> Void)?

    /// Fires whenever the active activity's expiry changes — a new activity
    /// started, the active one was refreshed or replaced, or it ended — so
    /// the coordinator can reschedule its one-shot timer.
    ///
    /// Separate from `onPresentationChange` on purpose: the expiry can move
    /// while the presentation stays put (a module refreshing or preempting
    /// its own activity, or a queued request from the module that just
    /// yielded), and keying the timer off the presentation left the notch
    /// stuck open in exactly those cases.
    var onExpiryChange: (() -> Void)?

    /// The modules last told they are on screen. Exposed so "nothing is
    /// visible behind the collapsed wings" is a test rather than a comment.
    private(set) var visibleIDs: Set<ModuleID> = []

    private var modules: [any NotchModule] = []
    private var active: (request: LiveActivityRequest, expiresAt: TimeInterval)?
    private var queue: [LiveActivityRequest] = []
    /// Bumped every time `active` starts or ends, so a public entry point can
    /// tell whether it moved the expiry and owes `onExpiryChange` a call.
    /// A counter rather than a comparison of `expiresAt`: a refresh can land
    /// on the same instant and must still reschedule.
    private var expiryGeneration = 0
    /// Collapsed until the coordinator says otherwise, so a panel that was
    /// never created shows nobody.
    private var surface: PanelSurface = .collapsed
    private let now: () -> TimeInterval

    /// `systemUptime` rather than wall clock: it does not jump when the user
    /// changes the date or the machine syncs time.
    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
    }

    // MARK: - Registration

    func register(_ module: any NotchModule) {
        guard !modules.contains(where: { $0.id == module.id }) else {
            Self.logger.error("Duplicate module ID \(module.id, privacy: .public); ignoring")
            return
        }
        modules.append(module)
        recompute()
    }

    func module(for id: ModuleID) -> (any NotchModule)? {
        modules.first { $0.id == id }
    }

    /// Registration order, for Settings to list.
    var registeredModules: [any NotchModule] { modules }

    /// Call after changing any module's `isEnabled`, so standby and the
    /// active activity are re-evaluated.
    func enablementDidChange() {
        let generation = expiryGeneration
        // The queue is filtered first, so a module disabled in the same
        // change as the active one can never be promoted in its place.
        queue.removeAll { module(for: $0.moduleID)?.isEnabled != true }
        if let active, module(for: active.request.moduleID)?.isEnabled != true {
            Self.logger.notice("Active module \(active.request.moduleID, privacy: .public) disabled; yielding")
            endActive()
            activateNextQueued()
        }
        recompute()
        notifyExpiryChange(since: generation)
    }

    // MARK: - Live activities

    func requestLiveActivity(_ incoming: LiveActivityRequest) {
        guard let owner = module(for: incoming.moduleID), owner.isEnabled else {
            Self.logger.notice("Ignoring activity from unknown or disabled module \(incoming.moduleID, privacy: .public)")
            return
        }
        let generation = expiryGeneration

        // A module may ask for less than its own priority, never more: the
        // tiers are the arbiter's to enforce, not each caller's to pick.
        var request = incoming
        if incoming.priority > owner.priority {
            Self.logger.notice("\(incoming.moduleID, privacy: .public) asked for priority \(incoming.priority.rawValue) above its own \(owner.priority.rawValue); capped")
            request = LiveActivityRequest(moduleID: incoming.moduleID,
                                          priority: owner.priority,
                                          duration: incoming.duration)
        }

        if let current = active {
            if current.request.moduleID == request.moduleID {
                // The module already has the notch: refresh in place with the
                // new request's priority and a fresh duration. Queueing it
                // behind itself replayed every stale notice in turn.
                Self.logger.notice("\(request.moduleID, privacy: .public) refreshed its activity")
                start(request)
            } else if request.priority > current.request.priority {
                Self.logger.notice("\(request.moduleID, privacy: .public) preempts \(current.request.moduleID, privacy: .public)")
                // Dropped, not re-queued: these are transient notices, and a
                // stale one resurfacing after the interruption reads as a bug.
                start(request)
            } else if let index = queue.firstIndex(where: { $0.moduleID == request.moduleID }) {
                // One slot per module: the newer request supersedes the
                // queued one where it stands, rather than queueing again.
                queue[index] = request
                Self.logger.notice("\(request.moduleID, privacy: .public) replaced its queued activity behind \(current.request.moduleID, privacy: .public)")
            } else {
                queue.append(request)
                Self.logger.notice("\(request.moduleID, privacy: .public) queued behind \(current.request.moduleID, privacy: .public)")
            }
        } else {
            start(request)
        }
        recompute()
        notifyExpiryChange(since: generation)
    }

    /// Seconds until the active activity yields, or nil when nothing is
    /// active. Lets the coordinator schedule a single one-shot timer at the
    /// exact moment instead of polling — hard rule 9 by construction.
    var timeUntilExpiry: TimeInterval? {
        guard let active else { return nil }
        return max(0, active.expiresAt - now())
    }

    /// Expires the active activity if its duration has elapsed. Driven by the
    /// coordinator; the arbiter owns no timer of its own so it cannot leak one.
    func tick() {
        guard let current = active, now() >= current.expiresAt else { return }
        let generation = expiryGeneration
        Self.logger.notice("\(current.request.moduleID, privacy: .public) yielded")
        endActive()
        activateNextQueued()
        recompute()
        notifyExpiryChange(since: generation)
    }

    private func start(_ request: LiveActivityRequest) {
        // The module now holds the notch, so any entry it still has queued
        // is superseded: one slot per module.
        queue.removeAll { $0.moduleID == request.moduleID }
        active = (request, now() + request.duration)
        expiryGeneration &+= 1
    }

    private func endActive() {
        active = nil
        expiryGeneration &+= 1
    }

    /// Called last by every public entry point, after `recompute`, so the
    /// coordinator reschedules against settled state.
    private func notifyExpiryChange(since generation: Int) {
        guard expiryGeneration != generation else { return }
        onExpiryChange?()
    }

    /// Highest priority wins; FIFO among equals, since `firstIndex` finds the
    /// earliest occurrence of the maximum.
    private func activateNextQueued() {
        guard let best = queue.map(\.priority).max(),
              let index = queue.firstIndex(where: { $0.priority == best })
        else { return }
        start(queue.remove(at: index))
    }

    // MARK: - Presentation

    private func recompute() {
        let next: NotchPresentation
        if let active {
            next = .liveActivity(active.request.moduleID)
        } else {
            next = .standby(modules.filter { $0.isEnabled && $0.wantsCompactDisplay }.map(\.id))
        }

        guard next != presentation else { return }
        presentation = next
        updateVisibility()
        Self.logger.notice("Presentation -> \(String(describing: next), privacy: .public)")
        onPresentationChange?(next)
    }

    // MARK: - Visibility

    /// Called by the coordinator after every state it applies to the panel.
    ///
    /// Re-checks even when the surface has not changed: a module's expanded
    /// content can appear while the panel stays open (music starting under
    /// the cursor), and the coordinator re-applies state on exactly those
    /// changes.
    func panelDidApply(_ surface: PanelSurface) {
        self.surface = surface
        updateVisibility()
    }

    /// Tells modules when their expanded view goes on and off screen. Hard
    /// rule 9 depends on this: a module that is off screen must not be
    /// polling.
    ///
    /// - Collapsed: nobody, wings included.
    /// - A live activity: its module, whether or not a screen was navigated
    ///   to — the coordinator draws the activity over either.
    /// - Standby, open on the stack: the modules with something to draw, by
    ///   the same `hasExpandedContent` filter the coordinator stacks with,
    ///   so the two cannot disagree. System stats has no expanded row and is
    ///   never visible here.
    /// - Standby, open on a navigated screen: nobody.
    private func updateVisibility() {
        let nowVisible: Set<ModuleID>
        switch (presentation, surface) {
        case (_, .collapsed), (.standby, .navigated):
            nowVisible = []
        case (.liveActivity(let id), _):
            nowVisible = [id]
        case (.standby(let ids), .expanded):
            nowVisible = Set(ids.filter { module(for: $0)?.hasExpandedContent == true })
        }
        guard nowVisible != visibleIDs else { return }

        let resigned = visibleIDs.subtracting(nowVisible)
        let became = nowVisible.subtracting(visibleIDs)
        // Recorded before the callbacks, so a module reacting to one sees
        // the settled state.
        visibleIDs = nowVisible
        Self.logger.notice("Visible -> \(String(describing: nowVisible.sorted()), privacy: .public)")
        for id in resigned {
            module(for: id)?.didResignVisible()
        }
        for id in became {
            module(for: id)?.didBecomeVisible()
        }
    }
}
