import Foundation
import os

/// Removes the file the 24-hour charge history left behind.
///
/// The history (`SystemStatsHistory`, removed 2026-10-07) kept a ring of
/// per-minute samples in `~/Library/Application Support/PopNotch/
/// stats-history.json`. It was regenerable machine state, never something
/// the user configured, so deleting it loses nothing. Without this the file
/// would sit there for good, read by nothing.
///
/// Runs every launch and costs one `fileExists` once the file is gone. Only
/// that one file: the directory holds other features' data.
enum LegacyStatsHistory {

    private static let logger = Logger(subsystem: "com.techie.PopNotch", category: "StatsHistory")

    static func removeFile() {
        // `create: false`: no Application Support folder means no file.
        guard let base = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                      in: .userDomainMask,
                                                      appropriateFor: nil,
                                                      create: false) else { return }
        let file = base.appendingPathComponent("PopNotch", isDirectory: true)
            .appendingPathComponent("stats-history.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            try FileManager.default.removeItem(at: file)
            logger.notice("Removed the charge history file left by an older version")
        } catch {
            logger.error("Could not remove \(file.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
