import Observation

/// Whether the notch is pinned open.
///
/// **Session-only, deliberately.** It is not in `AppSettings` and never
/// reaches UserDefaults: a panel stuck open across a relaunch, with no
/// visible cause, is a bug report rather than a preference. Quitting clears
/// it, which is the escape hatch of last resort.
///
/// Its own type rather than a property on the coordinator so the menu bar can
/// observe it without the coordinator becoming `@Observable` — that class
/// owns timers, closures and panel lifecycle, and making all of it observable
/// to publish one flag would be a large blast radius for a small need.
@MainActor
@Observable
final class PinState {
    var isPinned = false
}
