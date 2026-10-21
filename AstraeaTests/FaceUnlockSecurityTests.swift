import XCTest
import CryptoKit
import LocalAuthentication
@testable import Astraea

/// The 2026-10-15 security review's fixes: a fresh owner check for anything
/// that weakens Face Unlock (H1), no trust in a keychain item found with no
/// data on disk (M1), files and the session record bound to their purpose
/// and epoch (L2, L3, L4), and the migration of data sealed before that.
/// Every test injects the memory vault, a fake owner check and a temporary
/// directory; none reaches the real Keychain, LocalAuthentication or data.
@MainActor
final class FaceUnlockSecurityTests: XCTestCase {

    private let password = "correct horse"
    private var directory: URL!
    private var vault: MemoryKeyVault!
    private var authenticator: FakeOwnerAuthenticator!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appending(path: "AstraeaFaceSecurityTests-\(UUID().uuidString)")
        vault = MemoryKeyVault()
        authenticator = FakeOwnerAuthenticator()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func makeSession() -> FaceUnlockSession {
        FaceUnlockSession(vault: vault, authenticator: authenticator, directory: directory)
    }

    private func makePasswords(_ session: FaceUnlockSession) -> FacePasswordStore {
        FacePasswordStore(session: session, verifier: FakePasswordVerifier(correct: password))
    }

    private func sample(_ embedding: [Float]) -> FaceSample {
        FaceSample(embedding: embedding, pose: "center", capturedAt: Date(timeIntervalSince1970: 0), quality: 0.6)
    }

    private func url(_ file: FaceDataFile) -> URL { directory.appending(path: file.fileName) }
    private var recordURL: URL { directory.appending(path: FaceSessionRecord.fileName) }

    /// A session with one face ("A") and the password saved.
    private func setUpData() async throws -> (FaceUnlockSession, FaceEnrollmentStore) {
        let session = makeSession()
        await session.unlock(reason: "test")
        let store = FaceEnrollmentStore(session: session)
        await store.unlock()
        try await store.commitEnrollment(name: "A", samples: [sample([1, 0])])
        try await makePasswords(session).save(password)
        return (session, store)
    }

    /// A relaunch: a new session over the same directory and vault.
    private func relaunch() async -> (FaceUnlockSession, FaceEnrollmentStore) {
        let session = makeSession()
        let store = FaceEnrollmentStore(session: session)
        await store.unlock()
        return (session, store)
    }

