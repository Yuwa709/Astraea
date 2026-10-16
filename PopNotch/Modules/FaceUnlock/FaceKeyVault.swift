import Foundation
import CryptoKit
import Security
import LocalAuthentication
import os

/// Where the face-data encryption key lives. A protocol so the key's home
/// can change without touching the store, and so tests never hit the
/// Keychain.
///
/// Glance gates its key behind Touch ID (`.userPresence`). That is
/// impossible on PopNotch's ad-hoc-signed releases: measured 2026-10-14,
/// any access-controlled or data-protection-keychain item fails with
/// `errSecMissingEntitlement`, and claiming `keychain-access-groups` gets the
/// process killed at launch (`PROJECT-CONTEXT.md`, *Settled technical
/// decisions*). So the key sits in the ordinary login keychain instead. If
/// PopNotch ever ships Developer ID-signed, a Touch ID vault replaces
/// `LoginKeychainKeyVault` here and nothing else changes.
///
/// Beside the key, the item carries `FaceKeyEpochs` (in `kSecAttrGeneric`):
/// counters that make an older copy of a file stop verifying.
///
/// `readKey` can block on a Keychain prompt, so callers run it off the
/// main actor. The other methods ask for no UI.
nonisolated protocol FaceKeyVault: Sendable {
    /// The existing key, or nil if there is none. Throws when one exists but
    /// cannot be read (cancelled prompt, another build's item): never treat
    /// that as "no key", or a new key would orphan the data.
    func readKey() throws -> SymmetricKey?
    /// Adds a new item with a fresh random key and fresh epochs. Fails if an
    /// item already exists: call `deleteKey()` first.
    func createKey() throws -> SymmetricKey
    /// Removes the item. No item is not an error; an item that exists but
    /// cannot be removed (`errSecInvalidOwnerEdit`, say) throws.
    func deleteKey() throws
    /// The item's epochs. nil when there is no item, or when it has none
    /// (one made before epochs existed, whose files may be in the legacy
    /// layout). Reads attributes only, never the key.
    func readEpochs() throws -> FaceKeyEpochs?
    func writeEpochs(_ epochs: FaceKeyEpochs) throws
}

nonisolated enum FaceKeyVaultError: LocalizedError {
    case keychain(OSStatus)
    /// A key was about to be minted, but the item already there could not
    /// be deleted; it is never reused instead.
    case existingKeyNotRemovable(String)

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            let message = (SecCopyErrorMessageString(status, nil) as String?) ?? "unknown error"
            return "The keychain refused access to the face data key: \(message) (\(status))."
        case .existingKeyNotRemovable(let reason):
            return "An earlier Face Unlock key in your keychain could not be removed, so nothing was saved (\(reason)). Delete \u{201C}PopNotch Face Unlock\u{201D} in Keychain Access, then try again."
        }
    }
}

/// Monotonic counters kept with the key, one per thing a copy could be put
/// back over: each file's header and the session record's MAC carry the
/// value they were sealed with, and anything older than the item's counter
/// is refused. Bumped when a face is deleted or disabled, when the password
/// is removed, and when the session locks.
///
/// Stored as JSON in the item's `kSecAttrGeneric`. Anything able to rewrite
/// the item's attributes can wind them back: they defend against file
/// copies, not against code with keychain access.
nonisolated struct FaceKeyEpochs: Codable, Equatable, Sendable {
    var faces: UInt64 = 0
    var password: UInt64 = 0
    var session: UInt64 = 0
    /// Set once no file in the legacy layout is left under this key: from
    /// then on a legacy file or a version 1 session record is refused,
    /// since older copies of them may still be around.
    var refusesLegacy = false

    subscript(file: FaceDataFile) -> UInt64 {
        get { file == .faces ? faces : password }
        set { if file == .faces { faces = newValue } else { password = newValue } }
    }

    func encoded() throws -> Data { try JSONEncoder().encode(self) }

    /// Attributes that do not decode count as epoch zero with the legacy
    /// layout refused, never as an item that predates epochs: that would
    /// let legacy files back in.
    static func decode(_ data: Data?) -> FaceKeyEpochs? {
        guard let data, !data.isEmpty else { return nil }
        return (try? JSONDecoder().decode(FaceKeyEpochs.self, from: data)) ?? FaceKeyEpochs(refusesLegacy: true)
    }
}

