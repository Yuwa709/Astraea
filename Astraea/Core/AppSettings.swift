import Foundation

/// Everything the user can configure, in one `Codable` struct.
///
/// Persisted to UserDefaults as JSON by `SettingsStore`. No SwiftData, no
/// Core Data (hard rule 5). Live system state — the notch's actual contents —
/// is never stored here.
///
/// ## Changing this struct
///
/// Every shape change bumps `currentSchemaVersion` and adds a case to
/// `migrate(_:from:)`, plus a test that loads the previous version's JSON and
/// asserts nothing was dropped. Adding a property with a default is still a
/// shape change: old JSON lacks the key, so decoding must tolerate its
/// absence. That is why every property below has a default and the custom
/// decoder falls back to it rather than throwing.
struct AppSettings: Codable, Equatable {

    /// Bump on every shape change. See the note above.
    /// v2: added spotifyClientID.
    /// v3: added visualizerEnabled.
    /// v4: removed spotifyClientID — the Client ID is the app's own, built in.
    /// v5: added showMenuBarIcon.
    /// v6: added preferMusicOverVideo.
    /// v7: added spotifyAccountConnected.
    /// v8: added capybaraThemeEnabled.
    /// v9: added appVolume.
    /// v10: added appVolume.outputs.
    /// v11: removed spotifyAccountConnected; added spotifyKeychainCleanupPending.
    /// v12: added appVolume.bass.
    /// v13: added faceUnlockAutoLockInterval.
    /// v14: added faceUnlockAtLockScreenEnabled and faceUnlockMatchThreshold.
    /// v15: added faceUnlockLiveness.
    /// v16: added reopenLastPage.
    static let currentSchemaVersion = 16

    var schemaVersion: Int = AppSettings.currentSchemaVersion

    /// Per-module enable state, keyed by permanent `ModuleID`.
    ///
    /// A module absent from this dictionary has never been toggled; the
    /// arbiter treats absence as "use the module's own default" rather than
    /// as disabled, so newly shipped modules can appear without a migration.
    var moduleEnablement: [ModuleID: Bool] = [:]

    /// Seconds the cursor must dwell before the notch expands. User-tuned to
    /// 0.35 on hardware; 0.2 let too much passing traffic through.
    var hoverEnterDelay: TimeInterval = 0.35

    /// Whether a hover reopens the notch on the page it was last closed on
    /// (clipboard, shelf, stats, app volume) rather than the home screen.
    /// **Off by default**: home is the behaviour every install has had.
    /// Only the switch is stored; the page itself is session state.
    var reopenLastPage: Bool = false

    // `spotifyClientID` lived here until v4. It was a per-user field, which
    // was the wrong model: the Client ID identifies *Astraea* to Spotify, not
    // the user, so every install needs the same one. Shipping it empty meant a
    // fresh install had no Client ID at all and Connect was permanently
    // disabled. It became a build-time constant, and v11 removed the Spotify
    // account feature it served altogether.

    /// Whether the menu bar icon is inserted. **Defaults to on**: hiding it
    /// is a deliberate choice, and an agent with no Dock icon, no menu bar
    /// icon and no window is invisible to someone who has forgotten it is
    /// running. Everything the menu offered is reachable without it — the
    /// panel's gear opens Settings, and Quit lives in the About tab.
    var showMenuBarIcon: Bool = true

    /// Audio visualiser. Off by default on purpose: it needs the System
    /// Audio Recording permission, and a capture permission is opt-in, never
    /// something the app assumes.
    var visualizerEnabled: Bool = false

    /// Within the system now-playing source, prefer a track that has an album
    /// over one that does not.
    ///
    /// **Defaults to on.** macOS exposes one session at a time, so this is not
    /// a choice between two candidates — it is whether to accept the one on
    /// offer, and `album` is the only field that tells music from video.
    ///
    /// Narrow on purpose: it holds only while the app, the item and the
    /// playing state all still match, so what it actually absorbs is a
    /// payload that drops the album of the track already on screen. A
    /// genuinely different item is a different session and always wins —
    /// holding across one pinned a paused song to the notch with its scrub
    /// bar still running (hardware, 2026-09-01).
    ///
    /// Off means the system source reports whatever the session says, in
    /// arrival order. Has no effect on Spotify or Apple Music, which have
    /// their own adapters and outrank this source either way.
    var preferMusicOverVideo: Bool = true

