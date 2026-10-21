import Foundation
import os

/// One-time carry-over of a PopNotch install's data into Astraea.
///
/// The rebrand changed the bundle ID, so macOS gives the app a new
/// preferences domain, and the data folders were renamed. Without this an
/// upgrading user would open Astraea to default settings and no enrolled
/// faces, which CLAUDE.md forbids ("never wipe user settings silently").
///
/// Nothing is overwritten: a value or folder entry that already exists on the
/// Astraea side wins, and the PopNotch copy stays where it is. The Face
/// Unlock keychain service name is unchanged on purpose, so the key that
/// sealed the moved files is still found.
enum LegacyDataMigration {

    private static let logger = Logger(subsystem: "com.techie.Astraea", category: "Migration")

    static let oldBundleIdentifier = "com.techie.PopNotch"
    /// Only the app's own settings keys are copied. The rest of the old
    /// domain is system or framework state (window frames, Sparkle timers)
    /// that should start fresh.
    static let settingsKeyPrefix = "com.techie.PopNotch.settings"
    /// Set once the migration has run, whether or not there was anything to
    /// carry over, so it never runs twice.
    static let doneKey = "com.techie.Astraea.legacyMigrationDone"

    struct Report: Equatable {
        var settingsKeysCopied: [String] = []
        var itemsMoved: [String] = []
        /// Entries left in the old folder because the same name already
        /// exists in the new one.
        var itemsSkipped: [String] = []
        var alreadyDone = false
    }

    @discardableResult
    static func run(
        defaults: UserDefaults = .standard,
        oldDomain: [String: Any]? = UserDefaults.standard.persistentDomain(forName: oldBundleIdentifier),
        applicationSupport: URL? = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first,
        fileManager: FileManager = .default
    ) -> Report {
        var report = Report()
        if defaults.bool(forKey: doneKey) {
            report.alreadyDone = true
            return report
        }

        report.settingsKeysCopied = copySettings(from: oldDomain, to: defaults)
        if let applicationSupport {
            moveFolders(in: applicationSupport, fileManager: fileManager, into: &report)
        }

        defaults.set(true, forKey: doneKey)
        logger.notice("Legacy migration done: \(report.settingsKeysCopied.count, privacy: .public) settings keys copied, \(report.itemsMoved.count, privacy: .public) folder entries moved, \(report.itemsSkipped.count, privacy: .public) skipped")
        return report
    }

    // MARK: - Settings

    private static func copySettings(from oldDomain: [String: Any]?, to defaults: UserDefaults) -> [String] {
        guard let oldDomain else { return [] }
        var copied: [String] = []
        for (key, value) in oldDomain.sorted(by: { $0.key < $1.key })
        where key.hasPrefix(settingsKeyPrefix) {
            guard defaults.object(forKey: key) == nil else { continue }
            defaults.set(value, forKey: key)
            copied.append(key)
        }
        return copied
    }

    // MARK: - Folders

    /// Merges `PopNotch/*` into `Astraea/*` one entry at a time, moving (not
    /// copying) so no second copy of the encrypted face data is left behind.
    /// The old folder is removed only if that leaves it empty.
    private static func moveFolders(in base: URL, fileManager: FileManager, into report: inout Report) {
        let old = base.appendingPathComponent("PopNotch", isDirectory: true)
        let new = base.appendingPathComponent("Astraea", isDirectory: true)
        // A folder that cannot be listed is left alone: only one confirmed
        // empty is ever removed.
        guard let entries = try? fileManager.contentsOfDirectory(atPath: old.path) else { return }
        guard !entries.isEmpty else {
            try? fileManager.removeItem(at: old)
            return
        }
        do {
            try fileManager.createDirectory(at: new, withIntermediateDirectories: true)
        } catch {
            logger.error("Could not create \(new.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }
        for name in entries.sorted() {
            let source = old.appendingPathComponent(name)
            let target = new.appendingPathComponent(name)
            if fileManager.fileExists(atPath: target.path) {
                report.itemsSkipped.append(name)
                continue
            }
            do {
                try fileManager.moveItem(at: source, to: target)
                report.itemsMoved.append(name)
            } catch {
                report.itemsSkipped.append(name)
                logger.error("Could not move \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        if (try? fileManager.contentsOfDirectory(atPath: old.path))?.isEmpty == true {
            try? fileManager.removeItem(at: old)
        }
    }
}