/// A generic-password item in the login keychain.
///
/// After an update, an ad-hoc-signed build has a new signature, so macOS
/// asks once whether this build may read the previous one's item
/// (`PROJECT-CONTEXT.md`, on why the Keychain was dropped in 2026-09).
/// That prompt is expected from `readKey`: reads only happen from the
/// Settings window, or at launch to restore a session left unlocked, and
/// only while the screen is unlocked, where the user can answer it. Every
/// other call asks for no UI and fails rather than prompt.
nonisolated struct LoginKeychainKeyVault: FaceKeyVault {
    static let service = "com.techie.PopNotch.FaceUnlock"
    static let account = "faceDataKey"

    private var itemQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
    }

    /// Fails rather than show any authentication UI.
    private var silentItemQuery: [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        var query = itemQuery
        query[kSecUseAuthenticationContext as String] = context
        return query
    }

    func readKey() throws -> SymmetricKey? {
        var query = itemQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw FaceKeyVaultError.keychain(status) }
        guard let data = result as? Data, data.count == 32 else {
            throw FaceKeyVaultError.keychain(errSecDecode)
        }
        return SymmetricKey(data: data)
    }

    func createKey() throws -> SymmetricKey {
        let key = SymmetricKey(size: .bits256)
        var item = itemQuery
        item[kSecAttrLabel as String] = "PopNotch Face Unlock"
        item[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        item[kSecAttrGeneric as String] = try FaceKeyEpochs().encoded()
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw FaceKeyVaultError.keychain(status) }
        return key
    }

    func deleteKey() throws {
        let status = SecItemDelete(silentItemQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw FaceKeyVaultError.keychain(status)
        }
    }

    func readEpochs() throws -> FaceKeyEpochs? {
        var query = silentItemQuery
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw FaceKeyVaultError.keychain(status) }
        guard let attributes = result as? [String: Any] else { throw FaceKeyVaultError.keychain(errSecDecode) }
        return FaceKeyEpochs.decode(attributes[kSecAttrGeneric as String] as? Data)
    }

    func writeEpochs(_ epochs: FaceKeyEpochs) throws {
        let update = [kSecAttrGeneric as String: try epochs.encoded()]
        let status = SecItemUpdate(silentItemQuery as CFDictionary, update as CFDictionary)
        guard status == errSecSuccess else { throw FaceKeyVaultError.keychain(status) }
    }
}

// MARK: - Files

/// The two encrypted files. Each is sealed under its own subkey and its own
/// associated data, so one cannot stand in for the other.
nonisolated enum FaceDataFile: String, CaseIterable, Sendable {
    case faces = "face-identities"
    case password

    var fileName: String {
        switch self {
        case .faces: "face-identities.enc"
        case .password: "password.enc"
        }
    }
}

nonisolated enum FaceCryptoError: LocalizedError, Equatable {
    /// Not this file's layout, or not sealed by this key for this file.
    case unrecognised
    /// Sealed by this key for this file, but older than the keychain's
    /// counter: a copy put back after a delete.
    case rolledBack

    var errorDescription: String? {
        switch self {
        case .unrecognised: "The file was not sealed by this key for this purpose."
        case .rolledBack: "The file is an older copy than the one Face Unlock last wrote."
        }
    }
}

