// Adapted from Glance (github.com/jonnyoo/glance), MIT, (c) 2026 Jonathan Zhou.
// See THIRD-PARTY-LICENSES.md.

import Foundation
import CryptoKit
import LocalAuthentication
import Observation
import os

// MARK: - Owner check

/// Asks the person at the Mac to prove they are its owner.
///
/// **A policy gate, not cryptographic protection.** Glance's session key is a
/// Touch ID-gated keychain item, so the key itself cannot be read without
/// the user. PopNotch's ad-hoc releases cannot create such an item
/// (`FaceKeyVault`), so the key sits in the login keychain, readable by this
/// process without any prompt, and this check is PopNotch choosing not to
/// read it until the owner has answered. It keeps a passer-by at an
/// unlocked Mac from using PopNotch's own UI to reach the data; it does not
/// stop code running as the user from reading the keychain item directly.
nonisolated protocol OwnerAuthenticator: Sendable {
    /// Returns once the owner is verified. Throws on failure, and on a
    /// cancelled prompt. Cancelling the calling task must take down a prompt
    /// that is still showing: the session does so when it locks.
    func authenticate(reason: String) async throws
}

/// `.deviceOwnerAuthentication`: Touch ID where available, else the Mac
/// password.
///
/// Uses the async `evaluatePolicy` and never bridges it synchronously:
/// Glance found that waiting on a semaphore for its callback deadlocks the
/// cooperative thread pool.
///
/// Task cancellation invalidates the context, which dismisses the prompt
/// and makes `evaluatePolicy` throw.
nonisolated struct LocalAuthenticationOwnerAuthenticator: OwnerAuthenticator {
    func authenticate(reason: String) async throws {
        let context = LAContext()
        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
            throw policyError ?? LAError(.authenticationFailed)
        }
        try await withTaskCancellationHandler {
            // Throws `LAError.userCancel` and friends on a cancelled prompt.
            guard try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) else {
                throw LAError(.authenticationFailed)
            }
        } onCancel: {
            context.invalidate()
        }
    }
}

// MARK: - Session

enum FaceUnlockSessionError: LocalizedError, Equatable {
    case locked
    /// Encrypted data exists, but the key that sealed it is gone.
    case keyUnavailable

    var errorDescription: String? {
        switch self {
        case .locked:
            "Face Unlock is locked. Unlock it to continue."
        case .keyUnavailable:
            FaceUnlockSession.keyMissingMessage
        }
    }
}

/// The single owner of the in-memory key for everything Face Unlock keeps
/// encrypted: the enrolled faces and the stored password.
///
/// `unlock(reason:)` runs the owner check first and only then reads the key
/// (`OwnerAuthenticator` explains what that check is and is not). Changes
/// that weaken Face Unlock ask again with `reauthenticate(reason:)`, which
/// an unlocked session never answers on the owner's behalf.
///
/// Stays unlocked across restarts (unlike Glance, which locks at every
/// launch): while unlocked with a key and data on disk, it keeps a signed
/// `FaceSessionRecord` of its last use, and `restorePersistedUnlock` picks
/// the session up from it at the next launch, without the owner check,
/// until the auto-lock interval runs out. `lock()` deletes the record and
/// moves the session epoch on, so a saved copy of it no longer verifies.
///
/// Key rules:
/// - A key read that fails is never "no key": the session stays locked.
/// - The key is created lazily on the first write. With nothing encrypted
///   on disk, an item already in the keychain is never trusted: it is
///   deleted and a fresh key minted, and if it cannot be deleted nothing is
///   saved. Once no encrypted data is left, the item is deleted.
/// - A key is never created while encrypted data is on disk: data with no
///   key reports `.keyMissing` until the user deletes it.
/// - With no encrypted files on disk, unlocking touches no keychain item.
/// - The files are sealed under per-file subkeys with per-file epochs
///   (`FaceCrypto`); files in the legacy layout are re-sealed the first
///   time the key is read.
@Observable
@MainActor
final class FaceUnlockSession {

    enum State: Equatable {
        case locked
        case unlocking
        case unlocked
        /// The owner is verified, but encrypted data is on disk and the key
        /// that sealed it is missing from the keychain. Nothing can be
        /// decrypted; deleting the data is the only way on, and no new key
        /// is minted over it.
        case keyMissing
    }

    @ObservationIgnored private static let logger = Logger(subsystem: "com.techie.PopNotch", category: "FaceUnlock")