    private func storedPassword(_ session: FaceUnlockSession) async throws -> String {
        var bytes = try await makePasswords(session).readPassword()
        defer { bytes.resetBytes(in: 0..<bytes.count) }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: - H1: a fresh owner check

    func testReauthenticateAsksEvenWhileUnlocked() async {
        let session = makeSession()
        await session.unlock(reason: "test")
        XCTAssertEqual(authenticator.calls, 1)

        let first = await session.reauthenticate(reason: "loosen it")
        let second = await session.reauthenticate(reason: "loosen it again")
        XCTAssertTrue(first)
        XCTAssertTrue(second)
        XCTAssertEqual(authenticator.calls, 3, "an unlocked session never answers for the owner")
        XCTAssertEqual(authenticator.reasons.suffix(2), ["loosen it", "loosen it again"])
        XCTAssertEqual(session.state, .unlocked, "changes no state")

        let verified = await session.verifyOwner(reason: "delete")
        XCTAssertTrue(verified)
        XCTAssertEqual(authenticator.calls, 3, "removing data still needs only the plain check")
    }

    func testARefusedReauthenticationChangesNothing() async {
        let session = makeSession()
        await session.unlock(reason: "test")
        authenticator.error = LAError(.userCancel)
        let verified = await session.reauthenticate(reason: "loosen it")
        XCTAssertFalse(verified)
        XCTAssertEqual(session.state, .unlocked)
    }

    func testLockingDuringReauthenticationVoidsIt() async {
        let prompt = SuspendingOwnerAuthenticator()
        let session = FaceUnlockSession(vault: vault, authenticator: prompt, directory: directory)
        let checking = Task { await session.reauthenticate(reason: "loosen it") }
        for _ in 0..<1_000 where !prompt.isWaiting { try? await Task.sleep(for: .milliseconds(2)) }
        session.lock()
        for _ in 0..<1_000 where !prompt.wasCancelled { try? await Task.sleep(for: .milliseconds(2)) }
        XCTAssertTrue(prompt.wasCancelled, "locking takes the prompt down")
        prompt.resume()
        let verified = await checking.value
        XCTAssertFalse(verified)
    }

    func testWhatCountsAsWeakening() {
        XCTAssertTrue(FaceMatchThreshold.balanced.isWeaker(than: .strict))
        XCTAssertTrue(FaceMatchThreshold.lenient.isWeaker(than: .balanced))
        XCTAssertFalse(FaceMatchThreshold.strict.isWeaker(than: .lenient))
        XCTAssertFalse(FaceMatchThreshold.balanced.isWeaker(than: .balanced))

        XCTAssertTrue(FaceLivenessLevel.off.isWeaker(than: .light))
        XCTAssertFalse(FaceLivenessLevel.light.isWeaker(than: .off))
        XCTAssertFalse(FaceLivenessLevel.light.isWeaker(than: .light))

        XCTAssertTrue(AutoLockInterval.fourteenDays.isLonger(than: .sevenDays))
        XCTAssertTrue(AutoLockInterval.never.isLonger(than: .thirtyDays))
        XCTAssertFalse(AutoLockInterval.sevenDays.isLonger(than: .never))
        XCTAssertFalse(AutoLockInterval.sevenDays.isLonger(than: .thirtyDays))
        XCTAssertFalse(AutoLockInterval.never.isLonger(than: .never))
    }

    func testTheGateAppliesAStricterChangeAtOnceAndAWeakerOneOnlyAfterTheOwner() async {
        let session = makeSession()
        await session.unlock(reason: "test")
        let gate = FaceOwnerGate(store: FaceEnrollmentStore(session: session))
        var applied: [String] = []

        gate.apply(weakens: false, reason: "stricter") { applied.append("stricter") }
        XCTAssertEqual(applied, ["stricter"], "synchronous, no prompt")
        XCTAssertEqual(authenticator.calls, 1)

        authenticator.error = LAError(.userCancel)
        gate.apply(weakens: true, reason: "weaker") { applied.append("refused") }
        for _ in 0..<50 where authenticator.calls < 2 { await Task.yield() }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(authenticator.calls, 2)
        XCTAssertEqual(applied, ["stricter"], "a refused check changes nothing")

        authenticator.error = nil
        gate.apply(weakens: true, reason: "weaker") { applied.append("weaker") }
        for _ in 0..<50 where applied.count < 2 { await Task.yield() }
        XCTAssertEqual(applied, ["stricter", "weaker"])
        XCTAssertEqual(authenticator.calls, 3)
    }

    func testAddingAFaceAsksTheOwnerOnceWhetherLockedOrUnlocked() async {
        let session = makeSession()
        let gate = FaceOwnerGate(store: FaceEnrollmentStore(session: session))

        // Locked: unlocking is the check.
        let fromLocked = await gate.requireKeyAndFreshOwner(reason: "add a face")
        XCTAssertTrue(fromLocked)
        XCTAssertEqual(authenticator.calls, 1)

        // Unlocked: asked again.
        let fromUnlocked = await gate.requireKeyAndFreshOwner(reason: "add a face")
        XCTAssertTrue(fromUnlocked)
        XCTAssertEqual(authenticator.calls, 2)
        XCTAssertEqual(authenticator.reasons.last, "add a face")

        authenticator.error = LAError(.userCancel)
        let refused = await gate.requireKeyAndFreshOwner(reason: "add a face")
        XCTAssertFalse(refused)
        XCTAssertEqual(session.state, .unlocked, "a refused re-check does not lock")
    }

    // MARK: - M1: a planted key

    func testAKeyFoundWithNothingOnDiskIsReplacedNotReused() async throws {
        let planted = SymmetricKey(size: .bits256)
        vault = MemoryKeyVault(key: planted, epochs: FaceKeyEpochs())
        let session = makeSession()
        await session.unlock(reason: "test")
        try await makePasswords(session).save(password)

        XCTAssertEqual(vault.deletes, 1, "the item that was there is deleted")
        XCTAssertEqual(vault.creates, 1)
        let stored = try XCTUnwrap(vault.storedKey)
        XCTAssertNotEqual(stored.withUnsafeBytes { Data($0) }, planted.withUnsafeBytes { Data($0) })
        let file = try Data(contentsOf: url(.password))
        XCTAssertNil(FaceCrypto.openVersion2(file, as: .password, master: planted), "the planted key opens nothing")
        XCTAssertNil(try? FaceCrypto.open(file, using: planted))
    }

    func testAKeyThatCannotBeDeletedIsNeverReused() async throws {
        vault = MemoryKeyVault(key: SymmetricKey(size: .bits256), epochs: FaceKeyEpochs())
        vault.deleteError = FaceKeyVaultError.keychain(errSecInvalidOwnerEdit)
        let session = makeSession()
        await session.unlock(reason: "test")
        do {
            try await makePasswords(session).save(password)
            XCTFail("saved under a key that could not be replaced")
        } catch {
            guard case .existingKeyNotRemovable = error as? FaceKeyVaultError else {
                return XCTFail("unexpected error \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url(.password).path), "nothing written")
        XCTAssertEqual(vault.creates, 0)
        XCTAssertNotNil(session.lastError, "the user is told")

        let store = FaceEnrollmentStore(session: session)
        await store.unlock()
        do {
            try await store.commitEnrollment(name: "A", samples: [sample([1, 0])])
            XCTFail("enrolled under a key that could not be replaced")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: url(.faces).path))
    }

    func testDeletingAllTheDataDeletesTheKey() async throws {
        let (session, store) = try await setUpData()
        XCTAssertNotNil(vault.storedKey)
        store.deleteAll()
        XCTAssertNotNil(vault.storedKey, "the password still needs it")
        try makePasswords(session).delete()
        XCTAssertNil(vault.storedKey, "nothing left that it sealed")
        XCTAssertFalse(session.hasKeyInMemory)
        XCTAssertEqual(session.state, .unlocked)

        try await makePasswords(session).save(password)
        XCTAssertEqual(vault.creates, 2, "the next save mints a fresh key")
        let read = try await storedPassword(session)
        XCTAssertEqual(read, password)
    }

    func testExistingDataKeepsItsKey() async throws {
        _ = try await setUpData()
        let (session, store) = await relaunch()
        XCTAssertEqual(store.state, .ready)
        XCTAssertEqual(store.identities.map(\.name), ["A"])
        let read = try await storedPassword(session)
        XCTAssertEqual(read, password)
        XCTAssertEqual(vault.creates, 1)
        XCTAssertEqual(vault.deletes, 0)
    }

    // MARK: - L4: one file cannot stand in for the other

    func testTheFaceFileCopiedOverThePasswordDoesNotOpen() async throws {
        _ = try await setUpData()
        try FileManager.default.removeItem(at: url(.password))
        try FileManager.default.copyItem(at: url(.faces), to: url(.password))

        let (session, _) = await relaunch()
        do {
            _ = try await storedPassword(session)
            XCTFail("the face file decrypted as the password")
        } catch {
            XCTAssertEqual(error as? FacePasswordError, .decryptionFailed)
        }
    }

    func testThePasswordFileCopiedOverTheFacesDoesNotOpen() async throws {
        _ = try await setUpData()
        try FileManager.default.removeItem(at: url(.faces))
        try FileManager.default.copyItem(at: url(.password), to: url(.faces))
        let (_, store) = await relaunch()
        guard case .unreadable = store.state else { return XCTFail("expected unreadable, got \(store.state)") }
    }

    // MARK: - L3: rolled-back files

    func testARolledBackFaceFileDoesNotResurrectADeletedFace() async throws {
        let (_, store) = try await setUpData()
        let b = try await store.commitEnrollment(name: "B", samples: [sample([0, 1])])
        let withB = try Data(contentsOf: url(.faces))
        try store.delete(b.id)
        try withB.write(to: url(.faces))

        let (_, reloaded) = await relaunch()
        guard case .unreadable = reloaded.state else { return XCTFail("expected unreadable, got \(reloaded.state)") }
        XCTAssertTrue(reloaded.identities.isEmpty)
    }

    func testARolledBackFaceFileDoesNotReEnableADisabledFace() async throws {
        let (_, store) = try await setUpData()
        let enabled = try Data(contentsOf: url(.faces))
        try store.setEnabled(false, for: store.identities[0].id)
        try enabled.write(to: url(.faces))

        let (_, reloaded) = await relaunch()
        guard case .unreadable = reloaded.state else { return XCTFail("expected unreadable, got \(reloaded.state)") }
    }

    func testOrdinaryWritesStillReadBackAfterARelaunch() async throws {
        let (_, store) = try await setUpData()
        let b = try await store.commitEnrollment(name: "B", samples: [sample([0, 1])])
        try store.setEnabled(false, for: b.id)
        try store.setEnabled(true, for: b.id)
        try store.delete(store.identities[0].id)
        let (session, reloaded) = await relaunch()
        XCTAssertEqual(reloaded.state, .ready)
        XCTAssertEqual(reloaded.identities.map(\.name), ["B"])
        XCTAssertEqual(reloaded.identities.first?.isEnabled, true)
        let read = try await storedPassword(session)
        XCTAssertEqual(read, password)
    }

    func testARemovedPasswordPutBackDoesNotOpen() async throws {
        let (session, _) = try await setUpData()
        let saved = try Data(contentsOf: url(.password))
        try makePasswords(session).delete()
        XCTAssertNotNil(vault.storedKey, "the faces still need the key")
        try saved.write(to: url(.password))

        let (relaunched, _) = await relaunch()
        do {
            _ = try await storedPassword(relaunched)
            XCTFail("a removed password came back")
        } catch {
            XCTAssertEqual(error as? FacePasswordError, .decryptionFailed)
        }
    }

    // MARK: - L2: a saved session record after Lock Now

    func testASavedRecordPutBackAfterLockNowDoesNotRestore() async throws {
        let (session, _) = try await setUpData()
        let saved = try Data(contentsOf: recordURL)
        session.lock()
        XCTAssertFalse(FileManager.default.fileExists(atPath: recordURL.path))
        try saved.write(to: recordURL)

        let outcome = await makeSession().restorePersistedUnlock(interval: .sevenDays)
        XCTAssertEqual(outcome, .invalid, "the lock moved the session epoch on")
        XCTAssertFalse(FileManager.default.fileExists(atPath: recordURL.path))
    }

    func testARecordWrittenAfterTheLockStillRestores() async throws {
        let (session, _) = try await setUpData()
        session.lock()
        await session.unlock(reason: "test")
        let outcome = await makeSession().restorePersistedUnlock(interval: .sevenDays)
        XCTAssertEqual(outcome, .restored)
    }

    func testALockedRecordNeverRestores() async throws {
        _ = try await setUpData()
        try FaceSessionRecord.locked.write(to: recordURL)
        let outcome = await makeSession().restorePersistedUnlock(interval: .sevenDays)
        XCTAssertEqual(outcome, .noRecord)
    }

    // MARK: - Migration from the legacy layout

    /// Writes what a build before the fix left: both files sealed under the
    /// master key with no associated data, a version 1 record, and an item
    /// with no epochs.
    private func writeLegacyData(key: SymmetricKey, identities: [FaceIdentity]) throws {
        try FaceFileWriter.replace(url(.faces), with: FaceCrypto.seal(JSONEncoder().encode(identities), using: key))
        try FaceFileWriter.replace(url(.password), with: FaceCrypto.seal(Data(password.utf8), using: key))
        try FaceSessionRecord.legacy(lastActivityAt: Date(), key: key).write(to: recordURL)
        vault = MemoryKeyVault(key: key)
    }

    func testLegacyDataStillOpensAndIsResealed() async throws {
        let key = SymmetricKey(size: .bits256)
        let owner = FaceIdentity(name: "Owner", samples: [sample([1, 0])])
        try writeLegacyData(key: key, identities: [owner])
        let legacyFaces = try Data(contentsOf: url(.faces))

        // The first launch after the update restores the session, as before.
        let session = makeSession()
        let outcome = await session.restorePersistedUnlock(interval: .sevenDays)
        XCTAssertEqual(outcome, .restored)
        XCTAssertEqual(authenticator.calls, 0)

        let store = FaceEnrollmentStore(session: session)
        await store.unlock()
        XCTAssertEqual(store.identities, [owner], "nothing lost")
        let read = try await storedPassword(session)
        XCTAssertEqual(read, password)
        let secret = try makePasswords(session).readPasswordSecret()
        XCTAssertEqual(secret.withUnsafeBytes { Array($0) }, Array(password.utf8), "the lock-screen path too")
        secret.wipe()

        // Re-sealed in the current layout, and the record re-signed.
        XCTAssertNotNil(FaceCrypto.openVersion2(try Data(contentsOf: url(.faces)), as: .faces, master: key))
        XCTAssertNotNil(FaceCrypto.openVersion2(try Data(contentsOf: url(.password)), as: .password, master: key))
        XCTAssertEqual(vault.epochs?.refusesLegacy, true)
        guard case .record(let record) = FaceSessionRecord.load(from: recordURL) else { return XCTFail("no record") }
        XCTAssertEqual(record.version, FaceSessionRecord.currentVersion)
        XCTAssertEqual(vault.creates, 0, "the user's key is kept")

        // A legacy copy put back is refused from now on.
        try legacyFaces.write(to: url(.faces))
        let (_, reloaded) = await relaunch()
        guard case .unreadable = reloaded.state else { return XCTFail("expected unreadable, got \(reloaded.state)") }
    }

    func testLegacyDataIsResealedByAnOwnerUnlockToo() async throws {
        let key = SymmetricKey(size: .bits256)
        let owner = FaceIdentity(name: "Owner", samples: [sample([1, 0])])
        try writeLegacyData(key: key, identities: [owner])
        try FileManager.default.removeItem(at: recordURL)

        let (session, store) = await relaunch()
        XCTAssertEqual(authenticator.calls, 1)
        XCTAssertEqual(store.identities, [owner])
        let read = try await storedPassword(session)
        XCTAssertEqual(read, password)
        XCTAssertNotNil(FaceCrypto.openVersion2(try Data(contentsOf: url(.password)), as: .password, master: key))
        XCTAssertEqual(vault.epochs?.refusesLegacy, true)

        // A version 1 record is refused once the item no longer accepts the
        // legacy layout.
        try FaceSessionRecord.legacy(lastActivityAt: Date(), key: key).write(to: recordURL)
        let outcome = await makeSession().restorePersistedUnlock(interval: .sevenDays)
        XCTAssertEqual(outcome, .invalid)
    }

    /// The legacy reader itself: a file sealed by the old code path opens
    /// through the new one while legacy is accepted, and not after.
    func testTheNewReaderOpensTheLegacyLayoutOnlyWhileAllowed() throws {
        let key = SymmetricKey(size: .bits256)
        let legacy = try FaceCrypto.seal(Data("secret".utf8), using: key)
        XCTAssertEqual(try FaceCrypto.openFile(legacy, as: .password, master: key, minimumEpoch: 0, acceptsLegacy: true),
                       Data("secret".utf8))
        XCTAssertThrowsError(try FaceCrypto.openFile(legacy, as: .password, master: key, minimumEpoch: 0, acceptsLegacy: false))

        let current = try FaceCrypto.sealFile(Data("secret".utf8), as: .password, epoch: 3, master: key)
        XCTAssertEqual(try FaceCrypto.openFile(current, as: .password, master: key, minimumEpoch: 3, acceptsLegacy: false),
                       Data("secret".utf8))
        XCTAssertThrowsError(try FaceCrypto.openFile(current, as: .password, master: key, minimumEpoch: 4, acceptsLegacy: true)) {
            XCTAssertEqual($0 as? FaceCryptoError, .rolledBack)
        }
        XCTAssertThrowsError(try FaceCrypto.openFile(current, as: .faces, master: key, minimumEpoch: 0, acceptsLegacy: true))
        XCTAssertNil(try? FaceCrypto.open(current, using: key), "the current layout is not the legacy one")
    }
}
