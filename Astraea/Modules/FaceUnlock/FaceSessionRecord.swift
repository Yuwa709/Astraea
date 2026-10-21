import Foundation
import CryptoKit

/// "Stay unlocked across restarts": the note that the owner unlocked the
/// session, and when it was last used, so a relaunch can pick the session
/// up again until it auto-locks.
///
/// Holds no key and no secret: the key stays in the login keychain, and a
/// restore still reads it from there. Stored as `session.json` beside the
/// encrypted files, owner-only and written atomically (`FaceFileWriter`).
///
/// Signed with an HMAC under the session-record subkey (`FaceCrypto`), so a
/// process that can write the file but not read the key cannot mint or
/// extend an unlocked session. The MAC covers the session epoch, which every
/// lock bumps in the keychain (`FaceKeyEpochs`), so a copy saved before a
/// Lock Now and put back afterwards no longer verifies. The timestamp is in
/// the clear, so an expired record is recognised (and deleted) without
/// touching the keychain.
///
/// Version 1, signed under the master key with no epoch, is still read on
/// the first launch after the update (`FaceKeyMaterial.acceptedLegacyAtLoad`).
nonisolated struct FaceSessionRecord: Codable, Equatable, Sendable {

    static let fileName = "session.json"
    static let currentVersion = 2
    static let legacyVersion = 1

    let version: Int
    let unlocked: Bool
    /// Seconds since 2001 (`Date`'s own measure, so it round-trips exactly).
    /// A `Double` rather than a `Date`, so the signed bytes are exactly what
    /// was written.
    let lastActivity: Double
    /// The session epoch it was signed at; nil in version 1.
    let epoch: UInt64?
    let mac: Data

    var lastActivityAt: Date { Date(timeIntervalSinceReferenceDate: lastActivity) }

    /// `key` is the master key; the record is signed with its subkey.
    init(lastActivityAt: Date, key: SymmetricKey, epoch: UInt64) {
        version = Self.currentVersion
        unlocked = true
        lastActivity = lastActivityAt.timeIntervalSinceReferenceDate
        self.epoch = epoch
        mac = Data(HMAC<SHA256>.authenticationCode(
            for: Self.signedBytes(version: version, unlocked: unlocked, lastActivity: lastActivity, epoch: epoch),
            using: FaceCrypto.subkey(.sessionRecord, from: key)))
    }

    private init(version: Int, unlocked: Bool, lastActivity: Double, epoch: UInt64?, mac: Data) {
        self.version = version
        self.unlocked = unlocked
        self.lastActivity = lastActivity
        self.epoch = epoch
        self.mac = mac
    }

    /// Written over a record that could not be deleted: says locked, carries
    /// no MAC, and so can never restore anything.
    static let locked = FaceSessionRecord(version: currentVersion, unlocked: false, lastActivity: 0, epoch: nil, mac: Data())

    /// A version 1 record, signed under the master key itself. Nothing
    /// writes these any more; tests make them to prove they still restore.
    static func legacy(lastActivityAt: Date, key: SymmetricKey) -> FaceSessionRecord {
        let lastActivity = lastActivityAt.timeIntervalSinceReferenceDate
        let mac = Data(HMAC<SHA256>.authenticationCode(
            for: legacySignedBytes(unlocked: true, lastActivity: lastActivity), using: key))
        return FaceSessionRecord(version: legacyVersion, unlocked: true, lastActivity: lastActivity, epoch: nil, mac: mac)
    }

    /// The MAC checks out under `key` (the master key), at `minimumEpoch` or
    /// later. A version 1 record is checked only when `acceptsLegacy`.
    func isAuthentic(with key: SymmetricKey, minimumEpoch: UInt64, acceptsLegacy: Bool) -> Bool {
        switch version {
        case Self.currentVersion:
            guard let epoch, epoch >= minimumEpoch else { return false }
            return HMAC<SHA256>.isValidAuthenticationCode(
                mac, authenticating: Self.signedBytes(version: version, unlocked: unlocked,
                                                      lastActivity: lastActivity, epoch: epoch),
                using: FaceCrypto.subkey(.sessionRecord, from: key))
        case Self.legacyVersion:
            guard acceptsLegacy else { return false }
            return HMAC<SHA256>.isValidAuthenticationCode(
                mac, authenticating: Self.legacySignedBytes(unlocked: unlocked, lastActivity: lastActivity), using: key)
        default:
            return false
        }
    }

    private static func signedBytes(version: Int, unlocked: Bool, lastActivity: Double, epoch: UInt64) -> Data {
        Data("PopNotch.FaceSession|\(version)|\(unlocked ? 1 : 0)|\(lastActivity.bitPattern)|\(epoch)".utf8)
    }

    private static func legacySignedBytes(unlocked: Bool, lastActivity: Double) -> Data {
        Data("PopNotch.FaceSession|\(legacyVersion)|\(unlocked ? 1 : 0)|\(lastActivity.bitPattern)".utf8)
    }

    // MARK: - File

    enum Loaded: Equatable {
        case none
        /// Unreadable or undecodable: ignored and deleted by the caller.
        case corrupt
        case record(FaceSessionRecord)
    }

    static func load(from url: URL) -> Loaded {
        guard FileManager.default.fileExists(atPath: url.path) else { return .none }
        guard let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(FaceSessionRecord.self, from: data) else {
            return .corrupt
        }
        return .record(record)
    }

    func write(to url: URL) throws {
        try FaceFileWriter.replace(url, with: JSONEncoder().encode(self))
    }

    enum Removal: Equatable {
        case absent
        case removed
        /// The file is still there; the message says why.
        case failed(String)
    }

    static func remove(at url: URL) -> Removal {
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
        do {
            try FileManager.default.removeItem(at: url)
            return .removed
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// true when a file was there and is now gone.
    @discardableResult
    static func delete(at url: URL) -> Bool {
        remove(at: url) == .removed
    }
}
