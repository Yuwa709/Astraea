import Foundation

/// The fixed set of apps that are never tapped (v1 plan, decision 9): tools
/// that already interpose on other apps' audio, where adding our own tap on
/// top risks glitching everything they manage. Shown on the mixer page
/// greyed with the reason, so the row's absence of a working slider is
/// explained rather than looking broken.
///
/// **Every bundle ID here is verified against a real install, never
/// guessed** (decision 9). The set has no editor and no settings fields.
/// PopNotch itself and untraceable system daemons are not listed here
/// because `AudioOwnerResolver` already hides them entirely — this set only
/// covers apps that appear as rows.
///
/// DAW entries (Logic Pro, GarageBand, Ableton…) are anticipated by the
/// plan but absent: no DAW is installed on the development machine, so no
/// bundle ID can be verified yet. Add each one only after reading it from a
/// real install's Info.plist.
enum NeverTapSet {

    /// Owner key (the app's bundle ID) to display name, for the apps that
    /// do what this mixer does.
    ///
    /// Verified 2026-09-18 by reading each app's `Info.plist` in
    /// `/Applications` on the development machine.
    ///
    /// One list, two uses. They are never tapped, because two mixers on one
    /// app's audio is how you get glitching. And while one of them runs the
    /// **visualiser** cannot be trusted either: it re-renders other apps'
    /// audio exactly as PopNotch does, and the spectrum's tap counts that
    /// copy alongside the original. PopNotch can exclude its own re-render
    /// (Phase 6); nothing public lets it exclude somebody else's, so the
    /// only honest answer is to say so — see `AppVolumeService`'s warning.
    nonisolated static let mixerNames: [String: String] = [
        "com.finetuneapp.FineTune": "FineTune",
        "com.cshariq.sapphire": "Sapphire",
    ]

    /// The display reason for an owner key, or nil when the app is tappable.
    nonisolated static func reason(for key: String) -> String? {
        mixerNames[key] == nil ? nil : "audio mixer"
    }

    /// The app's own name for a bundle ID in the set, or nil.
    nonisolated static func mixerName(forBundleID id: String) -> String? {
        mixerNames[id]
    }
}