    /// `nonisolated` because it is a default argument of `init`.
    nonisolated static let defaultDirectory = URL.applicationSupportDirectory
        .appending(path: "PopNotch/FaceUnlock")
    nonisolated static let faceIdentitiesFileName = FaceDataFile.faces.fileName
    nonisolated static let passwordFileName = FaceDataFile.password.fileName

    nonisolated static let keyMissingMessage = "The key that encrypted your Face Unlock data is missing from the keychain. Nothing has been deleted. Delete the face data and the stored password to start fresh."

    private(set) var state: State = .locked
    /// Why the last unlock failed, or why the data cannot be read.
    private(set) var lastError: String?
    /// The unlock or the last recorded use. nil whenever the owner is not
    /// verified: a locked session has no idle time to age.
    private(set) var lastActivityAt: Date?
    /// The owner was verified, but reading the key threw (a refused or
    /// corrupt keychain item), so the session stayed locked. The encrypted
    /// data cannot be decrypted; deleting it, after an owner check, is the
    /// way on. Cleared by the next unlock and by `lock()`.
    private(set) var keyReadFailed = false

    @ObservationIgnored let directory: URL
    @ObservationIgnored let now: () -> Date
    @ObservationIgnored private let vault: any FaceKeyVault
    @ObservationIgnored private let authenticator: any OwnerAuthenticator
    /// The key and its epochs. Dropped on lock; `SymmetricKey` zeroes its
    /// storage when released.
    @ObservationIgnored private var material: FaceKeyMaterial?
    /// Bumped on every lock, so work that was in flight when the session
    /// locked cannot land afterwards.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var unlockTask: Task<Bool, Never>?
    @ObservationIgnored private var ownerCheck: Task<Void, Error>?
    @ObservationIgnored private var reauthCheck: Task<Void, Error>?
    @ObservationIgnored private var keyLoad: Task<FaceKeyMaterial?, Error>?
    @ObservationIgnored private var lockHandlers: [() -> Void] = []
    /// The activity time last written to the record; nil when none is on
    /// disk from this run.
    @ObservationIgnored private var persistedActivityAt: Date?

    /// Activity is written to the record at most this often: the auto-lock
    /// counts in days, so a restart may at worst lock this much early.
    static let persistInterval: TimeInterval = 60
    /// A record dated further ahead than this is not trusted.
    static let clockSkewAllowance: TimeInterval = 300

    /// How `restorePersistedUnlock` ended.
    enum RestoreOutcome: Equatable {
        case restored
        /// No record, or no encrypted data for it to unlock.
        case noRecord
        /// Past the auto-lock deadline: deleted.
        case expired
        /// Corrupt, from the future, not signed by this key, or older than
        /// the last lock: deleted.
        case invalid
        /// The key could not be read, or is gone.
        case keyUnavailable
        /// The session was no longer locked, or locked again, by the time
        /// the key arrived.
        case superseded
    }

    init(vault: any FaceKeyVault = LoginKeychainKeyVault(),
         authenticator: any OwnerAuthenticator = LocalAuthenticationOwnerAuthenticator(),
         directory: URL = FaceUnlockSession.defaultDirectory,
         now: @escaping () -> Date = Date.init) {
        self.vault = vault
        self.authenticator = authenticator
        self.directory = directory
        self.now = now
    }

    var faceIdentitiesURL: URL { url(of: .faces) }
    var passwordURL: URL { url(of: .password) }
    var sessionRecordURL: URL { directory.appending(path: FaceSessionRecord.fileName) }

    func url(of file: FaceDataFile) -> URL { directory.appending(path: file.fileName) }

    /// True once `unlock(reason:)` has verified the owner and the key, if
    /// any is needed, is in hand.
    var isUnlocked: Bool { state == .unlocked }

    /// The owner check has passed, whether or not the key was found.
    var isOwnerVerified: Bool { state == .unlocked || state == .keyMissing }

    /// The key is already in memory, so reading the stores needs no
    /// keychain access. Lock-screen Face Unlock reads the password only when
    /// this is true: nothing may prompt at the lock screen.
    var hasKeyInMemory: Bool { material != nil }

    /// The key, only when the session is unlocked and already holds it.
    /// Synchronous and never touches the keychain; nil otherwise.
    var cachedKey: SymmetricKey? { state == .unlocked ? material?.key : nil }

    /// Answerable without the key, so it still works when the key is gone.
    var hasEncryptedData: Bool {
        FileManager.default.fileExists(atPath: faceIdentitiesURL.path)
            || FileManager.default.fileExists(atPath: passwordURL.path)
    }

