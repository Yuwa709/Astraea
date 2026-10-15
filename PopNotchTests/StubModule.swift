import SwiftUI
@testable import PopNotch

/// A configurable stand-in for a real feature.
///
/// Roadmap Phase 2 task 5 asks for dummy modules that fight for the notch.
/// They live in the test target rather than the app so no placeholder code
/// ships, and they record visibility callbacks so tests can assert the
/// hard rule 9 contract: off-screen modules are told to stop polling.
@MainActor
final class StubModule: NotchModule {

    let id: ModuleID
    let displayName: String
    let priority: ModulePriority
    var isEnabled: Bool
    let wantsCompactDisplay: Bool
    /// Settable, so a test can have content appear while the panel is open.
    var hasExpandedContent: Bool

    /// Ordered log of visibility transitions, for assertions.
    private(set) var visibilityLog: [Bool] = []
    var isVisible: Bool { visibilityLog.last ?? false }

    init(
        id: ModuleID,
        priority: ModulePriority = .ambient,
        isEnabled: Bool = true,
        wantsCompactDisplay: Bool = true,
        hasExpandedContent: Bool = true
    ) {
        self.id = id
        self.displayName = id.capitalized
        self.priority = priority
        self.isEnabled = isEnabled
        self.wantsCompactDisplay = wantsCompactDisplay
        self.hasExpandedContent = hasExpandedContent
    }

    func makeCompactView() -> AnyView { AnyView(Text(id)) }
    func makeExpandedView() -> AnyView { AnyView(Text(displayName)) }

    func didBecomeVisible() { visibilityLog.append(true) }
    func didResignVisible() { visibilityLog.append(false) }

    func activity(priority: ModulePriority? = nil, duration: TimeInterval = 5) -> LiveActivityRequest {
        LiveActivityRequest(moduleID: id, priority: priority ?? self.priority, duration: duration)
    }
}

/// A hand-cranked clock, so tests never sleep and never flake.
final class TestClock {
    private(set) var current: TimeInterval = 0
    func advance(by interval: TimeInterval) { current += interval }
    var read: () -> TimeInterval { { [self] in current } }
}
