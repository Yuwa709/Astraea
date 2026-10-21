import Foundation
import Observation
import os

/// Loads and saves `AppSettings` as JSON in UserDefaults.
///
/// Injectable `UserDefaults` so tests can run against a scratch suite instead
/// of the real domain.
@MainActor
@Observable
final class SettingsStore {

    @ObservationIgnored
    private static let logger = Logger(subsystem: "com.techie.Astraea", category: "Settings")

    @ObservationIgnored
    static let storageKey = "com.techie.PopNotch.settings"
    /// Where unreadable JSON is parked instead of being overwritten. The
    /// first slot; see `preserve(_:under:in:)` for the rest.
    @ObservationIgnored
    static let salvageKey = "com.techie.PopNotch.settings.unreadable"

    /// How many payloads one preservation key keeps: the base key plus
    /// numbered overflow slots. Bounded, so a payload that keeps changing
    /// can never grow the defaults domain without limit.
    @ObservationIgnored
    static let preservedSlotLimit = 5

    /// Where a payload written by a newer schema is kept, verbatim, before
    /// this build writes its own shape over it. One key per version.
    static func newerSchemaKey(_ version: Int) -> String {
        "com.techie.PopNotch.settings.schema\(version)"
    }

    /// Every slot `preserve` may use for `base`, in fill order: the base key
    /// itself, then `base.2`, `base.3`, up to `preservedSlotLimit` in all.
    static func preservedSlotKeys(for base: String) -> [String] {
        [base] + (2...max(2, preservedSlotLimit)).map { "\(base).\($0)" }
    }

    private(set) var settings: AppSettings

    @ObservationIgnored
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.settings = Self.load(from: defaults)
    }

    // MARK: - Reading

    private static func load(from defaults: UserDefaults) -> AppSettings {
        guard let data = defaults.data(forKey: storageKey) else {
            logger.notice("No stored settings; starting from defaults")
            return AppSettings()
        }

        do {
            let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
            if decoded.schemaVersion > AppSettings.currentSchemaVersion {
                // Written by a newer build, so it may hold keys this one
                // does not know, and the next save would drop them. Keep it
                // verbatim first, before anything here can write.
                let key = newerSchemaKey(decoded.schemaVersion)
                preserve(data, under: key, in: defaults)
                logger.notice("Settings are from newer schema \(decoded.schemaVersion) than this build's \(AppSettings.currentSchemaVersion); original preserved under \(key, privacy: .public)")
            }
            let migrated = AppSettings.migrate(decoded, from: decoded.schemaVersion)
            if migrated.schemaVersion != decoded.schemaVersion {
                logger.notice("Migrated settings from schema \(decoded.schemaVersion) to \(migrated.schemaVersion)")
            }
            return migrated
        } catch {
            // Never wipe user settings silently: park the unreadable payload
            // under a separate key so it can be inspected or recovered, and
            // say so loudly, rather than overwriting it with defaults.
            preserve(data, under: salvageKey, in: defaults)
            logger.error("Settings unreadable (\(error.localizedDescription, privacy: .public)); preserved under \(salvageKey, privacy: .public) and continuing with defaults")
            return AppSettings()
        }
    }

    /// Parks `data` in the first free slot for `base`, never over an earlier
    /// payload: each one may be the only copy of someone's settings.
    ///
    /// A payload already in a slot is not stored twice — the main key keeps
    /// its unreadable or newer payload until the next save, so every launch
    /// before then preserves the same bytes again. When every slot is full
    /// the earlier payloads win and this one is only logged, which keeps the
    /// domain bounded.
    private static func preserve(_ data: Data, under base: String, in defaults: UserDefaults) {
        let slots = preservedSlotKeys(for: base)
        if slots.contains(where: { defaults.data(forKey: $0) == data }) {
            return
        }
        guard let free = slots.first(where: { defaults.object(forKey: $0) == nil }) else {
            logger.error("All \(slots.count) slots under \(base, privacy: .public) are full; earlier payloads kept, this one not preserved")
            return
        }
        defaults.set(data, forKey: free)
        logger.notice("Preserved settings payload under \(free, privacy: .public)")
    }

    // MARK: - Writing

    /// Mutates settings and persists. The only write path, so every change
    /// is saved and logged in one place.
    func update(_ mutate: (inout AppSettings) -> Void) {
        var copy = settings
        mutate(&copy)
        guard copy != settings else { return }
        settings = copy
        persist()
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(settings)
            defaults.set(data, forKey: Self.storageKey)
        } catch {
            Self.logger.error("Could not encode settings: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Module enablement

    /// Whether a module should run, honouring its own default when the user
    /// has never expressed a preference.
    func isEnabled(_ id: ModuleID, default fallback: Bool) -> Bool {
        settings.moduleEnablement[id] ?? fallback
    }

    func setEnabled(_ enabled: Bool, for id: ModuleID) {
        update { $0.moduleEnablement[id] = enabled }
        Self.logger.notice("Module \(id, privacy: .public) \(enabled ? "enabled" : "disabled", privacy: .public)")
    }
}
