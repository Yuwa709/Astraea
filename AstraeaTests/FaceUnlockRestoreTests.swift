import XCTest
import CryptoKit
import LocalAuthentication
@testable import Astraea

/// "Stay unlocked across restarts": a session the owner unlocked is picked
/// up again at the next launch, without the owner check, until auto-lock
/// or Lock Now. Each "relaunch" is a new session over the same directory
/// and memory vault; nothing here touches the real Keychain,
/// LocalAuthentication or the real data.
@MainActor
final class FaceUnlockRestoreTests: XCTestCase {

    private let day: TimeInterval = 24 * 60 * 60
    private let password = "correct horse"

    private var directory: URL!
    private var clock: FaceTestClock!
    private var vault: MemoryKeyVault!
    private var authenticator: FakeOwnerAuthenticator!
    private var lockGuard: FakeLockGuard!
    private var promptClock: FakeFaceUnlockClock!
    /// When the previous run last used the session.
    private var lastUsedAt: Date!

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appending(path: "AstraeaFaceRestoreTests-\(UUID().uuidString)")
        clock = FaceTestClock(Date(timeIntervalSince1970: 2_000_000))
        vault = MemoryKeyVault()
        authenticator = FakeOwnerAuthenticator()
        lockGuard = FakeLockGuard(.unlocked)
        promptClock = FakeFaceUnlockClock()

        // The previous run: the owner unlocks and saves the password.
        let previous = makeSession()
        await previous.unlock(reason: "test")
        try await makePasswordStore(previous).save(password)
        lastUsedAt = clock.now
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    private func makeSession() -> FaceUnlockSession {
        let clock = self.clock!
        return FaceUnlockSession(vault: vault, authenticator: authenticator, directory: directory, now: { clock.now })
    }

    private func makePasswordStore(_ session: FaceUnlockSession) -> FacePasswordStore {
        FacePasswordStore(session: session, verifier: FakePasswordVerifier(correct: password))
    }

    private func makePrompt(_ session: FaceUnlockSession, interval: AutoLockInterval = .sevenDays) -> FaceUnlockLoginPrompt {
        FaceUnlockLoginPrompt(session: session, lockGuard: lockGuard, clock: promptClock,
                              isEnabled: { true }, autoLockInterval: { interval },
                              hasStoredPassword: { true })
    }

    private func run(_ prompt: FaceUnlockLoginPrompt) async {
        for _ in 0..<3 {
            await prompt.waitUntilSettled()
            for _ in 0..<5 { await Task.yield() }
        }
    }

    private var recordExists: Bool {
        FileManager.default.fileExists(atPath: directory.appending(path: FaceSessionRecord.fileName).path)
    }

    // MARK: - Restore

    func testAValidRecordRestoresTheSessionWithoutTheOwnerCheck() async throws {
        clock.advance(by: 3 * day)
        let authCalls = authenticator.calls
        let session = makeSession()
        let prompt = makePrompt(session)
        prompt.schedule()
        await run(prompt)

        XCTAssertEqual(prompt.restoreOutcome, .restored)
        XCTAssertEqual(session.state, .unlocked)
        XCTAssertTrue(session.hasKeyInMemory)
        XCTAssertEqual(authenticator.calls, authCalls, "no Touch ID or password prompt")
        XCTAssertEqual(prompt.phase, .done)
        XCTAssertEqual(session.lastActivityAt, lastUsedAt, "the last use carries over; a restart is not use")
        let secret = try makePasswordStore(session).readPasswordSecret()
        XCTAssertEqual(secret.withUnsafeBytes { Array($0) }, Array(password.utf8))
        secret.wipe()
    }

    func testAnExpiredRecordIsDeletedWithoutAKeyReadAndTheOwnerIsAskedOnce() async {
        clock.advance(by: 8 * day)
        authenticator.error = LAError(.userCancel)
        let authCalls = authenticator.calls, reads = vault.reads
        let session = makeSession()
        let prompt = makePrompt(session)
        prompt.schedule()
        await run(prompt)

        XCTAssertEqual(prompt.restoreOutcome, .expired)
        XCTAssertFalse(recordExists, "deleted")
        XCTAssertEqual(vault.reads, reads, "an expired record never touches the keychain")
        XCTAssertEqual(authenticator.calls, authCalls + 1, "asked once, as before")
        XCTAssertEqual(session.state, .locked)
    }

    func testNeverExpiresOnNever() async {
        clock.advance(by: 400 * day)
        let session = makeSession()
        let outcome = await session.restorePersistedUnlock(interval: .never)
        XCTAssertEqual(outcome, .restored)
    }

    func testTheRestoreWaitsWhileTheScreenIsLocked() async {
        lockGuard.state = .locked
        let authCalls = authenticator.calls, reads = vault.reads
        let session = makeSession()
        let prompt = makePrompt(session)
        prompt.schedule()
        await run(prompt)
        XCTAssertNil(prompt.restoreOutcome, "not tried at the lock screen")
        XCTAssertEqual(vault.reads, reads, "no keychain read at the lock screen")
        XCTAssertEqual(prompt.phase, .deferredUntilUnlock)
        XCTAssertEqual(session.state, .locked)
        XCTAssertTrue(recordExists)

        lockGuard.state = .unlocked
        prompt.screenDidUnlock()
        await run(prompt)
        XCTAssertEqual(prompt.restoreOutcome, .restored)
        XCTAssertEqual(session.state, .unlocked)
        XCTAssertEqual(authenticator.calls, authCalls)
    }