    /// Whether an older version may have left a Spotify refresh token in the
    /// Keychain that `LegacySpotifyKeychain` has not yet tried to delete.
    ///
    /// Schema 10 and earlier had an optional Spotify account (OAuth) whose
    /// refresh token lived in the Keychain, and `spotifyAccountConnected`
    /// cached whether one existed. v11 removed the feature, and this flag is
    /// all that is left of it: the one-time cleanup's bookkeeping.
    ///
    /// **False by default**, so a fresh install never touches the Keychain —
    /// it cannot hold a token from a version it never ran. Only decoding a
    /// v10-or-earlier payload sets it (see the decoder), and the cleanup
    /// clears it the first time it runs, whatever the Keychain answers, so
    /// the Keychain is asked at most once per install, ever.
    var spotifyKeychainCleanupPending = false

    /// Capybara theme on the scrub bar: a sprite walks the track as it
    /// plays, towards a finish flag. Off by default — it is decoration, and
    /// a theme nobody chose must not switch itself on across an upgrade.
    var capybaraThemeEnabled: Bool = false

    /// The mixer's per-app volume (`docs/FUTURE-audio-mixer.md`). Absent in
    /// v8 and earlier, which decodes as an empty `AppVolume`: taps off, every
    /// app at its own volume.
    ///
    /// Not optional itself, unlike its fields: as an optional,
    /// `settings.appVolume?.tapsEnabled = true` would compile and do nothing
    /// on every install upgraded from v8.
    var appVolume = AppVolume()

    /// How long an unused Face Unlock session stays unlocked before it locks
    /// itself (`FaceSessionAutoLocker`). Stored as whole days, 0 for never.
    /// **Defaults to 30 days**, as in Glance, where the feature comes from.
    var faceUnlockAutoLockInterval: AutoLockInterval = .default

    /// Whether Face Unlock scans for an enrolled face when the Mac wakes at
    /// the lock screen and types the stored password on a match
    /// (`FaceUnlockCoordinator`). **Off by default**: it types the user's
    /// password and needs the camera and Accessibility, none of which a
    /// user should be opted into.
    var faceUnlockAtLockScreenEnabled: Bool = false

    /// How close a face must be to an enrolled one to unlock. Stored by
    /// preset name, not as a number, so the presets can be retuned without
    /// a migration. **Defaults to balanced** (0.63).
    var faceUnlockMatchThreshold: FaceMatchThreshold = .default

    /// Liveness checking before a lock-screen match types the password.
    /// Stored by name. **Defaults to light**, for upgraded installs too:
    /// without it a photo on a phone can unlock the Mac, and light only
    /// refuses frames that show glare or a device edge round the face.
    var faceUnlockLiveness: FaceLivenessLevel = .default

    /// The tap engine's settings. Spotify's and Music's volumes are never
    /// here: they live in the apps themselves, set through AppleScript. Their
    /// output choice is, because AppleScript cannot route: a routed Spotify
    /// or Music is tapped at unity and its volume stays the app's own.
    ///
    /// **Every field is optional, and nil is the shipped default.** JSON
    /// written before a field existed decodes it as nil rather than
    /// throwing, so adding a field later can't cost the fields beside it.
    struct AppVolume: Equatable {
        /// Whether apps other than Spotify and Music may be tapped. nil means
        /// never set, and reads as off: taps need the audio-recording
        /// permission, and a capture permission is opt-in.
        var tapsEnabled: Bool?

        /// Saved positions, keyed by `AudioOwner.key`, on
        /// `TapReconciler`'s 0...200 scale: 100 is the app's own volume and
        /// 200 twice it, which the slider shows as 50 and 100. The app's own
        /// volume is stored as absence, so an app never adjusted has no
        /// entry. Positions, not gains, so the taper can be retuned without
        /// a migration.
        ///
        /// Until 2026-10-07 the scale stopped at 100, with nothing louder.
        /// Every value saved then means what it did, so v12 JSON loads
        /// unchanged and no schema bump was needed: the range grew, the
        /// meaning of each value did not.
        var volumes: [String: Int]?

