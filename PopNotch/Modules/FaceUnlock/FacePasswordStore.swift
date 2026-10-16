// Adapted from Glance (github.com/jonnyoo/glance), MIT, (c) 2026 Jonathan Zhou.
// See THIRD-PARTY-LICENSES.md.

import Foundation
import Observation
import OpenDirectory
import os

// MARK: - Verification

/// Checks a password against the current macOS user. Blocking: callers run
/// it off the main actor.
nonisolated protocol PasswordVerifier: Sendable {
    /// true when `password` is the current user's, false when it is not.
    /// Throws only when the check itself could not be made.
    func verify(password: String) throws -> Bool
}

/// The local directory node's record for `NSUserName()`.
nonisolated struct OpenDirectoryPasswordVerifier: PasswordVerifier {
    func verify(password: String) throws -> Bool {
        let node = try ODNode(session: ODSession.default(), type: ODNodeType(kODNodeTypeLocalNodes))
        let record = try node.record(withRecordType: kODRecordTypeUsers, name: NSUserName(), attributes: nil)
        do {
            try record.verifyPassword(password)
            return true
        } catch let error as NSError where error.domain == ODFrameworkErrorDomain
                    && error.code == Int(kODErrorCredentialsInvalid.rawValue) {
            return false
        }
    }
}

// MARK: - Store

enum FacePasswordError: LocalizedError, Equatable {
    case emptyPassword
    case wrongPassword
    case verificationUnavailable(String)
    case sessionLocked
    case noStoredPassword
    case decryptionFailed

    var errorDescription: String? {
        switch self {
        case .emptyPassword:
            "Enter your Mac password."
        case .wrongPassword:
            "That is not the password for this Mac account, so it was not saved."
        case .verificationUnavailable:
            "macOS could not check this password, so it was not saved. Network and managed accounts may not be supported."
        case .sessionLocked:
            "Face Unlock is locked. Unlock it to continue."
        case .noStoredPassword:
            "No password is stored."
        case .decryptionFailed:
            "The stored password could not be decrypted. Delete it and enter it again."
        }
    }
}

/// The user's Mac login password, AES-GCM-encrypted with the session key, in
/// `password.enc` beside the face data, owner-only from creation and
/// replaced atomically (`FaceFileWriter`).
///
/// A file, not a second keychain item: on PopNotch's ad-hoc releases every
/// keychain item costs its own access prompt after each update.
///
/// The password and its length are never logged.
@Observable
@MainActor
final class FacePasswordStore {

    @ObservationIgnored private static let logger = Logger(subsystem: "com.techie.PopNotch", category: "FaceUnlock")

    @ObservationIgnored private let session: FaceUnlockSession
    @ObservationIgnored private let verifier: any PasswordVerifier
    @ObservationIgnored let fileURL: URL

    /// From the file's existence alone, so it needs no key and no unlock.
    private(set) var hasStoredPassword: Bool
    /// Bumped by every successful save, including one that replaces a
    /// password with the same value: lock-screen Face Unlock resumes typing
    /// after a re-save.
    private(set) var saveCount = 0

    init(session: FaceUnlockSession, verifier: any PasswordVerifier = OpenDirectoryPasswordVerifier()) {
        self.session = session
        self.verifier = verifier
        self.fileURL = session.passwordURL
        self.hasStoredPassword = FileManager.default.fileExists(atPath: session.passwordURL.path)
    }

    /// Re-reads `hasStoredPassword` from disk.
    func refresh() {
        hasStoredPassword = FileManager.default.fileExists(atPath: fileURL.path)
    }

    /// Verifies `password` against the current user, then encrypts and
    /// stores it, replacing any earlier one. A password macOS rejects is
    /// never stored. Needs an unlocked session.
    ///
    /// The caller's `String` cannot be zeroed; drop it promptly. The UTF-8
    /// copy made here is zeroed before returning.
    func save(_ password: String) async throws {
        guard !password.isEmpty else { throw FacePasswordError.emptyPassword }
        guard session.isOwnerVerified else { throw FacePasswordError.sessionLocked }

        let verifier = self.verifier
        let result = await Task.detached(priority: .userInitiated) {
            Result { try verifier.verify(password: password) }
        }.value
        switch result {
        case .failure(let error):
            Self.logger.error("Password check unavailable: \(error.localizedDescription, privacy: .public)")
            throw FacePasswordError.verificationUnavailable(error.localizedDescription)
        case .success(false):
            Self.logger.notice("Password rejected by macOS; not stored")
            throw FacePasswordError.wrongPassword
        case .success(true):
            break
        }

        guard try await session.key(creatingIfNeeded: true) != nil else {
            throw FacePasswordError.sessionLocked
        }
        var plaintext = Data(password.utf8)
        defer { plaintext.resetBytes(in: 0..<plaintext.count) }
        do {
            try session.writeSealed(plaintext, to: .password, bumpingEpoch: false)
        } catch FaceUnlockSessionError.locked {
            throw FacePasswordError.sessionLocked
        }
        hasStoredPassword = true
        saveCount += 1
        session.recordActivity()
        Self.logger.notice("Password stored")
    }

    /// The stored password as UTF-8. **The caller must zero the result**
    /// (`resetBytes(in:)`) as soon as it is used. Needs an unlocked session,
    /// and counts as activity only when it succeeds.
    func readPassword() async throws -> Data {
        guard session.isOwnerVerified else { throw FacePasswordError.sessionLocked }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw FacePasswordError.noStoredPassword
        }
        guard try await session.key(creatingIfNeeded: false) != nil else {
            throw FaceUnlockSessionError.keyUnavailable
        }
        let plaintext: Data
        do {
            plaintext = try session.openSealed(Data(contentsOf: fileURL), as: .password)
        } catch {
            Self.logger.error("Stored password decrypt failed: \(error.localizedDescription, privacy: .public)")
            throw FacePasswordError.decryptionFailed
        }
        session.recordActivity()
        Self.logger.notice("Stored password read")
        return plaintext
    }

    /// The stored password, decrypted straight into a `SecretBytes`, for the
    /// lock screen. Synchronous, so no plaintext `Data` crosses an await; the
    /// decrypted `Data` is zeroed in place as it is moved. Never prompts and
    /// never touches the keychain: it needs the session unlocked with its key
    /// already in memory, and throws `.sessionLocked` otherwise. Counts as
    /// activity only when it succeeds. The caller wipes the result.
    func readPasswordSecret() throws -> SecretBytes {
        guard session.isUnlocked, session.cachedKey != nil else { throw FacePasswordError.sessionLocked }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw FacePasswordError.noStoredPassword
        }
        var plaintext: Data
        do {
            plaintext = try session.openSealed(Data(contentsOf: fileURL), as: .password)
        } catch {
            Self.logger.error("Stored password decrypt failed: \(error.localizedDescription, privacy: .public)")
            throw FacePasswordError.decryptionFailed
        }
        let secret = SecretBytes(taking: &plaintext)
        session.recordActivity()
        Self.logger.notice("Stored password read")
        return secret
    }

    /// Removes the file. Needs no key, so it is also the way out when the
    /// key is missing or unreadable; the caller runs the owner check first
    /// (`FaceUnlockSession.verifyOwner(reason:)`). The password's epoch moves
    /// on, so a saved copy of the file no longer opens; with no faces left
    /// either, the session deletes the key.
    func delete() throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
        hasStoredPassword = false
        session.noteFileDeleted(.password)
        session.recordActivity()
        Self.logger.notice("Stored password deleted")
    }
}