    func testAKeyReadFailureFallsBackToTheOwnerCheckAndKeepsTheRecord() async {
        vault.readError = FaceKeyVaultError.keychain(errSecAuthFailed)
        let authCalls = authenticator.calls
        let session = makeSession()
        let prompt = makePrompt(session)
        prompt.schedule()
        await run(prompt)
        XCTAssertEqual(prompt.restoreOutcome, .keyUnavailable)
        XCTAssertEqual(authenticator.calls, authCalls + 1, "the ask-once prompt, as before")
        XCTAssertEqual(session.state, .locked, "its key read fails too")
        XCTAssertTrue(recordExists, "kept for a later launch")
    }

    func testACorruptRecordIsIgnoredAndDeleted() async throws {
        try Data("not json".utf8).write(to: directory.appending(path: FaceSessionRecord.fileName))
        // Cancelled, so no new unlock writes a fresh record over the check.
        authenticator.error = LAError(.userCancel)
        let authCalls = authenticator.calls
        let session = makeSession()
        let prompt = makePrompt(session)
        prompt.schedule()
        await run(prompt)
        XCTAssertEqual(prompt.restoreOutcome, .invalid)
        XCTAssertFalse(recordExists)
        XCTAssertEqual(authenticator.calls, authCalls + 1, "falls back to the ask-once prompt")
        XCTAssertEqual(session.state, .locked)
    }

    /// The ask-once prompt that follows a failed restore starts a new
    /// record, so the next launch restores.
    func testUnlockingAfterAFailedRestoreWritesAFreshRecord() async throws {
        try Data("not json".utf8).write(to: directory.appending(path: FaceSessionRecord.fileName))
        let session = makeSession()
        let prompt = makePrompt(session)
        prompt.schedule()
        await run(prompt)
        XCTAssertEqual(session.state, .unlocked, "by the owner check")
        let outcome = await makeSession().restorePersistedUnlock(interval: .sevenDays)
        XCTAssertEqual(outcome, .restored)
    }

    func testARecordNotSignedByTheKeyIsRejected() async throws {
        let forged = FaceSessionRecord(lastActivityAt: clock.now, key: SymmetricKey(size: .bits256),
                                       epoch: vault.epochs?.session ?? 0)
        try forged.write(to: directory.appending(path: FaceSessionRecord.fileName))
        let session = makeSession()
        let outcome = await session.restorePersistedUnlock(interval: .sevenDays)
        XCTAssertEqual(outcome, .invalid)
        XCTAssertEqual(session.state, .locked)
        XCTAssertFalse(recordExists)
    }

    func testARecordFromTheFutureIsRejected() async throws {
        let previous = makeSession()
        _ = await previous.restorePersistedUnlock(interval: .sevenDays)
        guard let key = previous.cachedKey else { return XCTFail("no key") }
        try FaceSessionRecord(lastActivityAt: clock.now.addingTimeInterval(day), key: key,
                              epoch: vault.epochs?.session ?? 0)
            .write(to: directory.appending(path: FaceSessionRecord.fileName))
        let session = makeSession()
        let outcome = await session.restorePersistedUnlock(interval: .sevenDays)
        XCTAssertEqual(outcome, .invalid)
        XCTAssertFalse(recordExists)
    }

    // MARK: - Deleting the record

    func testLockNowDeletesTheRecord() async {
        let session = makeSession()
        _ = await session.restorePersistedUnlock(interval: .sevenDays)
        XCTAssertTrue(recordExists)
        session.lock()
        XCTAssertFalse(recordExists)
        let outcome = await makeSession().restorePersistedUnlock(interval: .sevenDays)
        XCTAssertEqual(outcome, .noRecord, "the next launch is locked")
    }

    func testDeletingTheLastDataDeletesTheRecord() async throws {
        let session = makeSession()
        _ = await session.restorePersistedUnlock(interval: .sevenDays)
        try makePasswordStore(session).delete()
        XCTAssertFalse(recordExists, "nothing left to restore")
        XCTAssertEqual(session.state, .unlocked, "this run stays as it was")
    }

    // MARK: - Auto-lock and activity

    func testTheAutoLockDeadlineCarriesOverARestart() async {
        clock.advance(by: 3 * day)
        let session = makeSession()
        let locker = FaceSessionAutoLocker(session: session) { .sevenDays }
        let outcome = await session.restorePersistedUnlock(interval: .sevenDays)
        XCTAssertEqual(outcome, .restored)
        for _ in 0..<200 where locker.scheduledDeadline == nil { await Task.yield() }
        XCTAssertEqual(locker.scheduledDeadline, lastUsedAt.addingTimeInterval(7 * day),
                       "seven days from the last use, not from the restart")
        XCTAssertEqual(locker.scheduledDelay, 4 * day)

        clock.advance(by: 5 * day)
        locker.evaluate(reason: "wake")
        XCTAssertEqual(session.state, .locked, "auto-locked on time")
        XCTAssertFalse(recordExists, "and the record went with it")
    }

    func testActivityIsWrittenAtMostOncePerMinute() async throws {
        let session = makeSession()
        _ = await session.restorePersistedUnlock(interval: .sevenDays)
        let url = directory.appending(path: FaceSessionRecord.fileName)
        func stored() -> Date? {
            if case .record(let record) = FaceSessionRecord.load(from: url) { return record.lastActivityAt }
            return nil
        }

        clock.advance(by: 30)
        session.recordActivity()
        XCTAssertEqual(stored(), lastUsedAt, "throttled")
        XCTAssertEqual(session.lastActivityAt, clock.now, "in memory at once")

        clock.advance(by: 31)
        session.recordActivity()
        XCTAssertEqual(stored(), clock.now, "written once a minute has passed")
    }
}
