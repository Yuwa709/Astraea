import SwiftUI

/// Tells the user a new Astraea is out, in the notch, where they will see it.
///
/// Three surfaces, all driven by `UpdateService.availableVersion`:
/// - When a scheduled check first finds an update, a short live activity
///   opens the notch on the notice, the way a track change does.
/// - Until it is installed, the collapsed wings carry a badge: the download
///   glyph on the left, the version on the right. Media's wings outrank it
///   while something plays (registration order), so a listener's artwork is
///   never covered.
/// - Hovering shows the card with an Install button, which hands off to
///   Sparkle's own installer.
///
/// On by default: an update notice is the one thing a user who never opens
/// Settings still needs. Its switch is also the switch for Sparkle's daily
/// background check, so turning it off returns the app to manual-only
/// checks from the About tab. Holds no timer of its own: Sparkle's
/// scheduler is the one long-lived timer, and it is the pre-approved
/// dependency's (hard rule 2), checking once a day.
@MainActor
final class UpdateModule: NotchModule {

    /// Permanent. Persisted as a settings key; renaming it would silently
    /// reset every user's preference for this module.
    let id: ModuleID = "updates"
    let displayName = "Update Notices"
    /// Routine: a media change interrupts it, and it waits its turn behind
    /// one, but it outranks the ambient stats row.
    let priority: ModulePriority = .standard

    /// How long the notch stays open on a newly found update. Twice media's
    /// pop: there is a button to read and a decision to make.
    static let noticeDuration: TimeInterval = 8

    var isEnabled: Bool = true {
        // Unconditional, not guarded on `oldValue`: the coordinator assigns
        // the stored preference at registration, and when it equals the
        // initial value a guarded setter would never tell Sparkle anything.
        didSet { service.setAutomaticChecks(isEnabled) }
    }

    /// Something to draw only while an update is pending; otherwise the
    /// card is dropped from the stack and never told it is visible.
    var hasExpandedContent: Bool { service.availableVersion != nil }

    /// Set by AppDelegate to the coordinator; the module never touches it.
    var onLiveActivityRequest: ((LiveActivityRequest) -> Void)?
    /// Fired when the wings should be re-rendered: a notice arrived or was
    /// cleared.
    var onPresenceChange: (() -> Void)?

    private let service: UpdateService

    init(service: UpdateService) {
        self.service = service
        service.onAvailabilityChange = { [weak self] in
            self?.onPresenceChange?()
        }
        service.onUpdateFound = { [weak self] _ in
            guard let self, self.isEnabled else { return }
            self.onLiveActivityRequest?(LiveActivityRequest(
                moduleID: self.id, priority: self.priority,
                duration: Self.noticeDuration))
        }
    }

    func makeCompactView() -> AnyView {
        guard service.availableVersion != nil else { return AnyView(EmptyView()) }
        return AnyView(UpdateWingGlyph())
    }

    func makeExpandedView() -> AnyView {
        AnyView(UpdateNoticeCard(service: service))
    }

    /// The wings exist only while there is an update to point at; nil keeps
    /// the collapsed notch invisible the rest of the time.
    func makeCompactLeadingView() -> AnyView? {
        guard service.availableVersion != nil else { return nil }
        return AnyView(UpdateWingGlyph())
    }

    func makeCompactTrailingView() -> AnyView? {
        guard let version = service.availableVersion else { return nil }
        return AnyView(UpdateWingVersion(version: version))
    }
}
