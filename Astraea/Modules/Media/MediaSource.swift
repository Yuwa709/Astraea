import Foundation
import os

/// The track queued after the current one, when the player exposes one.
///
/// Only Music.app can answer this from its scripting dictionary. Spotify's
/// has no playlist, context, or queue — its `next track` is a *command* that
/// skips, not data — so `SpotifyAdapter` always reports nil here.
struct UpNextTrack: Equatable {
    let title: String
    let artist: String
}

/// Whether the current track is favourited, and whether this source can
/// change it.
///
/// The distinction is forced by the dictionaries, not by preference:
/// Spotify's `starred` is `access="r"` — readable, never writable — while
/// Music's `favorited` is read-write. A UI that offers a toggle for Spotify
/// would be offering something the scripting interface cannot do.
enum FavoriteState: Equatable {
    /// No favourite concept is reachable for this source right now.
    case unsupported
    /// Known, but this source cannot change it (Spotify's `starred`).
    case readOnly(Bool)
    /// Known and changeable (Music's `favorited`).
    case editable(Bool)

    var value: Bool? {
        switch self {
        case .unsupported: nil
        case .readOnly(let on), .editable(let on): on
        }
    }

    var isEditable: Bool {
        if case .editable = self { return true }
        return false
    }
}

/// One music player Astraea can read and control.
///
/// Adapters (Spotify, Apple Music) implement this; `MediaModule` owns a list
/// of them and is the only thing that talks to them. A MediaRemote-based
/// source can slot in here if Apple ever lifts the caller gate — see
/// FINDINGS.md.
@MainActor
protocol MediaSource: AnyObject {

    /// Stable identifier, e.g. "spotify".
    var sourceID: String { get }

    var isPlayerRunning: Bool { get }

    /// The user declined the Automation prompt for this player. The module
    /// degrades: metadata that arrives without Apple Events still shows, and
    /// the expanded view explains how to grant access. Never re-prompts in a
    /// loop.
    var permissionDenied: Bool { get }

    /// Fires with the latest snapshot, or nil when the player has nothing
    /// (stopped, quit). Always on the main actor.
    var onUpdate: ((NowPlaying?) -> Void)? { get set }

    /// Begin listening for changes. Push-based (distributed notifications) —
    /// no timers, so this may run for the app's lifetime without violating
    /// hard rule 9; a source must still not poll here.
    func startObserving()
    func stopObserving()

    /// Fetch current state now (Apple Event). Called when the module is
    /// switched on (including at launch) and by each adapter on its own
    /// track-change notifications — never on hover. The first call triggers
    /// the system's one-time Automation permission prompt.
    func refresh()

    func send(_ command: MediaCommand)

    /// Jump playback to an absolute position, for scrubbing.
    func seek(to seconds: TimeInterval)

    /// Next track in the player's own queue, refreshed by `refresh()` rather
    /// than fetched on access — reading it costs an Apple Event, and this is
    /// read from view code.
    var upNext: UpNextTrack? { get }

    /// Favourite state for the current track, refreshed by `refresh()`.
    var favorite: FavoriteState { get }

    /// Changes the favourite flag. A no-op unless `favorite` is `.editable`;
    /// callers should still check first so the UI never offers a dead control.
    func setFavorite(_ on: Bool)

    /// Lyrics the player itself holds for the current track, if any. Music
    /// exposes a `lyrics` property; Spotify's dictionary has none. Often
    /// plain text, so the caller must check whether it parses as timed.
    func embeddedLyrics() -> String?

    /// Shuffle and repeat, as the player last reported them. `nil` means
    /// this source cannot answer — which is not the same as "off", and is
    /// why these are optional: a control rendered from a guessed `false`
    /// would show a state nobody read.
    ///
    /// Refreshed by `refresh()`, like `upNext` and `favorite`, rather than
    /// fetched on access: reading them costs an Apple Event and this is read
    /// from view code.
    var shuffling: Bool? { get }
    var repeating: Bool? { get }

    /// Sets shuffle or repeat. A no-op unless the source answers the
    /// matching property; callers check first so the UI never offers a dead
    /// control.
    func setShuffling(_ on: Bool)
    func setRepeating(_ on: Bool)

    /// Whether this player exposes its own output volume. Spotify and Music
    /// do (`sound volume`); the system now-playing source does not, so the
    /// volume control is absent for it rather than dimmed.
    var supportsVolume: Bool { get }

    /// The player's own volume, 0...100, as last read or written. `nil`
    /// means never read, or this source cannot answer. Refreshed by
    /// `refreshVolume()` rather than on access, like the playback modes:
    /// reading it costs an Apple Event and this is read from view code.
    var volume: Int? { get }

    /// Reads the volume now. One Apple Event, ~17ms on the main actor, so
    /// never on a tight cadence.
    func refreshVolume()

    /// Writes the volume, clamped to 0...100. A no-op unless
    /// `supportsVolume`; callers check first so the UI never offers a dead
    /// control.
    func setVolume(_ value: Int)

    /// The player app's bundle ID, when this source is one app. The mixer
    /// page keys its rows by the owning app's bundle ID, so this is how a
    /// Spotify or Music row finds the source that controls its volume. Nil
    /// for the system source, which speaks for whichever app is playing.
    var bundleID: String? { get }
}

