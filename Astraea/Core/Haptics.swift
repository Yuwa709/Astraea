import AppKit

/// The one place the app taps the trackpad, so the Settings switch gates
/// every haptic at once. Reads `AppSettings.hapticsEnabled` from the store
/// at each tap rather than keeping a copy, so there is nothing to keep in
/// step; `NotchCoordinator` hands it the store once, at launch.
@MainActor
enum Haptics {
    /// Weak: the store outlives every haptic, and a test's store must not
    /// be kept alive by a static. With none, haptics stay on, the default.
    static weak var settings: SettingsStore?

    static func perform(_ pattern: NSHapticFeedbackManager.FeedbackPattern,
                        performanceTime: NSHapticFeedbackManager.PerformanceTime) {
        guard settings?.settings.hapticsEnabled ?? true else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: performanceTime)
    }
}
