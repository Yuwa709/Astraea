// Adapted from Glance (github.com/jonnyoo/glance), MIT, (c) 2026 Jonathan Zhou.
// See THIRD-PARTY-LICENSES.md.

import Foundation
import CryptoKit
import Observation
import os

enum FaceEnrollmentStoreError: LocalizedError {
    case notReady
    case emptyName
    case nameTaken(String)

    var errorDescription: String? {
        switch self {
        case .notReady: "Your face data isn't unlocked, so nothing was saved."
        case .emptyName: "Enter a name."
        case .nameTaken(let name): "A face named \"\(name)\" is already enrolled."
        }
    }
}

/// Enrolled faces, encrypted at rest with AES-GCM in
/// `~/Library/Application Support/Astraea/FaceUnlock/face-identities.enc`.
/// There is no plaintext fallback. The file is owner-only from creation and
/// replaced atomically (`FaceFileWriter`).
///
/// The key comes from `FaceUnlockSession`, which owns it. Nothing here
/// touches the Keychain at launch: the key is read when the session is
/// unlocked, and created on the first save, so a user who never enrols
/// never gets a keychain item. When the session locks, the decrypted
/// identities and the key reference are dropped and the store is `.locked`
/// again.
@Observable
@MainActor
final class FaceEnrollmentStore {

    enum State: Equatable {
        /// Session locked, or the unlock was refused; `lastError` says why.
        case locked
        case unlocking
        case ready
        /// The file exists but cannot be opened. Unlocking again won't help;
        /// only deleting the data will.
        case unreadable(String)
    }

    @ObservationIgnored private static let logger = Logger(subsystem: "com.techie.Astraea", category: "FaceUnlock")

    static let unlockReason = "unlock your Face Unlock data"
    static let keyMissingMessage = "The key that encrypted your face data is missing from the keychain."

    private(set) var state: State = .locked
    private(set) var identities: [FaceIdentity] = []
    private(set) var lastError: String?

    @ObservationIgnored let session: FaceUnlockSession
    @ObservationIgnored let fileURL: URL
    @ObservationIgnored private var key: SymmetricKey?

    init(session: FaceUnlockSession) {
        self.session = session
        self.fileURL = session.faceIdentitiesURL
        session.addLockHandler { [weak self] in self?.sessionDidLock() }
    }

    var fileExists: Bool { FileManager.default.fileExists(atPath: fileURL.path) }

