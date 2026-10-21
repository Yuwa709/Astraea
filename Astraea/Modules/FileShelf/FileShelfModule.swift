import SwiftUI

/// Files parked in the notch, reached from the top-left chrome.
///
/// Off by default. Unlike the clipboard it captures nothing on its own — it
/// only holds what the user drags in — but it is a feature that touches the
/// user's files, and those are opt-in here.
///
/// Holds no timer, so hard rule 9 is satisfied by there being nothing to
/// suspend. Disabling drops every reference, which also closes the
/// security scopes.
@MainActor
final class FileShelfModule: NotchModule {

    /// Permanent. Persisted as a settings key; renaming it would silently
    /// reset every user's preference for this module.
    let id: ModuleID = "file-shelf"
    let displayName = "File Shelf"
    let priority: ModulePriority = .ambient

    var isEnabled: Bool = false {
        didSet {
            guard isEnabled != oldValue, !isEnabled else { return }
            // Turning it off drops the references and their scopes; it never
            // touches the files themselves.
            service.clear()
        }
    }

    /// Nothing glanceable — a shelf is a place you go, not a readout.
    var wantsCompactDisplay: Bool { false }

    private let service: FileShelfService

    init(service: FileShelfService) {
        self.service = service
    }

    func makeCompactView() -> AnyView { AnyView(EmptyView()) }

    func makeExpandedView() -> AnyView {
        AnyView(FileShelfExpandedView(service: service))
    }
}