/// Defaults for sources whose player exposes neither concept, so an adapter
/// only implements what its dictionary actually supports.
extension MediaSource {
    var upNext: UpNextTrack? { nil }
    var favorite: FavoriteState { .unsupported }
    func setFavorite(_ on: Bool) {}
    func embeddedLyrics() -> String? { nil }
    var shuffling: Bool? { nil }
    var repeating: Bool? { nil }
    func setShuffling(_ on: Bool) {}
    func setRepeating(_ on: Bool) {}
    var supportsVolume: Bool { false }
    var volume: Int? { nil }
    func refreshVolume() {}
    func setVolume(_ value: Int) {}
    var bundleID: String? { nil }
}

/// Runs an AppleScript source and reports the result or the error code.
///
/// Main-actor only, and measured to be so, not merely cautious: `NSAppleScript`
/// deadlocks on any secondary thread — a plain queue, a `Thread` without a run
/// loop, and a `Thread` with one all hung on the first `executeAndReturnError`
/// (2026-09-04, four variants). The Apple Event reply is not routable off main.
///
/// **Cost is per property, not per script.** Measured 2026-09-04 against a
/// running Spotify: the runtime itself is free (`return 1` → 0.00ms) and each
/// property read is one synchronous IPC round-trip at ~16.7ms — 1 property
/// 16.7ms, 2 properties 33ms, the eight-field query **167ms median**. That
/// is ~10 dropped frames per call on the main actor, which is why nothing
/// here may run on a tight cadence and why a live poll reads three
/// properties, not eight. Compiling ahead saves ~16ms per call; it is not
/// the lever. The one other slow case is the first-ever call, which blocks
/// on the system permission dialog — user-driven and one-time.
@MainActor
enum AppleScriptRunner {

    private static let logger = Logger(subsystem: "com.techie.Astraea", category: "AppleScript")

    /// errAEEventNotPermitted: the user declined the Automation prompt.
    /// nonisolated: an immutable Int read by Failure.isPermissionDenied
    /// from nonisolated contexts; isolation was only inherited.
    nonisolated static let permissionDeniedCode = -1743

    /// errAETimeout: the player did not reply within `timeoutSeconds`.
    /// Transient — a busy or hung player, never a statement about the
    /// Automation grant — so callers must not treat it as a denial.
    nonisolated static let timeoutCode = -1712

    /// How long any one Apple Event may wait for its reply. Every script
    /// runs synchronously on the main actor (see above), and AppleScript's
    /// own default is two **minutes**: a hung Spotify or Music would freeze
    /// the notch for that long. Two seconds is ~12x the slowest healthy
    /// call measured here (the eight-field query, 167ms), so a working
    /// player never hits it.
    ///
    /// The one place this lives: `run(_:)` and `compile(_:)` both wrap the
    /// source in `bounded(_:)`, so no script can be added without it.
    nonisolated static let timeoutSeconds = 2

    struct Failure: Error {
        let code: Int
        var isPermissionDenied: Bool { code == AppleScriptRunner.permissionDeniedCode }
        /// The player was too slow to answer. Transient: retried by the next
        /// pull like any other dropped event, never recorded as a denial.
        var isTimeout: Bool { code == AppleScriptRunner.timeoutCode }
    }

    /// Wraps a script in a `with timeout` block. The block covers every
    /// application command inside it, nested `tell` blocks included, so the
    /// whole script is bounded rather than each `tell` separately.
    nonisolated static func bounded(_ source: String) -> String {
        "with timeout of \(timeoutSeconds) seconds\n\(source)\nend timeout"
    }

    static func run(_ source: String) -> Result<NSAppleEventDescriptor, Failure> {
        guard let script = NSAppleScript(source: bounded(source)) else {
            logger.error("Script failed to compile")
            return .failure(Failure(code: 0))
        }
        return run(script)
    }

    /// Compiles once for a script that will run repeatedly. Nil if the source
    /// does not compile — a programming error in a static string, logged.
    ///
    /// A compiled `NSAppleScript` is safe to execute again and again on the
    /// main actor (20 consecutive runs verified 2026-09-04). It saves the
    /// ~22ms compile per call; the IPC cost it does not touch.
    static func compile(_ source: String) -> NSAppleScript? {
        guard let script = NSAppleScript(source: bounded(source)) else {
            logger.error("Script failed to parse")
            return nil
        }
        var errorInfo: NSDictionary?
        guard script.compileAndReturnError(&errorInfo) else {
            let code = (errorInfo?[NSAppleScript.errorNumber] as? Int) ?? 0
            logger.error("Script failed to compile (\(code, privacy: .public))")
            return nil
        }
        return script
    }

    /// Executes an already-compiled script.
    static func run(_ script: NSAppleScript) -> Result<NSAppleEventDescriptor, Failure> {
        var errorInfo: NSDictionary?
        let descriptor = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let code = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? 0
            if code == timeoutCode {
                logger.notice(
                    "Apple Event timed out after \(timeoutSeconds, privacy: .public)s; transient, not a permission problem")
            } else {
                logger.notice("Apple Event failed (\(code, privacy: .public))")
            }
            return .failure(Failure(code: code))
        }
        return .success(descriptor)
    }
}