        /// Chosen output device per owner (V2 routing), keyed by the same
        /// `AudioOwner.key` as `volumes`. The value is the device's UID, never
        /// its `AudioDeviceID`: a dock reconnect renumbers every device's
        /// object ID (measured in the spike), while a UID survives it. System
        /// default is stored as absence, so an app never routed has no entry.
        /// A saved UID outlives its device being unplugged: the app falls
        /// back to its own output meanwhile and is routed again when the
        /// device returns.
        var outputs: [String: String]?

        /// Bass boost level per owner (V2 Phase 3), keyed by the same
        /// `AudioOwner.key`: 1, 2 or 3, which `BassBoost` maps to +6, +12 and
        /// +18 dB. Levels, not decibels, so the curve can be retuned without
        /// a migration. Off is stored as absence, so an app never boosted
        /// has no entry. Spotify and Music have entries too: boosting them
        /// taps them at unity, as routing does.
        var bass: [String: Int]?
    }

    // MARK: - Decoding

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, moduleEnablement, hoverEnterDelay, visualizerEnabled
        case showMenuBarIcon, preferMusicOverVideo, spotifyKeychainCleanupPending
        case capybaraThemeEnabled, appVolume, faceUnlockAutoLockInterval
        case faceUnlockAtLockScreenEnabled, faceUnlockMatchThreshold, faceUnlockLiveness
        case reopenLastPage
    }

    /// Keys an older schema wrote that this one no longer has. Read only by
    /// the decoder, to carry what they meant into the current shape.
    private enum LegacyCodingKeys: String, CodingKey {
        /// v7...v10. See `spotifyKeychainCleanupPending`.
        case spotifyAccountConnected
    }

    init() {}

    /// Decodes leniently: a missing or malformed individual key falls back to
    /// its default rather than failing the whole load. Losing one preference
    /// is recoverable; losing all of them is what "never wipe user settings
    /// silently" is guarding against.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Every shipped schema wrote this key, so a payload without one (or
        // with a malformed one) is older than all of them, not current:
        // reading it as current skipped every migration step, and with them
        // the Spotify Keychain cleanup below.
        schemaVersion = (try? container.decode(Int.self, forKey: .schemaVersion)) ?? 0
        // Per entry, like `AppVolume`: one malformed toggle loses only
        // itself, not every module preference beside it.
        moduleEnablement = (try? container.decode([ModuleID: LenientBool].self, forKey: .moduleEnablement))?
            .compactMapValues(\.value) ?? [:]
        hoverEnterDelay = (try? container.decode(TimeInterval.self, forKey: .hoverEnterDelay))
            ?? 0.35
        // A v2/v3 payload still carries spotifyClientID. It has no CodingKey
        // any more, so it is ignored rather than throwing — the lenient
        // contract above already covers keys this version does not know.
        visualizerEnabled = (try? container.decode(Bool.self, forKey: .visualizerEnabled))
            ?? false
        // Absent in v4 and earlier, which is exactly the shipped default.
        showMenuBarIcon = (try? container.decode(Bool.self, forKey: .showMenuBarIcon))
            ?? true
        // Absent in v5 and earlier; on is the shipped default.
        preferMusicOverVideo = (try? container.decode(Bool.self, forKey: .preferMusicOverVideo))
            ?? true
        // v11 replaced spotifyAccountConnected with the cleanup flag. The
        // conversion lives here rather than in `migrate` because the old key
        // is the only evidence of whether a token might exist, and `migrate`
        // sees only the decoded struct. Pending unless the old flag was a
        // definite `false`: `true` means a token was stored, and nil (v6 and
        // earlier, or a Keychain that never answered) means nobody knows.
        // A `false` was the Keychain itself saying there was none — asking
        // again would be a Keychain call for nothing.
        if schemaVersion >= 11 {
            spotifyKeychainCleanupPending = (try? container.decode(
                Bool.self, forKey: .spotifyKeychainCleanupPending)) ?? false
        } else {
            let legacy = try? decoder.container(keyedBy: LegacyCodingKeys.self)
            let wasConnected = try? legacy?.decodeIfPresent(
                Bool.self, forKey: .spotifyAccountConnected)
            spotifyKeychainCleanupPending = wasConnected != false
        }
        // Absent in v7 and earlier; off is the shipped default.
        capybaraThemeEnabled = (try? container.decode(Bool.self, forKey: .capybaraThemeEnabled))
            ?? false
        // Absent in v8 and earlier; empty is the shipped default. `try?`
        // also catches a value that is not an object at all.
        appVolume = (try? container.decode(AppVolume.self, forKey: .appVolume))
            ?? AppVolume()
        // Absent in v12 and earlier; 30 days is the shipped default. A
        // number that is not one of the choices falls back to it too.
        faceUnlockAutoLockInterval = (try? container.decode(
            AutoLockInterval.self, forKey: .faceUnlockAutoLockInterval)) ?? .default
        // Absent in v13 and earlier; off is the shipped default.
        faceUnlockAtLockScreenEnabled = (try? container.decode(
            Bool.self, forKey: .faceUnlockAtLockScreenEnabled)) ?? false
        // Absent in v13 and earlier; balanced is the shipped default. A
        // preset name this build does not know falls back to it too.
        faceUnlockMatchThreshold = (try? container.decode(
            FaceMatchThreshold.self, forKey: .faceUnlockMatchThreshold)) ?? .default
        // Absent in v14 and earlier; light is the shipped default. A level
        // this build does not know falls back to it too.
        faceUnlockLiveness = (try? container.decode(
            FaceLivenessLevel.self, forKey: .faceUnlockLiveness)) ?? .default
        // Absent in v15 and earlier; off is the shipped default.
        reopenLastPage = (try? container.decode(Bool.self, forKey: .reopenLastPage))
            ?? false
    }

    /// One saved module toggle, or nil when the stored value is not a Bool.
    private struct LenientBool: Decodable {
        let value: Bool?

        init(from decoder: Decoder) throws {
            value = try? decoder.singleValueContainer().decode(Bool.self)
        }
    }

    // MARK: - Migration

    /// Upgrades settings decoded from an older schema.
    ///
    /// Called by `SettingsStore` after a successful decode, before use. Each
    /// future version adds its own step and falls through to the next, so a
    /// user who skipped several releases still arrives at current.
    ///
    /// A payload from a *newer* schema (the user downgraded) is also stamped
    /// current, because current is the shape this build will write. Keys it
    /// does not know would be lost on the next save, so `SettingsStore`
    /// copies the raw payload aside before anything is written; see
    /// `SettingsStore.newerSchemaKey(_:)`.
    static func migrate(_ settings: AppSettings, from version: Int) -> AppSettings {
        var result = settings

        switch version {
        case ..<1:
            // Pre-versioned JSON — a payload with no schemaVersion, which the
            // decoder reads as 0. The lenient decoder already filled
            // defaults, and treated it as pre-v11 for the Keychain cleanup.
            // Nothing to move.
            result.schemaVersion = 1
            fallthrough
        case 1:
            // v2 added spotifyClientID; the lenient decoder fills "" for v1
            // JSON, which is exactly the not-configured state. Nothing moves.
            fallthrough
        case 2:
            // v3 added visualizerEnabled; the lenient decoder fills false for
            // v2 JSON, which is exactly the off-by-default state. Nothing moves.
            fallthrough
        case 3:
            // v4 removed spotifyClientID. Nothing to move: the value it held
            // was either empty (the broken default) or a hand-pasted copy of
            // an ID the app now supplies itself, and in both cases the built-in
            // constant supersedes it. This is the one case where dropping a
            // stored value is correct rather than a silent wipe — the field
            // no longer has a meaning for the user to have configured.
            fallthrough
        case 4:
            // v5 added showMenuBarIcon; the lenient decoder fills true for v4
            // JSON, which is the on-by-default state. Nothing moves.
            fallthrough
        case 5:
            // v6 added preferMusicOverVideo; the lenient decoder fills true
            // for v5 JSON, which is the on-by-default state. Nothing moves.
            fallthrough
        case 6:
            // v7 added spotifyAccountConnected, left nil here on purpose: only
            // the Keychain knew whether a token existed. v11 removed it; see
            // case 10.
            fallthrough
        case 7:
            // v8 added capybaraThemeEnabled; the lenient decoder fills false
            // for v7 JSON, which is the off-by-default state. Nothing moves.
            fallthrough
        case 8:
            // v9 added appVolume; the lenient decoder fills an empty one for
            // v8 JSON: taps off, no saved volumes. Nothing moves.
            fallthrough
        case 9:
            // v10 added appVolume.outputs; the lenient decoder fills nil for
            // v9 JSON: every app on System default. Taps and saved volumes
            // are untouched. Nothing moves.
            fallthrough
        case 10:
            // v11 removed spotifyAccountConnected with the Spotify account
            // feature, and added spotifyKeychainCleanupPending. The decoder
            // has already converted one into the other; it is the only place
            // the removed key is still visible. Dropping the old flag is not a
            // silent wipe: it cached a fact about the Keychain for a feature
            // that no longer exists, and nothing the user chose is lost.
            fallthrough
        case 11:
            // v12 added appVolume.bass; the lenient decoder fills nil for
            // v11 JSON: no app boosted. Taps, saved volumes and outputs are
            // untouched. Nothing moves.
            fallthrough
        case 12:
            // v13 added faceUnlockAutoLockInterval. No v12 payload can hold
            // it, so it starts at the shipped default, 30 days. Set here
            // explicitly rather than left to the decoder, so the upgrade's
            // value is stated in one place.
            result.faceUnlockAutoLockInterval = .default
            fallthrough
        case 13:
            // v14 added faceUnlockAtLockScreenEnabled and
            // faceUnlockMatchThreshold. No v13 payload can hold either, so
            // they start at the shipped defaults: off, and balanced. Set here
            // explicitly, as in case 12, so the upgrade's values are stated
            // in one place.
            result.faceUnlockAtLockScreenEnabled = false
            result.faceUnlockMatchThreshold = .default
            fallthrough
        case 14:
            // v15 added faceUnlockLiveness. No v14 payload can hold it, so it
            // starts at the shipped default, light, for upgraded installs as
            // for new ones: the match threshold and the lock-screen switch
            // are untouched. Set here explicitly, as in case 12.
            result.faceUnlockLiveness = .default
            fallthrough
        case 15:
            // v16 added reopenLastPage; the lenient decoder fills false for
            // v15 JSON, which is the off-by-default state. Nothing moves.
            fallthrough
        default:
            break
        }

        result.schemaVersion = currentSchemaVersion
        return result
    }
}

