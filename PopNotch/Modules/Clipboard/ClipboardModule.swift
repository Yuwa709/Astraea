import SwiftUI

/// Clipboard history as a first-class module, alongside media and stats.
///
/// Off by default (`enabledByDefault: false` at registration): it records
/// everything the user copies, which is not something to opt someone into.
///
/// Unlike `SystemStatsModule`, polling is tied to `isEnabled` rather than to
/// the visibility callbacks — a history that only recorded while the notch
/// was open would be empty every time you opened it. See the note on
/// `ClipboardService` for how hard rule 9 is otherwise honoured.
@MainActor
final class ClipboardModule: NotchModule {

    /// Permanent. Persisted as a settings key; renaming it would silently
    /// reset every user's preference for this module.
    let id: ModuleID = "clipboard"
    let displayName = "Clipboard History"
    let priority: ModulePriority = .ambient

    var isEnabled: Bool = false {
        didSet {
            guard isEnabled != oldValue else { return }
            // The single point where the poll starts and stops, so a toggle
            // in Settings cannot leave a timer running behind it.
            service.setEnabled(isEnabled)
        }
    }

    /// Nothing worth occupying the collapsed row with — a clipboard has no
    /// glanceable state, only a list you go looking for.
    var wantsCompactDisplay: Bool { false }

    private let service: ClipboardService

    init(service: ClipboardService) {
        self.service = service
    }

    func makeCompactView() -> AnyView { AnyView(EmptyView()) }

    func makeExpandedView() -> AnyView {
        AnyView(ClipboardExpandedView(service: service))
    }
}