    /// Calls `handler` synchronously every time the session locks, so
    /// anything holding decrypted data can drop it before the next run loop
    /// turn. Capture weakly; handlers live as long as the session.
    func addLockHandler(_ handler: @escaping () -> Void) {
        lockHandlers.append(handler)
    }

    // MARK: - Unlock and lock

    /// Owner check, then the key. Concurrent callers share one prompt.
    /// Returns whether the owner is now verified (`.unlocked` or
    /// `.keyMissing`).
    @discardableResult
    func unlock(reason: String) async -> Bool {
        if let unlockTask { return await unlockTask.value }
        guard state == .locked else { return isOwnerVerified }
        // Captured before the task exists, so a `lock()` that lands before
        // the task first runs still voids it.
        let generation = self.generation
        state = .unlocking
        lastError = nil
        keyReadFailed = false
        Self.logger.notice("Session unlocking")
        let task = Task { await performUnlock(reason: reason, generation: generation) }
        unlockTask = task
        let verified = await task.value
        if unlockTask == task { unlockTask = nil }
        return verified
    }

    private func performUnlock(reason: String, generation: Int) async -> Bool {
        guard generation == self.generation else { return false }
        do {
            try await authenticator.authenticate(reason: reason)
        } catch {
            guard generation == self.generation else { return false }
            state = .locked
            lastError = error.localizedDescription
            Self.logger.notice("Session unlock refused: \(error.localizedDescription, privacy: .public)")
            return false
        }
        guard generation == self.generation else { return false }

        // Nothing on disk: nothing to decrypt, and no reason to touch the
        // keychain until there is something to save.
        guard hasEncryptedData else {
            becomeVerified(.unlocked)
            Self.logger.notice("Session unlocked: no encrypted data yet")
            return true
        }

        let result = await loadMaterial()
        guard generation == self.generation else { return false }
        switch result {
        case .failure(let error):
            state = .locked
            lastError = error.localizedDescription
            keyReadFailed = true
            Self.logger.error("Session key read failed: \(error.localizedDescription, privacy: .public)")
            return false
        case .success(nil):
            becomeVerified(.keyMissing)
            lastError = Self.keyMissingMessage
            Self.logger.error("Session unlocked with key missing: encrypted data has no key")
            return true
        case .success(let material?):
            self.material = material
            becomeVerified(.unlocked)
            Self.logger.notice("Session unlocked")
            return true
        }
    }

    /// Reads the key off the main actor, re-sealing legacy files on the way.
    private func loadMaterial() async -> Result<FaceKeyMaterial?, Error> {
        let vault = self.vault, directory = self.directory
        return await Task.detached { Result { try FaceKeyLoader.load(from: vault, directory: directory) } }.value
    }

    private func becomeVerified(_ newState: State) {
        state = newState
        lastActivityAt = now()
        persistActivity(force: true)
    }

