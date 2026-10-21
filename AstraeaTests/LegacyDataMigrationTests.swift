import XCTest
@testable import Astraea

/// The rebrand moved every user to a new bundle ID, so these pin the promise
/// that an upgrading install loses nothing: settings and Face Unlock files
/// arrive intact, and nothing already on the Astraea side is overwritten.
@MainActor
final class LegacyDataMigrationTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!
    private var base: URL!
    private let fm = FileManager.default

    override func setUp() {
        super.setUp()
        suiteName = "com.techie.Astraea.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        base = fm.temporaryDirectory.appending(path: "AstraeaMigrationTests-\(UUID().uuidString)")
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        try? fm.removeItem(at: base)
        defaults = nil
        super.tearDown()
    }

    private func migrate(oldDomain: [String: Any]? = nil) -> LegacyDataMigration.Report {
        LegacyDataMigration.run(defaults: defaults, oldDomain: oldDomain,
                                applicationSupport: base, fileManager: fm)
    }

    private func write(_ text: String, to relative: String) throws {
        let url = base.appending(path: relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(_ relative: String) -> String? {
        (try? Data(contentsOf: base.appending(path: relative))).flatMap { String(data: $0, encoding: .utf8) }
    }

    // MARK: - Settings

    func testSettingsCarryOverAndLoadWithNothingDropped() throws {
        var saved = AppSettings()
        saved.schemaVersion = AppSettings.currentSchemaVersion
        let json = try JSONEncoder().encode(saved)
        let report = migrate(oldDomain: [SettingsStore.storageKey: json])

        XCTAssertEqual(report.settingsKeysCopied, [SettingsStore.storageKey])
        XCTAssertEqual(SettingsStore(defaults: defaults).settings, saved)
    }

    func testOnlyTheAppsOwnSettingsKeysAreCopied() {
        let report = migrate(oldDomain: [
            SettingsStore.salvageKey: Data([1]),
            "NSWindow Frame AstraeaSettings": "0 0 100 100",
            "SULastCheckTime": Date(),
        ])
        XCTAssertEqual(report.settingsKeysCopied, [SettingsStore.salvageKey])
        XCTAssertNil(defaults.object(forKey: "SULastCheckTime"))
    }

    func testAnExistingAstraeaValueIsNeverOverwritten() {
        let mine = Data([9])
        defaults.set(mine, forKey: SettingsStore.storageKey)
        let report = migrate(oldDomain: [SettingsStore.storageKey: Data([1])])
        XCTAssertTrue(report.settingsKeysCopied.isEmpty)
        XCTAssertEqual(defaults.data(forKey: SettingsStore.storageKey), mine)
    }

    func testItRunsOnlyOnce() {
        _ = migrate(oldDomain: nil)
        let second = migrate(oldDomain: [SettingsStore.storageKey: Data([1])])
        XCTAssertTrue(second.alreadyDone)
        XCTAssertNil(defaults.object(forKey: SettingsStore.storageKey))
    }

    func testAFreshInstallHasNothingToDoAndStillCompletes() {
        let report = migrate(oldDomain: nil)
        XCTAssertTrue(report.settingsKeysCopied.isEmpty)
        XCTAssertTrue(report.itemsMoved.isEmpty)
        XCTAssertTrue(defaults.bool(forKey: LegacyDataMigration.doneKey))
    }

    // MARK: - Folders

    func testFaceUnlockFilesMoveIntactAndTheOldFolderGoes() throws {
        try write("sealed-faces", to: "PopNotch/FaceUnlock/face-identities.enc")
        try write("sealed-password", to: "PopNotch/FaceUnlock/password.enc")
        try write("cache", to: "PopNotch/Lyrics/abc.json")

        let report = migrate()

        XCTAssertEqual(report.itemsMoved, ["FaceUnlock", "Lyrics"])
        XCTAssertEqual(read("Astraea/FaceUnlock/face-identities.enc"), "sealed-faces")
        XCTAssertEqual(read("Astraea/FaceUnlock/password.enc"), "sealed-password")
        XCTAssertEqual(read("Astraea/Lyrics/abc.json"), "cache")
        XCTAssertFalse(fm.fileExists(atPath: base.appending(path: "PopNotch").path))
    }

    func testAnExistingDestinationEntryIsKeptAndTheOldOneStays() throws {
        try write("new-faces", to: "Astraea/FaceUnlock/face-identities.enc")
        try write("old-faces", to: "PopNotch/FaceUnlock/face-identities.enc")
        try write("cache", to: "PopNotch/Lyrics/abc.json")

        let report = migrate()

        XCTAssertEqual(report.itemsSkipped, ["FaceUnlock"])
        XCTAssertEqual(report.itemsMoved, ["Lyrics"])
        XCTAssertEqual(read("Astraea/FaceUnlock/face-identities.enc"), "new-faces")
        XCTAssertEqual(read("PopNotch/FaceUnlock/face-identities.enc"), "old-faces")
    }

    func testNoOldFolderIsAQuietNoOp() {
        let report = migrate()
        XCTAssertTrue(report.itemsMoved.isEmpty)
        XCTAssertFalse(fm.fileExists(atPath: base.appending(path: "Astraea").path))
    }
}
