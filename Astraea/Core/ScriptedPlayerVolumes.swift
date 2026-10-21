import Foundation

/// Players whose volume is their own scripting `sound volume` — Spotify and
/// Music — reachable by bundle ID (v1 plan, decision 3: AppleScript, never
/// a tap, for these two).
///
/// `MediaModule` provides it: it already owns those players' adapters and
/// the player screen's slider, so going through it is what makes the mixer
/// page's row and the player slider one value — the same mirror, the same
/// write throttle, the same read-back correction. AppDelegate hands it to
/// `AppVolumeService` as this protocol, so the mixer never references the
/// media module itself (modules never reference each other).
@MainActor
protocol ScriptedPlayerVolumes: AnyObject {

    /// Whether this bundle ID is a player whose volume is scriptable right
    /// now. False when the media module is switched off: a user who turned
    /// media off must not be sent Apple Events from another screen.
    func handlesVolume(for bundleID: String) -> Bool

    /// 0...100 as last read or written; nil when never read or unreadable.
    /// Observable: a view reading this redraws when either control moves it.
    func volume(for bundleID: String) -> Int?

    /// One Apple Event (~17ms, main actor), skipped while a drag owns the
    /// value and for a player that is not running.
    func refreshVolume(for bundleID: String)

    /// A drag's lifecycle, the same begin/step/end the player slider uses.
    /// A `setVolume` with no edit open is a single write, so a keyboard or
    /// VoiceOver step needs no begin/end pair.
    func beginVolumeEdit(for bundleID: String)
    func setVolume(_ value: Int, for bundleID: String)
    func endVolumeEdit(for bundleID: String)
}
