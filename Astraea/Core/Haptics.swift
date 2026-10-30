import AppKit

/// The one place the app taps the trackpad, so the Settings switch gates
/// every haptic at once. `NotchCoordinator` keeps `isEnabled` in step with
/// `AppSettings.hapticsEnabled`.
@MainActor
enum Haptics {
    static var isEnabled = true

    static func perform(_ pattern: NSHapticFeedbackManager.FeedbackPattern,
                        performanceTime: NSHapticFeedbackManager.PerformanceTime) {
        guard isEnabled else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: performanceTime)
    }
}