    /// Unlocks the session if it is locked (the owner check prompts), then
    /// decrypts the faces. With the session already unlocked, no prompt.
    ///
    /// With `prompting: false` (lock-screen Face Unlock) it never prompts and
    /// never reads the keychain: unless the owner is verified and the key is
    /// already in memory when it runs, it does nothing.
    func unlock(prompting: Bool = true) async {
        guard state == .locked else { return }
        if !prompting {
            guard session.isOwnerVerified, session.hasKeyInMemory else {
                Self.logger.notice("Face store load skipped: it would need the owner check")
                return
            }
        }
        state = .unlocking
        lastError = nil

        if !session.isOwnerVerified {
            await session.unlock(reason: Self.unlockReason)
        }
        // Locked again while waiting: `sessionDidLock` has already reset.
        guard state == .unlocking else { return }

        switch session.state {
        case .locked, .unlocking:
            state = .locked
            lastError = session.lastError
            return
        case .keyMissing:
            if fileExists {
                state = .unreadable(Self.keyMissingMessage)
                Self.logger.error("Face store unreadable: key missing")
            } else {
                identities = []
                state = .ready
                Self.logger.notice("Face store ready: nothing enrolled")
            }
            return
        case .unlocked:
            break
        }

        // Nothing on disk: nothing to decrypt.
        guard fileExists else {
            identities = []
            state = .ready
            Self.logger.notice("Face store ready: nothing enrolled")
            return
        }

        let key: SymmetricKey?
        do {
            key = try await session.key(creatingIfNeeded: false)
        } catch FaceUnlockSessionError.keyUnavailable {
            key = nil
        } catch {
            guard state == .unlocking else { return }
            state = .locked
            lastError = error.localizedDescription
            Self.logger.error("Face store key read failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard state == .unlocking else { return }
        guard let key else {
            state = .unreadable(Self.keyMissingMessage)
            Self.logger.error("Face store unreadable: key missing")
            return
        }
        do {
            let plaintext = try session.openSealed(Data(contentsOf: fileURL), as: .faces)
            identities = try JSONDecoder().decode([FaceIdentity].self, from: plaintext)
            self.key = key
            state = .ready
            Self.logger.notice("Face store unlocked: \(self.identities.count, privacy: .public) identities")
            logStaleIdentities()
        } catch {
            state = .unreadable("Your face data could not be decrypted.")
            Self.logger.error("Face store decrypt failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Faces enrolled with an older face model. Kept on disk and listed,
    /// never matched or compared, until recaptured or deleted.
    var staleIdentities: [FaceIdentity] { identities.filter(\.isStale) }

    private func logStaleIdentities() {
        let stale = staleIdentities
        guard !stale.isEmpty else { return }
        let models = Set(stale.map { "\($0.modelIdentifier) (\($0.embeddingDimension)-d)" }).sorted().joined(separator: ", ")
        Self.logger.notice("Stale face enrolments: \(stale.count, privacy: .public) of \(self.identities.count, privacy: .public) made with \(models, privacy: .public), current model \(FaceEmbedder.modelIdentifier, privacy: .public) (\(FaceEmbedder.embeddingDimension, privacy: .public)-d); kept, excluded from matching, recapture needed")
    }

    /// The session locked: forget everything decrypted.
    private func sessionDidLock() {
        guard state != .locked || !identities.isEmpty || key != nil else { return }
        identities = []
        key = nil
        lastError = nil
        state = .locked
        Self.logger.notice("Face store locked: identities dropped")
    }

    /// Case- and diacritic-insensitive: "alex", "Alex" and "Álex" are one
    /// person to the user.
    func nameIsTaken(_ name: String, excluding id: UUID? = nil) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return identities.contains {
            $0.id != id && $0.name.compare(trimmed, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
    }

    /// One write for a whole guided enrolment. `existingID` replaces that
    /// identity's samples wholesale: a recapture is a redo, not an append.
    @discardableResult
    func commitEnrollment(replacing existingID: UUID? = nil, name: String, samples: [FaceSample]) async throws -> FaceIdentity {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw FaceEnrollmentStoreError.emptyName }
        guard state == .ready else { throw FaceEnrollmentStoreError.notReady }
        guard !nameIsTaken(trimmed, excluding: existingID) else { throw FaceEnrollmentStoreError.nameTaken(trimmed) }

        // Asked every time, not only when this store has no key: the session
        // forgets its key once no encrypted data is left. With nothing on
        // disk it mints a fresh one, never trusting an item already in the
        // keychain; it refuses to create one while other encrypted data is
        // on disk.
        let hadKey = key != nil
        let sessionKey = try await session.key(creatingIfNeeded: true)
        guard state == .ready, let sessionKey else { throw FaceEnrollmentStoreError.notReady }
        key = sessionKey
        if !hadKey { Self.logger.notice("Face store key ready") }

        var updated = identities
        let committed: FaceIdentity
        if let existingID, let index = updated.firstIndex(where: { $0.id == existingID }) {
            updated[index].name = trimmed
            updated[index].samples = samples
            updated[index].modelIdentifier = FaceEmbedder.modelIdentifier
            updated[index].embeddingDimension = FaceEmbedder.embeddingDimension
            committed = updated[index]
        } else {
            committed = FaceIdentity(name: trimmed, samples: samples)
            updated.append(committed)
        }
        // Assigned only after the write lands, so a failed save never shows.
        try write(updated)
        identities = updated
        session.recordActivity()
        Self.logger.notice("Face enrolled: \(samples.count, privacy: .public) samples")
        return committed
    }

    /// Reverts the in-memory flag if the write fails.
    func setEnabled(_ isEnabled: Bool, for id: UUID) throws {
        guard let index = identities.firstIndex(where: { $0.id == id }),
              identities[index].isEnabled != isEnabled else { return }
        var updated = identities
        updated[index].isEnabled = isEnabled
        // Disabling moves the file's epoch on, so a saved copy with the
        // face still enabled no longer opens.
        try write(updated, bumpingEpoch: !isEnabled)
        identities = updated
        session.recordActivity()
        Self.logger.notice("Face identity \(isEnabled ? "enabled" : "disabled", privacy: .public)")
    }

    func delete(_ id: UUID) throws {
        let updated = identities.filter { $0.id != id }
        // A saved copy with the face still in it no longer opens.
        try write(updated, bumpingEpoch: true)
        identities = updated
        session.recordActivity()
        Self.logger.notice("Face identity deleted")
    }

    /// Removes the file outright: the way out of `.unreadable`, and of a key
    /// that cannot be read. Needs no key; the caller runs the owner check
    /// first (`FaceUnlockSession.verifyOwner(reason:)`). The faces' epoch
    /// moves on, so a saved copy of the file no longer opens; with the
    /// password gone too, the session deletes the key, and the next
    /// enrolment mints a fresh one.
    func deleteAll() {
        do {
            if fileExists { try FileManager.default.removeItem(at: fileURL) }
        } catch {
            lastError = error.localizedDescription
            Self.logger.error("Face data delete failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        identities = []
        key = nil
        lastError = nil
        session.noteFileDeleted(.faces)
        session.recordActivity()
        state = session.isOwnerVerified ? .ready : .locked
        Self.logger.notice("All face data deleted")
    }

    /// Refuses without a key or outside `.ready`, so an unreadable file is
    /// never overwritten by an empty list.
    private func write(_ identities: [FaceIdentity], bumpingEpoch: Bool = false) throws {
        guard state == .ready, key != nil else { throw FaceEnrollmentStoreError.notReady }
        do {
            try session.writeSealed(JSONEncoder().encode(identities), to: .faces, bumpingEpoch: bumpingEpoch)
        } catch FaceUnlockSessionError.locked {
            throw FaceEnrollmentStoreError.notReady
        }
    }
}
