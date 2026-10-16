import XCTest
@testable import PopNotch

/// CLAUDE.md requires that every schemaVersion bump gets a test loading the
/// previous version's JSON and asserting nothing was dropped. Version 1 is
/// the first shipped schema, so these tests pin the current shape and the
/// "never wipe user settings silently" contract that future migrations must
/// keep honouring.
@MainActor
final class AppSettingsTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        // A scratch suite per test, so the developer's real settings are
        // never read or written by the test run.
        suiteName = "com.techie.PopNotch.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func store() -> SettingsStore {
        SettingsStore(defaults: defaults)
    }

    private func write(_ json: String) {
        defaults.set(Data(json.utf8), forKey: SettingsStore.storageKey)
    }

    // MARK: - Round trip

    func testDefaultsWhenNothingStored() {
        let settings = store().settings
        XCTAssertEqual(settings.schemaVersion, AppSettings.currentSchemaVersion)
        XCTAssertEqual(settings.moduleEnablement, [:])
        XCTAssertEqual(settings.hoverEnterDelay, 0.35)
    }

    func testChangesPersistAcrossStoreInstances() {
        let first = store()
        first.setEnabled(false, for: "weather")
        first.update { $0.hoverEnterDelay = 0.5 }

        let reloaded = store()
        XCTAssertEqual(reloaded.settings.moduleEnablement["weather"], false)
        XCTAssertEqual(reloaded.settings.hoverEnterDelay, 0.5)
    }

    func testUnchangedUpdateDoesNotRewrite() {
        let subject = store()
        subject.update { $0.hoverEnterDelay = 0.35 } // already the default
        XCTAssertNil(defaults.data(forKey: SettingsStore.storageKey))
    }

    // MARK: - Module enablement

    func testAbsentModuleFallsBackToItsOwnDefault() {
        let subject = store()
        XCTAssertTrue(subject.isEnabled("never-seen", default: true))
        XCTAssertFalse(subject.isEnabled("never-seen", default: false))
    }

    func testStoredPreferenceBeatsTheDefault() {
        let subject = store()
        subject.setEnabled(false, for: "stats")
        XCTAssertFalse(subject.isEnabled("stats", default: true))
    }

    // MARK: - Lenient decoding

    func testUnknownKeysAreIgnored() {
        write(#"{"schemaVersion":1,"hoverEnterDelay":0.5,"moduleEnablement":{},"futureFeature":true}"#)
        XCTAssertEqual(store().settings.hoverEnterDelay, 0.5)
    }

    func testMissingKeyFallsBackToDefaultWithoutLosingTheRest() {
        // hoverEnterDelay absent, as it would be in JSON written before the
        // key existed. The rest must survive.
        write(#"{"schemaVersion":1,"moduleEnablement":{"stats":false}}"#)
        let settings = store().settings
        XCTAssertEqual(settings.hoverEnterDelay, 0.35)
        XCTAssertEqual(settings.moduleEnablement["stats"], false)
    }

    func testMalformedValueForOneKeyDoesNotDiscardTheOthers() {
        write(#"{"schemaVersion":1,"hoverEnterDelay":"not a number","moduleEnablement":{"stats":false}}"#)
        let settings = store().settings
        XCTAssertEqual(settings.hoverEnterDelay, 0.35, "bad value falls back")
        XCTAssertEqual(settings.moduleEnablement["stats"], false, "good value survives")
    }

    // MARK: - Never wipe silently

    func testUnreadableJSONIsPreservedRatherThanOverwritten() {
        let corrupt = Data("this is not JSON at all".utf8)
        defaults.set(corrupt, forKey: SettingsStore.storageKey)

        let subject = store()
        XCTAssertEqual(subject.settings, AppSettings(), "falls back to defaults")
        XCTAssertEqual(
            defaults.data(forKey: SettingsStore.salvageKey),
            corrupt,
            "the unreadable payload must be kept for recovery"
        )
    }

    // MARK: - Migration

    func testV1JSONMigratesToV2WithNothingDropped() {
        // Exactly what a v1 install persisted. CLAUDE.md requires every
        // schema bump to load the previous version's JSON and prove nothing
        // was dropped.
        write(#"{"schemaVersion":1,"moduleEnablement":{"stats":false},"hoverEnterDelay":0.5}"#)
        let settings = store().settings
        XCTAssertEqual(settings.schemaVersion, AppSettings.currentSchemaVersion)
        XCTAssertEqual(settings.moduleEnablement["stats"], false)
        XCTAssertEqual(settings.hoverEnterDelay, 0.5)
    }

    func testMigrationStampsCurrentVersion() {
        var old = AppSettings()
        old.schemaVersion = 0
        old.moduleEnablement = ["stats": false]

        let migrated = AppSettings.migrate(old, from: 0)
        XCTAssertEqual(migrated.schemaVersion, AppSettings.currentSchemaVersion)
        XCTAssertEqual(migrated.moduleEnablement["stats"], false, "nothing dropped")
    }

    func testCurrentVersionSurvivesMigrationUnchanged() {
        var settings = AppSettings()
        settings.moduleEnablement = ["media": true]
        settings.hoverEnterDelay = 0.42

        XCTAssertEqual(AppSettings.migrate(settings, from: AppSettings.currentSchemaVersion), settings)
    }

    // MARK: - v2 -> v3

    func testV2JSONMigratesWithNothingDropped() throws {
        // Real v2 shape: no visualizerEnabled key.
        let v2 = Data("""
        {"schemaVersion": 2,
         "moduleEnablement": {"system-stats": false},
         "hoverEnterDelay": 0.1,
         "spotifyClientID": "abc123"}
        """.utf8)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: v2)
        let migrated = AppSettings.migrate(decoded, from: 2)

        XCTAssertEqual(migrated.schemaVersion, AppSettings.currentSchemaVersion)
        XCTAssertEqual(migrated.moduleEnablement["system-stats"], false, "nothing dropped")
        XCTAssertEqual(migrated.hoverEnterDelay, 0.1, accuracy: 0.0001, "nothing dropped")
        XCTAssertFalse(migrated.visualizerEnabled,
                       "the new field arrives OFF: a capture permission is opt-in")
    }

    // MARK: - v3 -> v4

    /// v4 removed spotifyClientID. The key is still present in every existing
    /// install's JSON, so the decoder must ignore it rather than throw — if it
    /// threw, the store would fall back to defaults and the user would lose
    /// every other preference, which is precisely the silent wipe CLAUDE.md
    /// forbids.
    func testV3JSONMigratesWithEveryOtherPreferenceIntact() throws {
        // Real v3 shape, including the field that no longer exists.
        let v3 = Data("""
        {"schemaVersion": 3,
         "moduleEnablement": {"system-stats": false, "clipboard": true},
         "hoverEnterDelay": 0.1,
         "spotifyClientID": "290ab45ba19d43599f66bb341cb33c77",
         "visualizerEnabled": true}
        """.utf8)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: v3)
        let migrated = AppSettings.migrate(decoded, from: 3)

        XCTAssertEqual(migrated.schemaVersion, AppSettings.currentSchemaVersion)
        XCTAssertEqual(migrated.moduleEnablement["system-stats"], false, "nothing dropped")
        XCTAssertEqual(migrated.moduleEnablement["clipboard"], true, "nothing dropped")
        XCTAssertEqual(migrated.hoverEnterDelay, 0.1, accuracy: 0.0001, "nothing dropped")
        XCTAssertTrue(migrated.visualizerEnabled, "nothing dropped")
    }

    // MARK: - v5 -> v6

    /// v6 added preferMusicOverVideo. Real v5 JSON has no such key, and it
    /// must arrive ON: an upgrade that silently started letting YouTube
    /// videos replace the music in the notch would read as a regression, not
    /// as a preference nobody set.
    func testV5JSONMigratesWithMusicPreferenceOn() throws {
        let v5 = Data("""
        {"schemaVersion": 5,
         "moduleEnablement": {"clipboard": true, "file-shelf": true, "system-stats": false},
         "hoverEnterDelay": 0.1,
         "visualizerEnabled": true,
         "showMenuBarIcon": false}
        """.utf8)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: v5)
        let migrated = AppSettings.migrate(decoded, from: 5)

        XCTAssertEqual(migrated.schemaVersion, AppSettings.currentSchemaVersion)
        XCTAssertTrue(migrated.preferMusicOverVideo, "upgrading must not change what the notch shows")
        XCTAssertFalse(migrated.showMenuBarIcon, "nothing dropped")
        XCTAssertEqual(migrated.moduleEnablement["clipboard"], true, "nothing dropped")
        XCTAssertEqual(migrated.moduleEnablement["file-shelf"], true, "nothing dropped")
        XCTAssertEqual(migrated.moduleEnablement["system-stats"], false, "nothing dropped")
        XCTAssertEqual(migrated.hoverEnterDelay, 0.1, accuracy: 0.0001, "nothing dropped")
        XCTAssertTrue(migrated.visualizerEnabled, "nothing dropped")
    }

    // MARK: - v4 -> v5

    /// v5 added showMenuBarIcon. Real v4 JSON has no such key, and the icon
    /// must come back ON — an agent with no Dock icon, no menu bar icon and
    /// no window is invisible to someone who has forgotten it is running, so
    /// an upgrade must never hide it silently.
    func testV4JSONMigratesWithTheIconStillShowing() throws {
        let v4 = Data("""
        {"schemaVersion": 4,
         "moduleEnablement": {"clipboard": true, "file-shelf": true, "system-stats": false},
         "hoverEnterDelay": 0.1,
         "visualizerEnabled": true}
        """.utf8)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: v4)
        let migrated = AppSettings.migrate(decoded, from: 4)

        XCTAssertEqual(migrated.schemaVersion, AppSettings.currentSchemaVersion)
        XCTAssertTrue(migrated.showMenuBarIcon, "upgrading must not hide the icon")
        XCTAssertEqual(migrated.moduleEnablement["clipboard"], true, "nothing dropped")
        XCTAssertEqual(migrated.moduleEnablement["file-shelf"], true, "nothing dropped")
        XCTAssertEqual(migrated.moduleEnablement["system-stats"], false, "nothing dropped")
        XCTAssertEqual(migrated.hoverEnterDelay, 0.1, accuracy: 0.0001, "nothing dropped")
        XCTAssertTrue(migrated.visualizerEnabled, "nothing dropped")
    }

    func testMenuBarIconDefaultsOnForAFreshInstall() {
        XCTAssertTrue(AppSettings().showMenuBarIcon)
    }

    // MARK: - v7: the Spotify connected flag

    /// CLAUDE.md's rule: every schemaVersion bump gets a test that loads the
    /// previous version's JSON and asserts nothing was dropped.
    func testV6JSONMigratesToV7WithNothingDropped() throws {
        write("""
        {"schemaVersion": 6,
         "moduleEnablement": {"media": true, "clipboard": false, "system-stats": true},
         "hoverEnterDelay": 0.42,
         "visualizerEnabled": true,
         "showMenuBarIcon": false,
         "preferMusicOverVideo": false}
        """)
        let settings = SettingsStore(defaults: defaults).settings

        XCTAssertEqual(settings.schemaVersion, AppSettings.currentSchemaVersion)
        XCTAssertGreaterThanOrEqual(settings.schemaVersion, 7, "v6 lands at v7 or beyond")
        // Every v6 preference survives untouched.
        XCTAssertEqual(settings.moduleEnablement["media"], true)
        XCTAssertEqual(settings.moduleEnablement["clipboard"], false)
        XCTAssertEqual(settings.moduleEnablement["system-stats"], true)
        XCTAssertEqual(settings.hoverEnterDelay, 0.42, accuracy: 0.0001)
        XCTAssertTrue(settings.visualizerEnabled)
        XCTAssertFalse(settings.showMenuBarIcon)
        XCTAssertFalse(settings.preferMusicOverVideo)
        // v6 JSON cannot say whether a Spotify token exists, so the one-time
        // Keychain cleanup is queued rather than guessed away.
        XCTAssertTrue(settings.spotifyKeychainCleanupPending,
                      "v6 payload must not be read as 'no Spotify token'")
    }

    /// Every pre-v11 payload that never recorded the old connected flag
    /// arrives with the cleanup queued: nothing said there was no token.
    func testEveryOlderSchemaWithoutTheFlagQueuesTheCleanup() throws {
        for version in 1...10 {
            defaults.removePersistentDomain(forName: suiteName)
            write("{\"schemaVersion\": \(version), \"moduleEnablement\": {}}")
            XCTAssertTrue(store().settings.spotifyKeychainCleanupPending,
                          "v\(version) must not claim to know the Spotify state")
        }
    }

    // MARK: - v8: the capybara theme

    /// CLAUDE.md's rule again: real v7 JSON must load with nothing dropped,
    /// and the new flag must arrive OFF — a theme nobody chose must not
    /// switch itself on across an upgrade.
    func testV7JSONMigratesToV8WithNothingDropped() throws {
        write("""
        {"schemaVersion": 7,
         "moduleEnablement": {"media": true, "clipboard": false, "system-stats": true},
         "hoverEnterDelay": 0.42,
         "visualizerEnabled": true,
         "showMenuBarIcon": false,
         "preferMusicOverVideo": false,
         "spotifyAccountConnected": true}
        """)
        let settings = SettingsStore(defaults: defaults).settings

        XCTAssertEqual(settings.schemaVersion, AppSettings.currentSchemaVersion)
        XCTAssertGreaterThanOrEqual(settings.schemaVersion, 8, "v7 lands at v8 or beyond")
        // Every v7 preference survives untouched.
        XCTAssertEqual(settings.moduleEnablement["media"], true)
        XCTAssertEqual(settings.moduleEnablement["clipboard"], false)
        XCTAssertEqual(settings.moduleEnablement["system-stats"], true)
        XCTAssertEqual(settings.hoverEnterDelay, 0.42, accuracy: 0.0001)
        XCTAssertTrue(settings.visualizerEnabled)
        XCTAssertFalse(settings.showMenuBarIcon)
        XCTAssertFalse(settings.preferMusicOverVideo)
        XCTAssertTrue(settings.spotifyKeychainCleanupPending, "a stored token is queued for cleanup")
        XCTAssertFalse(settings.capybaraThemeEnabled, "the new field arrives OFF")
    }

    func testCapybaraThemeDefaultsOffAndRoundTrips() {
        XCTAssertFalse(AppSettings().capybaraThemeEnabled)
        store().update { $0.capybaraThemeEnabled = true }
        XCTAssertTrue(store().settings.capybaraThemeEnabled, "must survive a reload")
    }

    // MARK: - v9: app volume

    /// CLAUDE.md's rule: real v8 JSON loads with nothing dropped. Every v8
    /// field holds a non-default value, so one that silently fell back to its
    /// default would fail here instead of passing unnoticed.
    func testV8JSONMigratesToV9WithNothingDropped() {
        write("""
        {"schemaVersion": 8,
         "moduleEnablement": {"media": true, "clipboard": false, "app-volume": true},
         "hoverEnterDelay": 0.42,
         "visualizerEnabled": true,
         "showMenuBarIcon": false,
         "preferMusicOverVideo": false,
         "spotifyAccountConnected": true,
         "capybaraThemeEnabled": true}
        """)
        let settings = store().settings

        XCTAssertEqual(settings.schemaVersion, AppSettings.currentSchemaVersion)
        XCTAssertGreaterThanOrEqual(settings.schemaVersion, 9, "v8 lands at v9 or beyond")
        // Every v8 preference survives untouched.
        XCTAssertEqual(settings.moduleEnablement, ["media": true, "clipboard": false, "app-volume": true])
        XCTAssertEqual(settings.hoverEnterDelay, 0.42, accuracy: 0.0001)
        XCTAssertTrue(settings.visualizerEnabled)
        XCTAssertFalse(settings.showMenuBarIcon)
        XCTAssertFalse(settings.preferMusicOverVideo)
        XCTAssertTrue(settings.spotifyKeychainCleanupPending)
        XCTAssertTrue(settings.capybaraThemeEnabled)
        // And the new struct arrives empty.
        XCTAssertNil(settings.appVolume.tapsEnabled, "taps arrive off: a capture permission is opt-in")
        XCTAssertNil(settings.appVolume.volumes, "no app arrives turned down")
        XCTAssertNil(defaults.data(forKey: SettingsStore.salvageKey), "nothing was unreadable")
    }

    func testAppVolumeDefaultsEmptyAndRoundTrips() {
        XCTAssertEqual(AppSettings().appVolume, AppSettings.AppVolume())
        let saved = ["com.hnc.Discord": 35,
                     AudioOwnerResolver.webContentKey: 60,
                     "path:/opt/homebrew/bin/mpv": 0]
        store().update {
            $0.appVolume.tapsEnabled = true
            $0.appVolume.volumes = saved
        }
        let reloaded = store().settings.appVolume
        XCTAssertEqual(reloaded.tapsEnabled, true, "must survive a reload")
        XCTAssertEqual(reloaded.volumes, saved, "every key shape must survive a reload")
    }

    /// What the optional fields and `try?` exist to prevent: a bad
    /// `appVolume` costs only itself, and never reaches the store's catch,
    /// which would reset every other setting.
    func testMalformedAppVolumeDoesNotDiscardTheOtherSettings() {
        write(#"{"schemaVersion":9,"hoverEnterDelay":0.5,"moduleEnablement":{"stats":false},"appVolume":"loud"}"#)
        let settings = store().settings
        XCTAssertEqual(settings.appVolume, AppSettings.AppVolume(), "bad value falls back")
        XCTAssertEqual(settings.hoverEnterDelay, 0.5, "the rest survives")
        XCTAssertEqual(settings.moduleEnablement["stats"], false, "the rest survives")
        XCTAssertNil(defaults.data(forKey: SettingsStore.salvageKey), "the catch never ran")
    }

    func testOneMalformedAppVolumeValueCostsOnlyItself() {
        write("""
        {"schemaVersion": 9,
         "appVolume": {"tapsEnabled": "yes",
                       "volumes": {"com.hnc.Discord": 35, "webkit": "quiet"}}}
        """)
        let appVolume = store().settings.appVolume
        XCTAssertNil(appVolume.tapsEnabled, "a malformed flag reads as never set: off")
        XCTAssertEqual(appVolume.volumes, ["com.hnc.Discord": 35],
                       "a malformed entry loses itself, not the other apps' volumes")
    }

    // MARK: - v10: output routing

    /// CLAUDE.md's rule: real v9 JSON loads with nothing dropped. Every v9
    /// field holds a non-default value, the app-volume ones included, so one
    /// that silently fell back to its default would fail here.
    func testV9JSONMigratesToV10WithNothingDropped() {
        write("""
        {"schemaVersion": 9,
         "moduleEnablement": {"media": true, "clipboard": false, "app-volume": true},
         "hoverEnterDelay": 0.42,
         "visualizerEnabled": true,
         "showMenuBarIcon": false,
         "preferMusicOverVideo": false,
         "spotifyAccountConnected": true,
         "capybaraThemeEnabled": true,
         "appVolume": {"tapsEnabled": true,
                       "volumes": {"com.hnc.Discord": 35, "webkit": 60}}}
        """)
        let settings = store().settings

        XCTAssertEqual(settings.schemaVersion, AppSettings.currentSchemaVersion)
        XCTAssertGreaterThanOrEqual(settings.schemaVersion, 10, "v9 lands at v10 or beyond")
        XCTAssertEqual(settings.moduleEnablement, ["media": true, "clipboard": false, "app-volume": true])
        XCTAssertEqual(settings.hoverEnterDelay, 0.42, accuracy: 0.0001)
        XCTAssertTrue(settings.visualizerEnabled)
        XCTAssertFalse(settings.showMenuBarIcon)
        XCTAssertFalse(settings.preferMusicOverVideo)
        XCTAssertTrue(settings.spotifyKeychainCleanupPending)
        XCTAssertTrue(settings.capybaraThemeEnabled)
        XCTAssertEqual(settings.appVolume.tapsEnabled, true, "taps stay on across the upgrade")
        XCTAssertEqual(settings.appVolume.volumes, ["com.hnc.Discord": 35, "webkit": 60],
                       "every saved volume survives")
        XCTAssertNil(settings.appVolume.outputs, "every app arrives on System default")
        XCTAssertNil(defaults.data(forKey: SettingsStore.salvageKey), "nothing was unreadable")
    }

    func testOutputsRoundTripByDeviceUID() {
        let saved = ["com.hnc.Discord": "AppleUSBAudioEngine:Apple, Inc.:EarPods:1",
                     SpotifyAdapter.bundleID: "44-A7-F4-2C-B3-DA:output"]
        store().update { $0.appVolume.outputs = saved }
        XCTAssertEqual(store().settings.appVolume.outputs, saved, "must survive a reload")
    }

    func testOneMalformedOutputCostsOnlyItself() {
        write("""
        {"schemaVersion": 10,
         "appVolume": {"volumes": {"com.hnc.Discord": 35},
                       "outputs": {"com.hnc.Discord": "usb", "webkit": 42, "org.chromium": ""}}}
        """)
        let appVolume = store().settings.appVolume
        XCTAssertEqual(appVolume.outputs, ["com.hnc.Discord": "usb"],
                       "a non-string or empty UID loses itself, not the other apps' outputs")
        XCTAssertEqual(appVolume.volumes, ["com.hnc.Discord": 35], "and never the volumes beside it")
    }

    // MARK: - v11: the Spotify account removed

    /// CLAUDE.md's rule: real v10 JSON loads with nothing dropped. Every v10
    /// field holds a non-default value, so one that silently fell back to its
    /// default would fail here. The one field v11 removes is converted, not
    /// dropped: a stored token becomes a queued cleanup.
    func testV10JSONMigratesToV11WithNothingDropped() {
        write("""
        {"schemaVersion": 10,
         "moduleEnablement": {"media": true, "clipboard": false, "app-volume": true},
         "hoverEnterDelay": 0.42,
         "visualizerEnabled": true,
         "showMenuBarIcon": false,
         "preferMusicOverVideo": false,
         "spotifyAccountConnected": true,
         "capybaraThemeEnabled": true,
         "appVolume": {"tapsEnabled": true,
                       "volumes": {"com.hnc.Discord": 35, "webkit": 60},
                       "outputs": {"com.hnc.Discord": "usb-uid"}}}
        """)
        let settings = store().settings

        XCTAssertGreaterThanOrEqual(settings.schemaVersion, 11, "v10 lands at v11 or beyond")
        XCTAssertEqual(settings.schemaVersion, AppSettings.currentSchemaVersion)
        XCTAssertEqual(settings.moduleEnablement, ["media": true, "clipboard": false, "app-volume": true])
        XCTAssertEqual(settings.hoverEnterDelay, 0.42, accuracy: 0.0001)
        XCTAssertTrue(settings.visualizerEnabled)
        XCTAssertFalse(settings.showMenuBarIcon)
        XCTAssertFalse(settings.preferMusicOverVideo)
        XCTAssertTrue(settings.capybaraThemeEnabled)
        XCTAssertEqual(settings.appVolume.tapsEnabled, true)
        XCTAssertEqual(settings.appVolume.volumes, ["com.hnc.Discord": 35, "webkit": 60])
        XCTAssertEqual(settings.appVolume.outputs, ["com.hnc.Discord": "usb-uid"])
        XCTAssertTrue(settings.spotifyKeychainCleanupPending, "a stored token is queued for cleanup")
        XCTAssertNil(defaults.data(forKey: SettingsStore.salvageKey), "nothing was unreadable")
    }

    /// A definite `false` was the Keychain itself saying there was no token,
    /// so the cleanup is not queued: that user's launch never touches the
    /// Keychain at all.
    func testV10DefiniteNoAccountDoesNotQueueTheCleanup() {
        write(#"{"schemaVersion": 10, "spotifyAccountConnected": false}"#)
        XCTAssertFalse(store().settings.spotifyKeychainCleanupPending)
    }

    /// A fresh install cannot hold a token from a version it never ran, so
    /// it must never be sent to the Keychain.
    func testFreshInstallNeverQueuesTheCleanup() {
        XCTAssertFalse(AppSettings().spotifyKeychainCleanupPending)
        XCTAssertFalse(store().settings.spotifyKeychainCleanupPending,
                       "nothing stored reads as a fresh install")
    }

    /// The removed key is not written back: the first save after upgrading
    /// persists v11's shape, and the cleared flag stays cleared.
    func testTheRemovedFlagIsNotWrittenBack() throws {
        write(#"{"schemaVersion": 10, "spotifyAccountConnected": true, "hoverEnterDelay": 0.5}"#)
        store().update { $0.spotifyKeychainCleanupPending = false }

        let data = try XCTUnwrap(defaults.data(forKey: SettingsStore.storageKey))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["spotifyAccountConnected"], "the removed field must not be persisted")
        XCTAssertEqual(json["schemaVersion"] as? Int, AppSettings.currentSchemaVersion)
        XCTAssertEqual(json["spotifyKeychainCleanupPending"] as? Bool, false)
        XCTAssertFalse(store().settings.spotifyKeychainCleanupPending, "cleared survives a reload")
        XCTAssertEqual(store().settings.hoverEnterDelay, 0.5, "and nothing else moved")
    }

    /// Once a payload is v11, only the new key counts. A stray old key must
    /// not re-arm a cleanup that already ran, or the Keychain would be asked
    /// again on every launch.
    func testAV11PayloadIgnoresAStrayLegacyKey() {
        write(#"{"schemaVersion": 11, "spotifyKeychainCleanupPending": false, "spotifyAccountConnected": true}"#)
        XCTAssertFalse(store().settings.spotifyKeychainCleanupPending)
        write(#"{"schemaVersion": 11, "spotifyKeychainCleanupPending": true}"#)
        XCTAssertTrue(store().settings.spotifyKeychainCleanupPending, "a pending flag survives a reload")
    }

    // MARK: - v12: bass boost

    /// CLAUDE.md's rule: real v11 JSON loads with nothing dropped. Every v11
    /// field holds a non-default value, so one that silently fell back to
    /// its default would fail here; the new field arrives empty.
    func testV11JSONMigratesToV12WithNothingDropped() {
        write("""
        {"schemaVersion": 11,
         "moduleEnablement": {"media": true, "clipboard": false, "app-volume": true},
         "hoverEnterDelay": 0.42,
         "visualizerEnabled": true,
         "showMenuBarIcon": false,
         "preferMusicOverVideo": false,
         "spotifyKeychainCleanupPending": true,
         "capybaraThemeEnabled": true,
         "appVolume": {"tapsEnabled": true,
                       "volumes": {"com.hnc.Discord": 35, "webkit": 60},
                       "outputs": {"com.hnc.Discord": "usb-uid"}}}
        """)
        let settings = store().settings

        XCTAssertGreaterThanOrEqual(settings.schemaVersion, 12, "v11 lands at v12 or beyond")
        XCTAssertEqual(settings.schemaVersion, AppSettings.currentSchemaVersion)
        XCTAssertEqual(settings.moduleEnablement, ["media": true, "clipboard": false, "app-volume": true])
        XCTAssertEqual(settings.hoverEnterDelay, 0.42, accuracy: 0.0001)
        XCTAssertTrue(settings.visualizerEnabled)
        XCTAssertFalse(settings.showMenuBarIcon)
        XCTAssertFalse(settings.preferMusicOverVideo)
        XCTAssertTrue(settings.spotifyKeychainCleanupPending)
        XCTAssertTrue(settings.capybaraThemeEnabled)
        XCTAssertEqual(settings.appVolume.tapsEnabled, true)
        XCTAssertEqual(settings.appVolume.volumes, ["com.hnc.Discord": 35, "webkit": 60])
        XCTAssertEqual(settings.appVolume.outputs, ["com.hnc.Discord": "usb-uid"])
        XCTAssertNil(settings.appVolume.bass, "no app arrives boosted")
        XCTAssertNil(defaults.data(forKey: SettingsStore.salvageKey), "nothing was unreadable")
    }

    func testBassLevelsRoundTripAndPersistAtV12() throws {
        let saved = ["com.hnc.Discord": 1, SpotifyAdapter.bundleID: 3]
        store().update { $0.appVolume.bass = saved }
        XCTAssertEqual(store().settings.appVolume.bass, saved, "must survive a reload")

        let data = try XCTUnwrap(defaults.data(forKey: SettingsStore.storageKey))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["schemaVersion"] as? Int, AppSettings.currentSchemaVersion)
        let appVolume = try XCTUnwrap(json["appVolume"] as? [String: Any])
        XCTAssertEqual(appVolume["bass"] as? [String: Int], saved, "stored as levels, not decibels")
    }

    /// A level that is not an integer from 1 to 3 loses only its own entry.
    /// 0 is off, which is stored as absence, so a stored 0 is dropped too.
    func testOneMalformedBassLevelCostsOnlyItself() {
        write("""
        {"schemaVersion": 12,
         "appVolume": {"volumes": {"com.hnc.Discord": 35},
                       "outputs": {"com.hnc.Discord": "usb"},
                       "bass": {"com.hnc.Discord": 2, "webkit": 7, "org.chromium": "loud",
                                "com.apple.Safari": 0, "us.zoom.xos": -1}}}
        """)
        let appVolume = store().settings.appVolume
        XCTAssertEqual(appVolume.bass, ["com.hnc.Discord": 2])
        XCTAssertEqual(appVolume.volumes, ["com.hnc.Discord": 35], "never the volumes beside it")
        XCTAssertEqual(appVolume.outputs, ["com.hnc.Discord": "usb"], "nor the outputs")
    }

    // MARK: - Volume boost (no schema change)

    /// Volumes saved before the boost existed load as the same numbers, and
    /// so play at the same loudness: 35 is still 35% of the app's own
    /// volume, now shown at 18 on a slider whose middle is the app's own.
    func testVolumesSavedBeforeTheBoostKeepTheirLoudness() {
        write("""
        {"schemaVersion": 12,
         "appVolume": {"tapsEnabled": true, "volumes": {"com.hnc.Discord": 35, "webkit": 60}}}
        """)
        let volumes = store().settings.appVolume.volumes
        XCTAssertEqual(volumes, ["com.hnc.Discord": 35, "webkit": 60])
        XCTAssertEqual(TapReconciler.gain(atPosition: volumes?["com.hnc.Discord"] ?? 0), 0.35)
        XCTAssertEqual(TapReconciler.sliderValue(atPosition: 35), 18)
    }

    func testABoostedVolumeRoundTrips() {
        store().update { $0.appVolume.volumes = ["com.hnc.Discord": 170] }
        XCTAssertEqual(store().settings.appVolume.volumes, ["com.hnc.Discord": 170])
        XCTAssertEqual(store().settings.schemaVersion, AppSettings.currentSchemaVersion,
                       "the range grew; the shape did not")
    }

    func testBassThatIsNotAnObjectCostsOnlyItself() {
        write(#"{"schemaVersion": 12, "appVolume": {"tapsEnabled": true, "bass": [1, 2]}}"#)
        let appVolume = store().settings.appVolume
        XCTAssertNil(appVolume.bass)
        XCTAssertEqual(appVolume.tapsEnabled, true)
    }

    // MARK: - v13: Face Unlock auto-lock

    /// CLAUDE.md's rule: real v12 JSON loads with nothing dropped. Every v12
    /// field holds a non-default value, so one that silently fell back to
    /// its default would fail here; the new field arrives at 30 days.
    func testV12JSONMigratesToV13WithNothingDropped() {
        write("""
        {"schemaVersion": 12,
         "moduleEnablement": {"media": true, "clipboard": false, "app-volume": true},
         "hoverEnterDelay": 0.42,
         "visualizerEnabled": true,
         "showMenuBarIcon": false,
         "preferMusicOverVideo": false,
         "spotifyKeychainCleanupPending": true,
         "capybaraThemeEnabled": true,
         "appVolume": {"tapsEnabled": true,
                       "volumes": {"com.hnc.Discord": 35, "webkit": 60},
                       "outputs": {"com.hnc.Discord": "usb-uid"},
                       "bass": {"com.hnc.Discord": 2}}}
        """)
        let settings = store().settings

        XCTAssertGreaterThanOrEqual(settings.schemaVersion, 13, "v12 lands at v13 or beyond")
        XCTAssertEqual(settings.schemaVersion, AppSettings.currentSchemaVersion)
        XCTAssertEqual(settings.moduleEnablement, ["media": true, "clipboard": false, "app-volume": true])
        XCTAssertEqual(settings.hoverEnterDelay, 0.42, accuracy: 0.0001)
        XCTAssertTrue(settings.visualizerEnabled)
        XCTAssertFalse(settings.showMenuBarIcon)
        XCTAssertFalse(settings.preferMusicOverVideo)
        XCTAssertTrue(settings.spotifyKeychainCleanupPending)
        XCTAssertTrue(settings.capybaraThemeEnabled)
        XCTAssertEqual(settings.appVolume.tapsEnabled, true)
        XCTAssertEqual(settings.appVolume.volumes, ["com.hnc.Discord": 35, "webkit": 60])
        XCTAssertEqual(settings.appVolume.outputs, ["com.hnc.Discord": "usb-uid"])
        XCTAssertEqual(settings.appVolume.bass, ["com.hnc.Discord": 2])
        XCTAssertEqual(settings.faceUnlockAutoLockInterval, .thirtyDays, "the shipped default")
        XCTAssertNil(defaults.data(forKey: SettingsStore.salvageKey), "nothing was unreadable")
    }

    func testAutoLockIntervalRoundTripsAsDays() throws {
        XCTAssertEqual(AppSettings().faceUnlockAutoLockInterval, .thirtyDays)
        store().update { $0.faceUnlockAutoLockInterval = .never }
        XCTAssertEqual(store().settings.faceUnlockAutoLockInterval, .never, "must survive a reload")

        let data = try XCTUnwrap(defaults.data(forKey: SettingsStore.storageKey))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["faceUnlockAutoLockInterval"] as? Int, 0, "never is stored as 0 days")
    }

    /// A number that is not one of the choices loses only itself.
    func testUnknownAutoLockIntervalFallsBackToTheDefault() {
        write(#"{"schemaVersion": 13, "faceUnlockAutoLockInterval": 3, "hoverEnterDelay": 0.5}"#)
        let settings = store().settings
        XCTAssertEqual(settings.faceUnlockAutoLockInterval, .thirtyDays)
        XCTAssertEqual(settings.hoverEnterDelay, 0.5)
    }

    // MARK: - v14: Face Unlock at the lock screen

    /// CLAUDE.md's rule: real v13 JSON loads with nothing dropped. Every v13
    /// field holds a non-default value, so one that silently fell back to
    /// its default would fail here; the new fields arrive off and balanced.
    func testV13JSONMigratesToV14WithNothingDropped() {
        write("""
        {"schemaVersion": 13,
         "moduleEnablement": {"media": true, "clipboard": false, "app-volume": true},
         "hoverEnterDelay": 0.42,
         "visualizerEnabled": true,
         "showMenuBarIcon": false,
         "preferMusicOverVideo": false,
         "spotifyKeychainCleanupPending": true,
         "capybaraThemeEnabled": true,
         "appVolume": {"tapsEnabled": true,
                       "volumes": {"com.hnc.Discord": 35, "webkit": 60},
                       "outputs": {"com.hnc.Discord": "usb-uid"},
                       "bass": {"com.hnc.Discord": 2}},
         "faceUnlockAutoLockInterval": 7}
        """)
        let settings = store().settings

        XCTAssertGreaterThanOrEqual(settings.schemaVersion, 14, "v13 lands at v14 or beyond")
        XCTAssertEqual(settings.schemaVersion, AppSettings.currentSchemaVersion)
        XCTAssertEqual(settings.moduleEnablement, ["media": true, "clipboard": false, "app-volume": true])
        XCTAssertEqual(settings.hoverEnterDelay, 0.42, accuracy: 0.0001)
        XCTAssertTrue(settings.visualizerEnabled)
        XCTAssertFalse(settings.showMenuBarIcon)
        XCTAssertFalse(settings.preferMusicOverVideo)
        XCTAssertTrue(settings.spotifyKeychainCleanupPending)
        XCTAssertTrue(settings.capybaraThemeEnabled)
        XCTAssertEqual(settings.appVolume.tapsEnabled, true)
        XCTAssertEqual(settings.appVolume.volumes, ["com.hnc.Discord": 35, "webkit": 60])
        XCTAssertEqual(settings.appVolume.outputs, ["com.hnc.Discord": "usb-uid"])
        XCTAssertEqual(settings.appVolume.bass, ["com.hnc.Discord": 2])
        XCTAssertEqual(settings.faceUnlockAutoLockInterval, .sevenDays)
        XCTAssertFalse(settings.faceUnlockAtLockScreenEnabled, "off is the shipped default")
        XCTAssertEqual(settings.faceUnlockMatchThreshold, .balanced, "the shipped default")
        XCTAssertNil(defaults.data(forKey: SettingsStore.salvageKey), "nothing was unreadable")
    }

    func testLockScreenFaceUnlockSettingsRoundTrip() throws {
        XCTAssertFalse(AppSettings().faceUnlockAtLockScreenEnabled)
        XCTAssertEqual(AppSettings().faceUnlockMatchThreshold, .balanced)
        store().update {
            $0.faceUnlockAtLockScreenEnabled = true
            $0.faceUnlockMatchThreshold = .strict
        }
        let reloaded = store().settings
        XCTAssertTrue(reloaded.faceUnlockAtLockScreenEnabled, "must survive a reload")
        XCTAssertEqual(reloaded.faceUnlockMatchThreshold, .strict, "must survive a reload")

        let data = try XCTUnwrap(defaults.data(forKey: SettingsStore.storageKey))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["faceUnlockMatchThreshold"] as? String, "strict", "stored by preset name")
        XCTAssertEqual(json["faceUnlockAtLockScreenEnabled"] as? Bool, true)
    }

    /// A preset name or flag this build does not understand loses only itself.
    func testMalformedLockScreenFaceUnlockSettingsFallBackToDefaults() {
        write(#"{"schemaVersion": 14, "faceUnlockMatchThreshold": "paranoid", "faceUnlockAtLockScreenEnabled": "yes", "hoverEnterDelay": 0.5}"#)
        let settings = store().settings
        XCTAssertEqual(settings.faceUnlockMatchThreshold, .balanced)
        XCTAssertFalse(settings.faceUnlockAtLockScreenEnabled)
        XCTAssertEqual(settings.hoverEnterDelay, 0.5)
    }

    /// face-reidentification-retail-0095's scale (ArcFace's was 0.58/0.63/0.68).
    func testMatchThresholdPresets() {
        XCTAssertEqual(FaceMatchThreshold.lenient.value, 0.68)
        XCTAssertEqual(FaceMatchThreshold.balanced.value, 0.72)
        XCTAssertEqual(FaceMatchThreshold.strict.value, 0.76)
        XCTAssertEqual(FaceMatchThreshold.default, .balanced)
    }

    /// The model swap retuned the numbers, not the stored names: settings
    /// saved before it still decode to the same preset, so no migration.
    func testMatchThresholdPresetNamesSurviveTheModelSwap() {
        XCTAssertEqual(FaceMatchThreshold.allCases.map(\.rawValue), ["lenient", "balanced", "strict"])
        XCTAssertLessThan(FaceMatchThreshold.lenient.value, FaceMatchThreshold.balanced.value)
        XCTAssertLessThan(FaceMatchThreshold.balanced.value, FaceMatchThreshold.strict.value)
        write(#"{"schemaVersion": 15, "faceUnlockMatchThreshold": "lenient", "hoverEnterDelay": 0.5}"#)
        XCTAssertEqual(store().settings.faceUnlockMatchThreshold, .lenient)
    }

    // MARK: - v15: Face Unlock liveness

    /// CLAUDE.md's rule: real v14 JSON loads with nothing dropped. Every v14
    /// field holds a non-default value; liveness arrives at light, for an
    /// upgraded install as for a new one.
    func testV14JSONMigratesToV15WithNothingDropped() {
        write("""
        {"schemaVersion": 14,
         "moduleEnablement": {"media": true, "clipboard": false, "app-volume": true},
         "hoverEnterDelay": 0.42,
         "visualizerEnabled": true,
         "showMenuBarIcon": false,
         "preferMusicOverVideo": false,
         "spotifyKeychainCleanupPending": true,
         "capybaraThemeEnabled": true,
         "appVolume": {"tapsEnabled": true,
                       "volumes": {"com.hnc.Discord": 35, "webkit": 60},
                       "outputs": {"com.hnc.Discord": "usb-uid"},
                       "bass": {"com.hnc.Discord": 2}},
         "faceUnlockAutoLockInterval": 7,
         "faceUnlockAtLockScreenEnabled": true,
         "faceUnlockMatchThreshold": "strict"}
        """)
        let settings = store().settings

        XCTAssertEqual(settings.schemaVersion, 15)
        XCTAssertEqual(settings.schemaVersion, AppSettings.currentSchemaVersion)
        XCTAssertEqual(settings.moduleEnablement, ["media": true, "clipboard": false, "app-volume": true])
        XCTAssertEqual(settings.hoverEnterDelay, 0.42, accuracy: 0.0001)
        XCTAssertTrue(settings.visualizerEnabled)
        XCTAssertFalse(settings.showMenuBarIcon)
        XCTAssertFalse(settings.preferMusicOverVideo)
        XCTAssertTrue(settings.spotifyKeychainCleanupPending)
        XCTAssertTrue(settings.capybaraThemeEnabled)
        XCTAssertEqual(settings.appVolume.tapsEnabled, true)
        XCTAssertEqual(settings.appVolume.volumes, ["com.hnc.Discord": 35, "webkit": 60])
        XCTAssertEqual(settings.appVolume.outputs, ["com.hnc.Discord": "usb-uid"])
        XCTAssertEqual(settings.appVolume.bass, ["com.hnc.Discord": 2])
        XCTAssertEqual(settings.faceUnlockAutoLockInterval, .sevenDays)
        XCTAssertTrue(settings.faceUnlockAtLockScreenEnabled)
        XCTAssertEqual(settings.faceUnlockMatchThreshold, .strict)
        XCTAssertEqual(settings.faceUnlockLiveness, .light, "the shipped default, for upgraded installs too")
        XCTAssertNil(defaults.data(forKey: SettingsStore.salvageKey), "nothing was unreadable")
    }

    func testLivenessLevelRoundTripsByName() throws {
        XCTAssertEqual(AppSettings().faceUnlockLiveness, .light)
        store().update { $0.faceUnlockLiveness = .off }
        XCTAssertEqual(store().settings.faceUnlockLiveness, .off, "must survive a reload")

        let data = try XCTUnwrap(defaults.data(forKey: SettingsStore.storageKey))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["faceUnlockLiveness"] as? String, "off", "stored by name")
    }

    /// A level from a later build ("heavy") or a wrong type loses only itself.
    func testUnknownLivenessLevelFallsBackToLight() {
        write(#"{"schemaVersion": 15, "faceUnlockLiveness": "heavy", "faceUnlockMatchThreshold": "strict", "hoverEnterDelay": 0.5}"#)
        var settings = store().settings
        XCTAssertEqual(settings.faceUnlockLiveness, .light)
        XCTAssertEqual(settings.faceUnlockMatchThreshold, .strict)
        XCTAssertEqual(settings.hoverEnterDelay, 0.5)

        write(#"{"schemaVersion": 15, "faceUnlockLiveness": 1, "hoverEnterDelay": 0.5}"#)
        settings = store().settings
        XCTAssertEqual(settings.faceUnlockLiveness, .light)
        XCTAssertEqual(settings.hoverEnterDelay, 0.5)
    }

    // MARK: - Module toggles decode per entry

    func testOneMalformedModuleToggleCostsOnlyItself() {
        write("""
        {"schemaVersion": 12,
         "moduleEnablement": {"stats": false, "media": "yes", "weather": true, "clipboard": 1}}
        """)
        let enablement = store().settings.moduleEnablement
        XCTAssertEqual(enablement, ["stats": false, "weather": true],
                       "only the entries that are not Bools are dropped")
        XCTAssertNil(defaults.data(forKey: SettingsStore.salvageKey), "nothing was unreadable")
    }

    // MARK: - A payload with no schemaVersion

    /// Every shipped schema wrote its version, so a payload without one is
    /// older than all of them. Read as current, it skipped every migration
    /// step, the Spotify Keychain cleanup with them.
    func testPayloadWithoutSchemaVersionIsMigratedFromTheStart() {
        write(#"{"moduleEnablement": {"stats": false}, "hoverEnterDelay": 0.5, "spotifyAccountConnected": true}"#)
        let settings = store().settings
        XCTAssertEqual(settings.schemaVersion, AppSettings.currentSchemaVersion)
        XCTAssertEqual(settings.moduleEnablement["stats"], false, "nothing dropped")
        XCTAssertEqual(settings.hoverEnterDelay, 0.5, "nothing dropped")
        XCTAssertTrue(settings.spotifyKeychainCleanupPending,
                      "a stored Spotify token must still be cleaned up")
    }

    func testMissingSchemaVersionDecodesAsZero() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"hoverEnterDelay": 0.5}"#.utf8))
        XCTAssertEqual(decoded.schemaVersion, 0)
    }

    // MARK: - A payload from a newer schema (downgrade)

    /// A downgraded build must not drop what a newer one wrote. The payload
    /// is kept verbatim under a per-version key before anything is written,
    /// and the keys this build knows still load.
    func testPayloadFromANewerSchemaIsPreservedBeforeAnyWrite() throws {
        let newer = AppSettings.currentSchemaVersion + 1
        let json = """
        {"schemaVersion": \(newer),
         "moduleEnablement": {"stats": false},
         "hoverEnterDelay": 0.5,
         "capybaraThemeEnabled": true,
         "someFutureFeature": {"enabled": true, "level": 3}}
        """
        let original = Data(json.utf8)
        defaults.set(original, forKey: SettingsStore.storageKey)

        let subject = store()
        XCTAssertEqual(subject.settings.moduleEnablement["stats"], false)
        XCTAssertEqual(subject.settings.hoverEnterDelay, 0.5)
        XCTAssertTrue(subject.settings.capybaraThemeEnabled)
        let key = SettingsStore.newerSchemaKey(newer)
        XCTAssertEqual(defaults.data(forKey: key), original,
                       "preserved at load, before any write")

        // The next save writes this build's shape over the main key, and
        // the newer payload must survive it.
        subject.update { $0.hoverEnterDelay = 0.6 }
        let saved = try XCTUnwrap(defaults.data(forKey: SettingsStore.storageKey))
        let savedJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        XCTAssertNil(savedJSON["someFutureFeature"], "this build cannot write what it does not know")
        XCTAssertEqual(defaults.data(forKey: key), original, "so the original is still kept aside")
        XCTAssertNil(defaults.data(forKey: SettingsStore.salvageKey), "nothing was unreadable")
    }

    func testANewerPayloadIsPreservedOnceAcrossLaunches() {
        let newer = AppSettings.currentSchemaVersion + 1
        write("{\"schemaVersion\": \(newer), \"hoverEnterDelay\": 0.5}")
        _ = store()
        _ = store()
        let slots = SettingsStore.preservedSlotKeys(for: SettingsStore.newerSchemaKey(newer))
        XCTAssertNotNil(defaults.data(forKey: slots[0]))
        XCTAssertNil(defaults.data(forKey: slots[1]), "the same bytes are not stored twice")
    }

    func testCurrentPayloadIsNotPreservedAsNewer() {
        write("{\"schemaVersion\": \(AppSettings.currentSchemaVersion), \"hoverEnterDelay\": 0.5}")
        _ = store()
        XCTAssertNil(defaults.data(forKey: SettingsStore.newerSchemaKey(AppSettings.currentSchemaVersion)))
    }

    // MARK: - Salvage slots

    func testEachUnreadablePayloadKeepsItsOwnSlot() {
        let first = Data("first corrupt payload".utf8)
        let second = Data("second corrupt payload".utf8)
        defaults.set(first, forKey: SettingsStore.storageKey)
        _ = store()
        _ = store() // the same bytes again, as on every launch until a save
        defaults.set(second, forKey: SettingsStore.storageKey)
        _ = store()

        let slots = SettingsStore.preservedSlotKeys(for: SettingsStore.salvageKey)
        XCTAssertEqual(defaults.data(forKey: slots[0]), first, "never overwritten")
        XCTAssertEqual(defaults.data(forKey: slots[1]), second)
        XCTAssertNil(defaults.data(forKey: slots[2]), "no duplicate of either")
    }

    func testSalvageSlotsAreBoundedAndKeepTheEarliest() {
        let slots = SettingsStore.preservedSlotKeys(for: SettingsStore.salvageKey)
        XCTAssertEqual(slots.count, SettingsStore.preservedSlotLimit)
        for index in 0..<(slots.count + 2) {
            defaults.set(Data("corrupt \(index)".utf8), forKey: SettingsStore.storageKey)
            XCTAssertEqual(store().settings, AppSettings(), "still loads defaults when full")
        }
        for (index, slot) in slots.enumerated() {
            XCTAssertEqual(defaults.data(forKey: slot), Data("corrupt \(index)".utf8))
        }
        XCTAssertNil(defaults.data(forKey: "\(SettingsStore.salvageKey).\(slots.count + 1)"),
                     "nothing beyond the bound")
    }
}
