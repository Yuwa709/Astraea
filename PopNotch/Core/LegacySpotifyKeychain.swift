import Foundation
import Security
import os

/// The one-time removal of the Spotify refresh token that versions up to
/// settings schema 10 kept in the Keychain.
///
/// The Spotify account feature (OAuth, the Web API) is gone; it was the
/// app's only Keychain use. This deletes the item it left behind, once, and
/// records that it ran, so no later launch touches the Keychain at all.
///
/// **What it can and cannot remove** (measured 2026-09-28, macOS 27.0, with
/// ad-hoc-signed probe binaries standing in for two releases):
/// - An item created by a build with the *same* signature deletes silently.
///   That is every Apple Development-signed build on a developer's machine.
/// - An item created by a *differently* signed build is refused at once with
///   `errSecInvalidOwnerEdit` (-25244), **without a prompt**, whether or not
///   user interaction is allowed. Released builds are ad-hoc signed, so every
///   release has a different signature, and an upgrading user's item cannot
///   be deleted from here. It stays in their login keychain, orphaned: no
///   code reads it any more, so it can never prompt again.
///
/// User interaction is disabled around the delete anyway. The measured paths
/// never prompted, but a locked login keychain could otherwise ask to be
/// unlocked, and this must never put a dialog in front of anyone. With it
/// off, that case returns `errSecInteractionNotAllowed` instead.
/// `kSecUseAuthenticationUIFail` is not a substitute: a probe read with it
/// set still blocked on a prompt.
enum LegacySpotifyKeychain {

    private static let logger = Logger(subsystem: "com.techie.PopNotch", category: "LegacySpotifyKeychain")

    /// The item the removed `SpotifyTokenStore` wrote. Exactly these two
    /// attributes, so nothing else in the Keychain can match.
    nonisolated static let service = "com.techie.PopNotch"
    nonisolated static let account = "spotify-refresh-token"

    /// Deletes the legacy item if the settings say one may exist, then clears
    /// the flag whatever the outcome, so this runs at most once per install.
    ///
    /// Clearing on failure is deliberate. A refused delete (the ad-hoc case
    /// above) will be refused identically next launch, so retrying would be a
    /// Keychain call on every launch for nothing.
    ///
    /// `delete` is injectable so tests never reach the real Keychain.
    static func runIfPending(settings: SettingsStore,
                             delete: () -> OSStatus = deleteItem) {
        guard settings.settings.spotifyKeychainCleanupPending else { return }
        let status = delete()
        settings.update { $0.spotifyKeychainCleanupPending = false }
        logger.notice("Legacy Spotify token cleanup ran once: \(describe(status), privacy: .public); not retried")
    }

    /// The real delete, with user interaction off for its duration and
    /// restored afterwards. Touches no app state, hence `nonisolated`.
    nonisolated static func deleteItem() -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // Deprecated since 10.10 with no replacement for the file-based login
        // keychain, where these items live. It is the only switch measured to
        // stop a prompt here; see the type's notes.
        var wasAllowed: DarwinBoolean = true
        let readPrevious = SecKeychainGetUserInteractionAllowed(&wasAllowed) == errSecSuccess
        SecKeychainSetUserInteractionAllowed(false)
        defer {
            if readPrevious { SecKeychainSetUserInteractionAllowed(wasAllowed.boolValue) }
        }
        return SecItemDelete(query as CFDictionary)
    }

    /// The status as a log reads it: what happened, then the raw code.
    static func describe(_ status: OSStatus) -> String {
        switch status {
        case errSecSuccess:
            return "deleted"
        case errSecItemNotFound:
            return "no item"
        case errSecInvalidOwnerEdit:
            return "refused, item owned by another build's signature (OSStatus \(status)); left orphaned"
        case errSecInteractionNotAllowed:
            return "would have needed user interaction (OSStatus \(status)); skipped"
        default:
            return "failed (OSStatus \(status))"
        }
    }
}