// In an extension so `AppVolume` keeps its memberwise initializer.
extension AppSettings.AppVolume: Codable {

    private enum CodingKeys: String, CodingKey {
        case tapsEnabled, volumes, outputs, bass
    }

    /// Lenient the way `AppSettings` is, one level down: a missing or
    /// malformed field decodes as nil, and a malformed volume, output or
    /// bass level loses only its own entry, never another app's.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tapsEnabled = try? container.decodeIfPresent(Bool.self, forKey: .tapsEnabled)
        volumes = (try? container.decodeIfPresent([String: LenientVolume].self, forKey: .volumes))?
            .compactMapValues(\.value)
        outputs = (try? container.decodeIfPresent([String: LenientUID].self, forKey: .outputs))?
            .compactMapValues(\.value)
        bass = (try? container.decodeIfPresent([String: LenientBass].self, forKey: .bass))?
            .compactMapValues(\.value)
    }

    /// One saved volume, or nil when the stored value is not an integer.
    private struct LenientVolume: Decodable {
        let value: Int?

        init(from decoder: Decoder) throws {
            value = try? decoder.singleValueContainer().decode(Int.self)
        }
    }

    /// One saved device UID, or nil when the stored value is not a
    /// non-empty string.
    private struct LenientUID: Decodable {
        let value: String?

        init(from decoder: Decoder) throws {
            let uid = try? decoder.singleValueContainer().decode(String.self)
            value = uid?.isEmpty == false ? uid : nil
        }
    }

    /// One saved bass level, or nil when the stored value is not an integer
    /// from 1 to 3. Off is absence, so a stored 0 is dropped too.
    private struct LenientBass: Decodable {
        let value: Int?

        init(from decoder: Decoder) throws {
            let level = try? decoder.singleValueContainer().decode(Int.self)
            value = level.flatMap { BassBoost.levels.contains($0) ? $0 : nil }
        }
    }
}