/// AES-256-GCM under subkeys derived from the keychain key.
///
/// **Current layout (version 2):** `"PNFU"`, the byte 2, the file's epoch
/// (8 bytes, big-endian), then `.combined` (12-byte nonce, ciphertext,
/// 16-byte tag). The key is HKDF-SHA256 of the master key with the file's
/// label; the associated data is the label and the header, so the epoch is
/// authenticated and a file sealed for one purpose fails for another.
///
/// **Legacy layout:** `.combined` under the master key itself, no associated
/// data. Read only while the key's epochs allow it; never written.
nonisolated enum FaceCrypto {

    enum Purpose: String {
        case faces = "face-identities"
        case password
        case sessionRecord = "session-record"
    }

    private static let salt = Data("PopNotch.FaceUnlock.subkeys.v2".utf8)
    private static let magic = Data("PNFU".utf8) + Data([2])
    private static var headerLength: Int { magic.count + 8 }

    static func subkey(_ purpose: Purpose, from master: SymmetricKey) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: master, salt: salt,
                               info: Data("PopNotch.FaceUnlock.\(purpose.rawValue)".utf8), outputByteCount: 32)
    }

    private static func purpose(of file: FaceDataFile) -> Purpose {
        file == .faces ? .faces : .password
    }

    // MARK: Version 2

    static func sealFile(_ plaintext: Data, as file: FaceDataFile, epoch: UInt64, master: SymmetricKey) throws -> Data {
        let header = magic + withUnsafeBytes(of: epoch.bigEndian) { Data($0) }
        let box = try AES.GCM.seal(plaintext, using: subkey(purpose(of: file), from: master),
                                   authenticating: associatedData(file, header: header))
        guard let combined = box.combined else { throw CryptoKitError.incorrectParameterSize }
        return header + combined
    }

    /// The plaintext and the epoch it was sealed with, if `data` is a
    /// version 2 file sealed by `master` for `file`; nil otherwise.
    static func openVersion2(_ data: Data, as file: FaceDataFile, master: SymmetricKey) -> (plaintext: Data, epoch: UInt64)? {
        let bytes = Data(data) // indices from 0
        guard bytes.count > headerLength, bytes.prefix(magic.count) == magic else { return nil }
        let header = Data(bytes.prefix(headerLength))
        let epoch = header.suffix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        guard let box = try? AES.GCM.SealedBox(combined: Data(bytes.dropFirst(headerLength))),
              let plaintext = try? AES.GCM.open(box, using: subkey(purpose(of: file), from: master),
                                                authenticating: associatedData(file, header: header)) else {
            return nil
        }
        return (plaintext, epoch)
    }

    /// Opens `data` as `file`: the version 2 layout at `minimumEpoch` or
    /// later, else, only when `acceptsLegacy`, the legacy layout.
    static func openFile(_ data: Data, as file: FaceDataFile, master: SymmetricKey,
                         minimumEpoch: UInt64, acceptsLegacy: Bool) throws -> Data {
        if let opened = openVersion2(data, as: file, master: master) {
            guard opened.epoch >= minimumEpoch else { throw FaceCryptoError.rolledBack }
            return opened.plaintext
        }
        guard acceptsLegacy, let plaintext = try? open(data, using: master) else {
            throw FaceCryptoError.unrecognised
        }
        return plaintext
    }

    private static func associatedData(_ file: FaceDataFile, header: Data) -> Data {
        Data("PopNotch.FaceUnlock.file.\(file.rawValue)|".utf8) + header
    }

    // MARK: Legacy

    /// The legacy layout. Kept to read files written before version 2, and
    /// for tests that make such files; nothing in the app writes it.
    static func seal(_ plaintext: Data, using key: SymmetricKey) throws -> Data {
        guard let combined = try AES.GCM.seal(plaintext, using: key).combined else {
            throw CryptoKitError.incorrectParameterSize
        }
        return combined
    }

    static func open(_ ciphertext: Data, using key: SymmetricKey) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: ciphertext), using: key)
    }
}

// MARK: - Loading the key

