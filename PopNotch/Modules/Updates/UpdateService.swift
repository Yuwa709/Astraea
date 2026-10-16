import AppKit
import Observation
import Sparkle
import os

/// What Sparkle has found and not yet shown, and the one way to act on it.
///
/// Sparkle's scheduled checks are routed through this object as the standard
/// user driver's delegate, using its *gentle reminders* contract: when a
/// background check finds an update, Sparkle asks whether it may show its
/// alert, this says no, and records the version instead. The notch is the
/// surface that shows it (`UpdateModule`); Sparkle's own alert appears only
/// when the user clicks through, via `showUpdate()`. A background agent
/// cannot afford the alternative: Sparkle activates the app to show its
/// windows, and an alert opening behind the user's work, with no Dock icon
/// to bounce, is how releases went unnoticed before this existed.
///
/// Manual checks from Settings are untouched: Sparkle always shows those
/// itself, in focus, because the user asked.
///
/// Owned by `AppDelegate` for the process lifetime. Sparkle holds its
/// delegate weakly, so nothing else keeps this alive.
@MainActor
@Observable
final class UpdateService: NSObject, SPUStandardUserDriverDelegate {

    @ObservationIgnored
    private static let logger = Logger(subsystem: "com.techie.PopNotch", category: "Updates")

    /// The display version of an update a scheduled check found and the
    /// user has not yet looked at. Nil when there is nothing to tell them.
    private(set) var availableVersion: String?

    /// The running build's own display version, for "you have 1.3.0".
    let currentVersion: String

    /// Whether the updater is checking on its own. Mirrors the Update
    /// Notices module's switch; read back by tests.
    private(set) var automaticChecksEnabled = false

    /// A scheduled check found an update that was not already pending.
    /// `UpdateModule` asks for the notch on this.
    @ObservationIgnored var onUpdateFound: ((String) -> Void)?

    /// `availableVersion` changed either way, so the wings can be re-rendered.
    @ObservationIgnored var onAvailabilityChange: (() -> Void)?

    /// Set by `AppDelegate` once the updater exists. A pending preference
    /// is applied the moment it lands, so the module's switch can be set
    /// before or after without either order losing it.
    @ObservationIgnored var updater: SPUUpdater? {
        didSet { applyAutomaticChecks() }
    }

    init(currentVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—") {
        self.currentVersion = currentVersion
        super.init()
    }

    // MARK: - Controls

    /// Turns Sparkle's daily background check on or off. Set explicitly on
    /// every launch, so a stale stored preference, or a future Sparkle
    /// default, can never decide this for an app with no Dock icon.
    ///
    /// Writing the preference is also what stops Sparkle asking its own
    /// "check automatically?" question on first launch: it asks only while
    /// neither Info.plist nor the defaults say.
    func setAutomaticChecks(_ enabled: Bool) {
        automaticChecksEnabled = enabled
        applyAutomaticChecks()
    }

    private func applyAutomaticChecks() {
        guard let updater else { return }
        if updater.automaticallyChecksForUpdates != automaticChecksEnabled {
            updater.automaticallyChecksForUpdates = automaticChecksEnabled
            Self.logger.notice("Automatic update checks \(self.automaticChecksEnabled ? "on" : "off", privacy: .public)")
        }
    }

    /// Brings Sparkle's update alert into focus, or starts a check if no
    /// session is pending. Click-driven only: Sparkle activates the app to
    /// show its windows, the same narrow carve-out to hard rule 4 that the
    /// settings gear and the About tab's button document. No hover path
    /// reaches this.
    func showUpdate() {
        guard let updater else {
            Self.logger.error("Install requested before the updater existed")
            return
        }
        Self.logger.notice("Update \(self.availableVersion ?? "?", privacy: .public) requested from the notch")
        updater.checkForUpdates()
    }

    // MARK: - State

    /// Records a found update. Separate from the delegate method so the
    /// module can be tested without Sparkle in the loop.
    func noteUpdateAvailable(_ version: String) {
        let isNew = availableVersion != version
        availableVersion = version
        Self.logger.notice("Update available: \(version, privacy: .public)\(isNew ? "" : " (already pending)", privacy: .public)")
        if isNew {
            onAvailabilityChange?()
            onUpdateFound?(version)
        }
    }

    /// Clears the notice. The user has seen Sparkle's alert, or the session
    /// ended; either way the notch has nothing left to say.
    func clearAvailableUpdate(reason: String) {
        guard availableVersion != nil else { return }
        Self.logger.notice("Update notice cleared: \(reason, privacy: .public)")
        availableVersion = nil
        onAvailabilityChange?()
    }

    // MARK: - SPUStandardUserDriverDelegate

    // Sparkle calls these on the main thread; `assumeIsolated` states that
    // to the compiler and traps if it is ever not so.

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Never let a *scheduled* find open Sparkle's alert, whatever focus it
    /// proposes: the notch shows it, and the user clicks through when they
    /// want it. User-initiated checks do not come through here.
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        false
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        let version = update.displayVersionString
        MainActor.assumeIsolated {
            // A manual check from Settings: Sparkle shows it in focus right
            // now, and a badge that appears for the instant before the user
            // looks at the alert is noise.
            guard !handleShowingUpdate else {
                Self.logger.notice("Sparkle showing update \(version, privacy: .public) itself (user initiated: \(state.userInitiated, privacy: .public))")
                return
            }
            noteUpdateAvailable(version)
        }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated {
            clearAvailableUpdate(reason: "user looked at Sparkle's alert")
        }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated {
            clearAvailableUpdate(reason: "update session finished")
        }
    }
}
