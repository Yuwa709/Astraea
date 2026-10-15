import SwiftUI

/// The per-app volume feature's presence in Settings and, through the
/// coordinator's door rule, in the panel chrome. Deliberately thin: the
/// engine is `AppVolumeService`, owned by AppDelegate, not by a module
/// (docs/FUTURE-audio-mixer.md, *v1 plan*, decision 4). This type exists so
/// the feature gets the same Settings toggle and door-availability machinery
/// as every other screen, one `register` call like the rest.
///
/// Off by default: watching enumerates and logs which apps play audio,
/// which is not something to opt someone into — the same reasoning as the
/// clipboard. Its `isEnabled` setter is the single point where watching
/// starts and stops, replacing Phase 3's `#if DEBUG` gate in AppDelegate
/// (which that gate's comment said this toggle would).
@MainActor
final class AppVolumeModule: NotchModule {

    /// Permanent. Persisted as a settings key; renaming it would silently
    /// reset every user's preference for this module.
    let id: ModuleID = "app-volume"
    let displayName = "App Volume"
    let priority: ModulePriority = .ambient

    var isEnabled: Bool = false {
        didSet {
            guard isEnabled != oldValue else { return }
            // Event-driven listeners, not timers, so hard rule 9 is not in
            // play — but the same discipline holds: off means nothing
            // registered and nothing logged.
            if isEnabled {
                service.startWatching()
            } else {
                service.stopWatching()
            }
        }
    }

    /// Nothing glanceable: a mixer is a screen you go to, not ambient state.
    var wantsCompactDisplay: Bool { false }

    /// The mixer page is composed by the coordinator, the way the stats page
    /// is; this module contributes nothing to the arbitrated stack.
    var hasExpandedContent: Bool { false }

    private let service: AppVolumeService

    init(service: AppVolumeService) {
        self.service = service
    }

    func makeCompactView() -> AnyView { AnyView(EmptyView()) }

    /// Unreachable in practice: the coordinator composes the mixer page from
    /// its own service reference before the generic module branch, and skips
    /// that branch for this destination when the service is absent.
    func makeExpandedView() -> AnyView { AnyView(EmptyView()) }
}