/// The key and its epochs, as the session holds them while unlocked.
nonisolated struct FaceKeyMaterial: Sendable {
    let key: SymmetricKey
    var epochs: FaceKeyEpochs
    /// The legacy layout was still accepted when the item was read. A
    /// version 1 session record is honoured on that one load, so the first
    /// launch after the update restores as before.
    let acceptedLegacyAtLoad: Bool

    var acceptsLegacy: Bool { !epochs.refusesLegacy }
}

/// Reads the key off the main actor and, while its item still accepts the
/// legacy layout, re-seals any legacy file in the version 2 layout.
nonisolated enum FaceKeyLoader {

    private static let logger = Logger(subsystem: "com.techie.PopNotch", category: "FaceUnlock")

    /// nil when there is no item. Throws when it cannot be read.
    static func load(from vault: any FaceKeyVault, directory: URL) throws -> FaceKeyMaterial? {
        guard let key = try vault.readKey() else { return nil }
        let stored = try vault.readEpochs()
        if let stored, stored.refusesLegacy {
            return FaceKeyMaterial(key: key, epochs: stored, acceptedLegacyAtLoad: false)
        }
        let epochs = migrate(directory: directory, key: key, epochs: stored ?? FaceKeyEpochs(), vault: vault)
        return FaceKeyMaterial(key: key, epochs: epochs, acceptedLegacyAtLoad: true)
    }

    /// A fresh item, never one that was already there: that could have
    /// been planted by another process with a key it knows. Throws, and
    /// creates nothing, when the existing item cannot be removed.
    static func mint(in vault: any FaceKeyVault) throws -> FaceKeyMaterial {
        do {
            try vault.deleteKey()
        } catch {
            logger.error("Face Unlock key not minted: the existing item could not be deleted: \(error.localizedDescription, privacy: .public)")
            throw FaceKeyVaultError.existingKeyNotRemovable(error.localizedDescription)
        }
        let key = try vault.createKey()
        logger.notice("Face Unlock key minted")
        return FaceKeyMaterial(key: key, epochs: FaceKeyEpochs(), acceptedLegacyAtLoad: false)
    }

    /// Re-seals each file that opens in the legacy layout, checking that the
    /// new file opens before it replaces the old one. Only once every one is
    /// done are the epochs saved with the legacy layout refused; until then
    /// the next load tries again. A file that opens in neither layout is
    /// left alone: it is unreadable either way.
    static func migrate(directory: URL, key: SymmetricKey, epochs: FaceKeyEpochs,
                        vault: any FaceKeyVault) -> FaceKeyEpochs {
        var resealed = 0
        for file in FaceDataFile.allCases {
            let url = directory.appending(path: file.fileName)
            guard FileManager.default.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url),
                  FaceCrypto.openVersion2(data, as: file, master: key) == nil,
                  var plaintext = try? FaceCrypto.open(data, using: key) else { continue }
            defer { plaintext.resetBytes(in: 0..<plaintext.count) }
            do {
                let sealed = try FaceCrypto.sealFile(plaintext, as: file, epoch: epochs[file], master: key)
                guard FaceCrypto.openVersion2(sealed, as: file, master: key)?.plaintext == plaintext else {
                    throw FaceCryptoError.unrecognised
                }
                try FaceFileWriter.replace(url, with: sealed)
                resealed += 1
            } catch {
                logger.error("Face data migration stopped: \(file.rawValue, privacy: .public) not re-sealed: \(error.localizedDescription, privacy: .public)")
                return epochs
            }
        }
        var migrated = epochs
        migrated.refusesLegacy = true
        do {
            try vault.writeEpochs(migrated)
            logger.notice("Face data in the version 2 layout: \(resealed, privacy: .public) legacy files re-sealed; legacy layout refused from now on")
        } catch {
            logger.error("Face data re-sealed (\(resealed, privacy: .public) files) but the epochs were not saved: \(error.localizedDescription, privacy: .public)")
            return epochs
        }
        return migrated
    }
}