    /// The owner check alone, for actions that need the owner but not the
    /// key: removing the password and deleting the face data, which must
    /// also work when the key is missing or unreadable. Changes no state.
    /// A verified session answers at once; otherwise the authenticator
    /// prompts, and concurrent callers share one prompt. false when the
    /// check fails, is cancelled, or the session locks while it is up.
    ///
    /// Only for actions that make Face Unlock safer or remove data. Anything
    /// that weakens it uses `reauthenticate(reason:)`.
    func verifyOwner(reason: String) async -> Bool {
        if isOwnerVerified { return true }
        let generation = self.generation
        let check = ownerCheck ?? Task { [authenticator] in
            try await authenticator.authenticate(reason: reason)
        }
        ownerCheck = check
        let result = await check.result
        if ownerCheck == check { ownerCheck = nil }
        guard generation == self.generation else { return false }
        switch result {
        case .success:
            Self.logger.notice("Owner verified without unlocking")
            return true
        case .failure(let error):
            Self.logger.notice("Owner check refused: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// A fresh owner check, every time, whatever the session's state: an
    /// unlocked session (perhaps restored at launch, unlocked weeks ago)
    /// never answers for the owner here. For changes that weaken Face
    /// Unlock: adding or recapturing a face, enabling one, turning on
    /// lock-screen unlock, saving the password, and loosening the match
    /// threshold, liveness or auto-lock. Changes no state. Concurrent
    /// callers share one prompt. false when the check fails, is cancelled,
    /// or the session locks while it is up.
    func reauthenticate(reason: String) async -> Bool {
        let generation = self.generation
        let check = reauthCheck ?? Task { [authenticator] in
            try await authenticator.authenticate(reason: reason)
        }
        reauthCheck = check
        let result = await check.result
        if reauthCheck == check { reauthCheck = nil }
        guard generation == self.generation else {
            Self.logger.notice("Owner re-check void: the session locked while it was up")
            return false
        }
        switch result {
        case .success:
            Self.logger.notice("Owner re-verified")
            return true
        case .failure(let error):
            Self.logger.notice("Owner re-check refused: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Drops the key and everything decrypted with it, takes down any
    /// owner-check prompt still showing, deletes the record, and moves the
    /// session epoch on, so neither this run nor the next is unlocked
    /// without the owner check, even from a saved copy of the record.
    func lock() {
        generation += 1
        let wasLocked = state == .locked
        let hadRecord = removePersistedRecord(reason: "session locked")
        if !wasLocked || hadRecord { bumpSessionEpoch() }
        material = nil
        lastActivityAt = nil
        state = .locked
        lastError = nil
        keyReadFailed = false
        unlockTask?.cancel()
        unlockTask = nil
        ownerCheck?.cancel()
        ownerCheck = nil
        reauthCheck?.cancel()
        reauthCheck = nil
        keyLoad = nil
        guard !wasLocked else { return }
        Self.logger.notice("Session locked")
        lockHandlers.forEach { $0() }
    }

    /// Takes down the owner-check prompt `unlock(reason:)` is showing,
    /// without locking: the record a later launch restores from stays, and
    /// no epoch moves. That unlock returns false. Does nothing unless the
    /// session is unlocking. For the launch prompt, when the screen locks
    /// under it.
    func withdrawUnlockPrompt() {
        guard state == .unlocking else { return }
        generation += 1
        unlockTask?.cancel()
        unlockTask = nil
        state = .locked
        lastError = nil
        Self.logger.notice("Session unlock prompt withdrawn; the record is kept")
    }

    /// Restarts the idle countdown. Ignored while locked.
    func recordActivity() {
        guard isOwnerVerified else { return }
        lastActivityAt = now()
        persistActivity(force: false)
    }

    /// After a store deletes its file: older copies of it stop opening
    /// (its epoch moves on), and once no encrypted data is left the key is
    /// forgotten and deleted from the keychain (`noteEncryptedDataRemoved`).
    func noteFileDeleted(_ file: FaceDataFile) {
        if hasEncryptedData { bumpEpoch(of: file) }
        noteEncryptedDataRemoved()
    }

    /// After a store deletes its file: once no encrypted data is left, a
    /// missing key no longer blocks anything, the key is deleted (the next
    /// write mints a fresh one), and there is nothing for a relaunch to
    /// restore.
    func noteEncryptedDataRemoved() {
        guard !hasEncryptedData else { return }
        removePersistedRecord(reason: "no encrypted data left")
        forgetKey()
        if state == .keyMissing {
            state = .unlocked
            lastError = nil
            Self.logger.notice("Session unlocked: data with the missing key was deleted")
        } else if keyReadFailed {
            // Nothing left that needs the unreadable key.
            keyReadFailed = false
            lastError = nil
            Self.logger.notice("Data with the unreadable key was deleted")
        }
    }

    // MARK: - Sealed files

    /// Opens one of the encrypted files with the key in memory: the version
    /// 2 layout at the file's current epoch or later, or, while the key
    /// still accepts it, the legacy layout. Never touches the keychain, so
    /// the lock screen may call it. Throws `.locked` without the key.
    func openSealed(_ data: Data, as file: FaceDataFile) throws -> Data {
        guard isOwnerVerified, let material else { throw FaceUnlockSessionError.locked }
        return try FaceCrypto.openFile(data, as: file, master: material.key, minimumEpoch: material.epochs[file],
                                       acceptsLegacy: material.acceptsLegacy)
    }

    /// Seals `plaintext` for `file` in the version 2 layout and replaces the
    /// file (`FaceFileWriter`). With `bumpingEpoch`, for a write that
    /// removes or disables something, the file's epoch moves on first, so
    /// the copy it replaces stops opening. Throws `.locked` without the key.
    func writeSealed(_ plaintext: Data, to file: FaceDataFile, bumpingEpoch: Bool) throws {
        guard isOwnerVerified, var material else { throw FaceUnlockSessionError.locked }
        if bumpingEpoch { material.epochs[file] &+= 1 }
        let sealed = try FaceCrypto.sealFile(plaintext, as: file, epoch: material.epochs[file], master: material.key)
        try FaceFileWriter.replace(url(of: file), with: sealed)
        // Kept even if saving the epoch fails: the file carries it now, and
        // a file at or above the keychain's epoch still opens.
        self.material = material
        if bumpingEpoch { saveEpochs(material.epochs, change: "\(file.rawValue) epoch moved on") }
    }

    // MARK: - Epochs

    private func bumpEpoch(of file: FaceDataFile) {
        guard var epochs = currentEpochs() else { return }
        epochs[file] &+= 1
        material?.epochs = epochs
        saveEpochs(epochs, change: "\(file.rawValue) epoch moved on after a delete")
    }

    private func bumpSessionEpoch() {
        guard var epochs = currentEpochs() else { return }
        epochs.session &+= 1
        material?.epochs = epochs
        saveEpochs(epochs, change: "session epoch moved on")
    }

    /// The epochs in memory, else the item's. nil when there is no item, or
    /// it predates epochs (its first read re-seals and adds them).
    private func currentEpochs() -> FaceKeyEpochs? {
        if let material { return material.epochs }
        do {
            return try vault.readEpochs()
        } catch {
            Self.logger.error("Epochs not read: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func saveEpochs(_ epochs: FaceKeyEpochs, change: String) {
        do {
            try vault.writeEpochs(epochs)
            Self.logger.notice("Keychain: \(change, privacy: .public)")
        } catch {
            Self.logger.error("Keychain: \(change, privacy: .public) not saved: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func forgetKey() {
        material = nil
        do {
            try vault.deleteKey()
            Self.logger.notice("Session key deleted: nothing it sealed is left")
        } catch {
            // The next write refuses to reuse it and says so (`FaceKeyLoader.mint`).
            Self.logger.error("Session key not deleted: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Across restarts

    /// Picks up the session the last run left unlocked, without the owner
    /// check: the record must exist, be signed by the key at the current
    /// session epoch, and be within `interval` of its last use. Reads the
    /// key from the keychain, which an ad-hoc-signed update may answer with
    /// a one-time prompt, so the caller runs this only while the screen is
    /// positively unlocked (`FaceUnlockLoginPrompt`), never at the lock
    /// screen or under tests.
    ///
    /// Restores the record's activity time, not now, so the auto-lock
    /// deadline carries over. A key that cannot be read leaves the record
    /// for a later launch; everything else that fails deletes it.
    func restorePersistedUnlock(interval: AutoLockInterval) async -> RestoreOutcome {
        guard state == .locked else { return .superseded }
        let record: FaceSessionRecord
        switch FaceSessionRecord.load(from: sessionRecordURL) {
        case .none:
            return .noRecord
        case .corrupt:
            return discardRecord(.invalid, reason: "unreadable")
        case .record(let loaded):
            record = loaded
        }
        guard record.unlocked, hasEncryptedData else { return discardRecord(.noRecord, reason: "nothing to unlock") }
        let now = now()
        guard record.lastActivityAt <= now.addingTimeInterval(Self.clockSkewAllowance) else {
            return discardRecord(.invalid, reason: "dated in the future")
        }
        guard !interval.shouldLock(lastActivityAt: record.lastActivityAt, now: now) else {
            return discardRecord(.expired, reason: "past the \(interval.rawValue)-day auto-lock")
        }

        let generation = self.generation
        let result = await loadMaterial()
        guard generation == self.generation, state == .locked else { return .superseded }
        switch result {
        case .failure(let error):
            Self.logger.error("Session not restored: key read failed: \(error.localizedDescription, privacy: .public)")
            return .keyUnavailable
        case .success(nil):
            return discardRecord(.keyUnavailable, reason: "the key is gone")
        case .success(let material?):
            guard record.isAuthentic(with: material.key, minimumEpoch: material.epochs.session,
                                     acceptsLegacy: material.acceptedLegacyAtLoad) else {
                return discardRecord(.invalid, reason: "not signed by this key at the current epoch")
            }
            self.material = material
            state = .unlocked
            lastError = nil
            keyReadFailed = false
            lastActivityAt = record.lastActivityAt
            let hours = Int(now.timeIntervalSince(record.lastActivityAt) / 3600)
            Self.logger.notice("Session restored from the last run (last used \(hours, privacy: .public) h ago)")
            if record.version == FaceSessionRecord.currentVersion {
                persistedActivityAt = record.lastActivityAt
            } else {
                // A version 1 record: re-signed in the current layout.
                persistedActivityAt = nil
                persistActivity(force: true)
            }
            return .restored
        }
    }

    private func discardRecord(_ outcome: RestoreOutcome, reason: String) -> RestoreOutcome {
        removePersistedRecord(reason: "not restored, \(reason)")
        return outcome
    }

    /// Writes the record while the session is unlocked with its key in hand
    /// and data on disk to restore. Throttled to `persistInterval` unless
    /// `force` (an unlock).
    private func persistActivity(force: Bool) {
        guard state == .unlocked, let material, let lastActivityAt else { return }
        if !force, let persistedActivityAt,
           lastActivityAt >= persistedActivityAt,
           lastActivityAt.timeIntervalSince(persistedActivityAt) < Self.persistInterval {
            return
        }
        guard hasEncryptedData else { return }
        do {
            try FaceSessionRecord(lastActivityAt: lastActivityAt, key: material.key, epoch: material.epochs.session)
                .write(to: sessionRecordURL)
            if persistedActivityAt == nil { Self.logger.notice("Session record written: stays unlocked across restarts") }
            persistedActivityAt = lastActivityAt
        } catch {
            Self.logger.error("Session record not written: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// true when a record was on disk. One that cannot be deleted is
    /// overwritten with a locked record, which never restores anything.
    @discardableResult
    private func removePersistedRecord(reason: String) -> Bool {
        persistedActivityAt = nil
        switch FaceSessionRecord.remove(at: sessionRecordURL) {
        case .absent:
            return false
        case .removed:
            Self.logger.notice("Session record deleted: \(reason, privacy: .public)")
            return true
        case .failed(let message):
            Self.logger.error("Session record not deleted (\(reason, privacy: .public)): \(message, privacy: .public)")
            do {
                try FaceSessionRecord.locked.write(to: sessionRecordURL)
                Self.logger.notice("Session record overwritten with a locked one")
            } catch {
                Self.logger.error("Session record not overwritten either: \(error.localizedDescription, privacy: .public)")
            }
            return true
        }
    }

    // MARK: - Key

    /// The session key, for the stores. Throws `.locked` unless the owner is
    /// verified.
    ///
    /// Read from the vault off the main actor if it is not cached yet. With
    /// encrypted data on disk: the item's key, or, when there is none, the
    /// session moves to `.keyMissing` and this throws `.keyUnavailable`.
    /// With nothing on disk: nil, or with `creatingIfNeeded` a freshly
    /// minted key, never one that was already in the keychain; if that one
    /// cannot be deleted, this throws and nothing is created.
    func key(creatingIfNeeded: Bool) async throws -> SymmetricKey? {
        // One vault round-trip at a time, so two first writes cannot both
        // find no key and both create one.
        var awaited: Task<FaceKeyMaterial?, Error>?
        while let pending = keyLoad, pending != awaited {
            awaited = pending
            _ = await pending.result
        }
        guard isOwnerVerified else { throw FaceUnlockSessionError.locked }
        if let material { return material.key }

        let generation = self.generation
        let dataOnDisk = hasEncryptedData
        guard dataOnDisk || creatingIfNeeded else { return nil }
        let vault = self.vault, directory = self.directory
        let task = Task.detached { () throws -> FaceKeyMaterial? in
            if dataOnDisk { return try FaceKeyLoader.load(from: vault, directory: directory) }
            return try FaceKeyLoader.mint(in: vault)
        }
        keyLoad = task
        defer { if keyLoad == task { keyLoad = nil } }

        let loaded: FaceKeyMaterial?
        do {
            loaded = try await task.value
        } catch {
            guard generation == self.generation else { throw FaceUnlockSessionError.locked }
            if !dataOnDisk {
                lastError = error.localizedDescription
                Self.logger.error("Session key not minted: \(error.localizedDescription, privacy: .public)")
            }
            throw error
        }
        guard generation == self.generation else { throw FaceUnlockSessionError.locked }
        if let loaded {
            material = loaded
            if state == .keyMissing { state = .unlocked }
            lastError = nil
            Self.logger.notice("Session key ready")
            return loaded.key
        }
        state = .keyMissing
        lastError = Self.keyMissingMessage
        Self.logger.error("Session key missing while encrypted data exists")
        throw FaceUnlockSessionError.keyUnavailable
    }
}
