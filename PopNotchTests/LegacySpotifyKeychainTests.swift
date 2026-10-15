import XCTest
import Security
@testable import PopNotch

/// The one-time Keychain cleanup left by the removed Spotify account.
///
/// Every test injects the delete. None may reach the real Keychain: an
/// earlier suite that did deleted the developer's own live token
/// (2026-09-01), and `LegacySpotifyKeychain.deleteItem` targets that very
/// item.
@MainActor
final class LegacySpotifyKeychainTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!
    private var deletes = 0

    override func setUp() {
        super.setUp()
        suiteName = "com.techie.PopNotch.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        deletes = 0
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func store() -> SettingsStore { SettingsStore(defaults: defaults) }

    private func write(_ json: String) {
        defaults.set(Data(json.utf8), forKey: SettingsStore.storageKey)
    }

    /// One launch: the cleanup against a counting fake answering `status`.
    private func launch(answering status: OSStatus = errSecSuccess) {
        LegacySpotifyKeychain.runIfPending(settings: store()) {
            self.deletes += 1
            return status
        }
    }

    // MARK: - At most once

    func testAConnectedUpgradeDeletesOnceAndNeverAgain() {
        write(#"{"schemaVersion": 10, "spotifyAccountConnected": true}"#)

        launch()
        XCTAssertEqual(deletes, 1, "the upgrade launch deletes the token")
        XCTAssertFalse(store().settings.spotifyKeychainCleanupPending, "and records that it ran")

        launch()
        launch()
        XCTAssertEqual(deletes, 1, "no later launch touches the Keychain")
    }

    /// Nil meant nobody knew, which includes a connected user whose Keychain
    /// never answered, so it is cleaned too.
    func testAnUpgradeThatNeverRecordedTheFlagDeletesOnce() {
        write(#"{"schemaVersion": 6}"#)
        launch()
        launch()
        XCTAssertEqual(deletes, 1)
    }

    /// The refused case measured for ad-hoc releases. Retrying cannot
    /// succeed, so it must not be retried either.
    func testARefusedDeleteIsStillRecordedAsRun() {
        write(#"{"schemaVersion": 10, "spotifyAccountConnected": true}"#)

        launch(answering: errSecInvalidOwnerEdit)
        XCTAssertFalse(store().settings.spotifyKeychainCleanupPending)

        launch()
        XCTAssertEqual(deletes, 1, "a refusal is not retried on the next launch")
    }

    func testALockedKeychainIsStillRecordedAsRun() {
        write(#"{"schemaVersion": 10}"#)
        launch(answering: errSecInteractionNotAllowed)
        launch()
        XCTAssertEqual(deletes, 1)
    }

    // MARK: - Never at all

    func testAFreshInstallNeverTouchesTheKeychain() {
        launch()
        launch()
        XCTAssertEqual(deletes, 0)
    }

    func testAnUpgradeWithNoAccountNeverTouchesTheKeychain() {
        write(#"{"schemaVersion": 10, "spotifyAccountConnected": false}"#)
        launch()
        XCTAssertEqual(deletes, 0)
    }

    /// Unreadable settings are parked and replaced by defaults, which reads
    /// as a fresh install: no Keychain call.
    func testUnreadableSettingsNeverTouchTheKeychain() {
        write("not json")
        launch()
        XCTAssertEqual(deletes, 0)
    }

    // MARK: - The target

    /// Pinned to exactly what the removed `SpotifyTokenStore` wrote. Any
    /// drift and the cleanup deletes nothing, or something else.
    func testTargetsTheItemTheOldTokenStoreWrote() {
        XCTAssertEqual(LegacySpotifyKeychain.service, "com.techie.PopNotch")
        XCTAssertEqual(LegacySpotifyKeychain.account, "spotify-refresh-token")
    }
}
