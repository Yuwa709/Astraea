import XCTest
import CryptoKit
import LocalAuthentication
import Observation
@testable import PopNotch

/// Face Unlock, phase 2: the session gate, the stored password and the
/// idle auto-lock. Every test injects a fake vault, owner check, password
/// verifier and clock, and a temporary directory; none may reach the real
/// Keychain, LocalAuthentication, OpenDirectory or the real data.
@MainActor
final class FaceUnlockSessionTests: XCTestCase {

    private var directory: URL!
    private var clock: FaceTestClock!
    private var vault: MemoryKeyVault!
    private var authenticator: FakeOwnerAuthenticator!
    private var verifier: FakePasswordVerifier!

    private let day: TimeInterval = 24 * 60 * 60

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appending(path: "PopNotchFaceSessionTests-\(UUID().uuidString)")
        clock = FaceTestClock(Date(timeIntervalSince1970: 1_000_000))
        vault = MemoryKeyVault()
        authenticator = FakeOwnerAuthenticator()
        verifier = FakePasswordVerifier(correct: "correct horse")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        clock = nil
        vault = nil
        authenticator = nil
        verifier = nil
        super.tearDown()
    }

    private func makeSession(vault: MemoryKeyVault? = nil) -> FaceUnlockSession {
        let clock = self.clock!
        return FaceUnlockSession(vault: vault ?? self.vault, authenticator: authenticator,
                                 directory: directory, now: { clock.now })
    }

    private func makePasswordStore(_ session: FaceUnlockSession) -> FacePasswordStore {
        FacePasswordStore(session: session, verifier: verifier)
    }

    private func writeOpaqueData(to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data((0..<64).map { UInt8($0) }).write(to: url)
    }

    private func sample(_ embedding: [Float]) -> FaceSample {
        FaceSample(embedding: embedding, pose: "center", capturedAt: Date(timeIntervalSince1970: 0), quality: 0.6)
    }

    // MARK: - Session

    func testCancelledOwnerCheckLeavesTheSessionLocked() async {
        authenticator.error = LAError(.userCancel)
        let session = makeSession()
        let verified = await session.unlock(reason: "test")
        XCTAssertFalse(verified)
        XCTAssertEqual(session.state, .locked)
        XCTAssertNotNil(session.lastError)
        XCTAssertNil(session.lastActivityAt)
        XCTAssertEqual(vault.reads, 0, "no key is read before the owner check passes")
        do {
            _ = try await session.key(creatingIfNeeded: true)
            XCTFail("a locked session must not hand out a key")
        } catch {
            XCTAssertEqual(error as? FaceUnlockSessionError, .locked)
        }
        XCTAssertEqual(vault.creates, 0)
    }

    func testUnlockWithNoDataTouchesNoKeychainItem() async {
        let session = makeSession()
        let verified = await session.unlock(reason: "test")
        XCTAssertTrue(verified)
        XCTAssertEqual(session.state, .unlocked)
        XCTAssertEqual(session.lastActivityAt, clock.now)
        XCTAssertEqual(authenticator.calls, 1)
        XCTAssertEqual(vault.reads, 0)
        XCTAssertEqual(vault.creates, 0)
    }

    func testConcurrentUnlocksShareOneOwnerCheck() async {
        let session = makeSession()
        async let first = session.unlock(reason: "a")
        async let second = session.unlock(reason: "b")
        let results = await [first, second]
        XCTAssertEqual(results, [true, true])
        XCTAssertEqual(authenticator.calls, 1)
    }

    func testMissingKeyWithDataOnDiskIsKeyMissingAndNeverCreatesAKey() async throws {
        try writeOpaqueData(to: directory.appending(path: FaceUnlockSession.passwordFileName))
        let session = makeSession()
        let verified = await session.unlock(reason: "test")
        XCTAssertTrue(verified, "the owner was verified; only the key is gone")
        XCTAssertEqual(session.state, .keyMissing)
        XCTAssertNotNil(session.lastError)

        do {
            _ = try await session.key(creatingIfNeeded: true)
            XCTFail("a key must never be minted over existing data")
        } catch {
            XCTAssertEqual(error as? FaceUnlockSessionError, .keyUnavailable)
        }
        let passwords = makePasswordStore(session)
        do {
            try await passwords.save("correct horse")
            XCTFail("saving must not mint a key over existing data")
        } catch {}
        XCTAssertEqual(vault.creates, 0)
    }

    func testDeletingTheOrphanedDataLetsTheNextSaveCreateAKey() async throws {
        try writeOpaqueData(to: directory.appending(path: FaceUnlockSession.passwordFileName))
        let session = makeSession()
        await session.unlock(reason: "test")
        let passwords = makePasswordStore(session)
        XCTAssertTrue(passwords.hasStoredPassword)

        try passwords.delete()
        XCTAssertEqual(session.state, .unlocked)
        try await passwords.save("correct horse")
        XCTAssertEqual(vault.creates, 1)
    }

    func testRefusedKeyReadStaysLockedAndMintsNothing() async throws {
        try writeOpaqueData(to: directory.appending(path: FaceUnlockSession.faceIdentitiesFileName))
        vault.readError = FaceKeyVaultError.keychain(errSecUserCanceled)
        let session = makeSession()
        let verified = await session.unlock(reason: "test")
        XCTAssertFalse(verified)
        XCTAssertEqual(session.state, .locked, "a read error is never \"no key\"")
        XCTAssertNotNil(session.lastError)
        XCTAssertEqual(vault.creates, 0)
    }

    func testLockDropsTheSessionAndRecordActivityIgnoresALockedSession() async {
        let session = makeSession()
        await session.unlock(reason: "test")
        session.lock()
        XCTAssertEqual(session.state, .locked)
        XCTAssertNil(session.lastActivityAt)
        session.recordActivity()
        XCTAssertNil(session.lastActivityAt)
    }

    func testLockClearsTheFaceStore() async throws {
        let session = makeSession()
        let store = FaceEnrollmentStore(session: session)
        await store.unlock()
        try await store.commitEnrollment(name: "A", samples: [sample([1, 0])])
        XCTAssertEqual(store.identities.count, 1)

        session.lock()
        XCTAssertEqual(store.state, .locked)
        XCTAssertTrue(store.identities.isEmpty, "decrypted faces are dropped on lock")
        do {
            try await store.commitEnrollment(name: "B", samples: [sample([0, 1])])
            XCTFail("a locked store must refuse to write")
        } catch {}

        await store.unlock()
        XCTAssertEqual(authenticator.calls, 2, "unlocking again asks the owner again")
        XCTAssertEqual(store.state, .ready)
        XCTAssertEqual(store.identities.map(\.name), ["A"])
    }

    // MARK: - Password store

    func testPasswordRoundTripsEncryptedWithOwnerOnlyMode() async throws {
        let session = makeSession()
        await session.unlock(reason: "test")
        let passwords = makePasswordStore(session)
        XCTAssertFalse(passwords.hasStoredPassword)

        try await passwords.save("correct horse")
        XCTAssertTrue(passwords.hasStoredPassword)
        XCTAssertEqual(verifier.calls, 1)
        XCTAssertEqual(vault.creates, 1, "the key is created on the first write")

        let raw = try Data(contentsOf: passwords.fileURL)
        XCTAssertNil(raw.range(of: Data("correct horse".utf8)), "the file must not be plaintext")
        let mode = try FileManager.default.attributesOfItem(atPath: passwords.fileURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(Set(leftovers), [FaceUnlockSession.passwordFileName, FaceSessionRecord.fileName],
                       "no temporary file is left behind")

        var bytes = try await passwords.readPassword()
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "correct horse")
        bytes.resetBytes(in: 0..<bytes.count)

        // Answerable from the file alone, with the session locked.
        session.lock()
        XCTAssertTrue(makePasswordStore(makeSession()).hasStoredPassword)

        // A fresh session reads the same key back and decrypts.
        let next = makeSession()
        await next.unlock(reason: "test")
        let again = try await makePasswordStore(next).readPassword()
        XCTAssertEqual(again, Data("correct horse".utf8))
        XCTAssertEqual(vault.creates, 1)
    }

    func testWrongPasswordIsRejectedAndNotStored() async {
        let session = makeSession()
        await session.unlock(reason: "test")
        let passwords = makePasswordStore(session)
        do {
            try await passwords.save("wrong")
            XCTFail("a password macOS rejects must not be stored")
        } catch {
            XCTAssertEqual(error as? FacePasswordError, .wrongPassword)
            XCTAssertTrue(error.localizedDescription.contains("not saved"))
        }
        XCTAssertFalse(passwords.hasStoredPassword)
        XCTAssertFalse(FileManager.default.fileExists(atPath: passwords.fileURL.path))
        XCTAssertEqual(vault.creates, 0, "no key is created for a rejected password")
    }

    func testUnverifiablePasswordIsNotStored() async {
        verifier.error = NSError(domain: "test", code: 1)
        let session = makeSession()
        await session.unlock(reason: "test")
        let passwords = makePasswordStore(session)
        do {
            try await passwords.save("correct horse")
            XCTFail("a password that could not be checked must not be stored")
        } catch {
            guard case .verificationUnavailable = error as? FacePasswordError else {
                return XCTFail("unexpected error \(error)")
            }
        }
        XCTAssertFalse(passwords.hasStoredPassword)
    }

    func testEmptyPasswordIsRejectedBeforeAnyCheck() async {
        let session = makeSession()
        await session.unlock(reason: "test")
        let passwords = makePasswordStore(session)
        do {
            try await passwords.save("")
            XCTFail("empty password accepted")
        } catch {
            XCTAssertEqual(error as? FacePasswordError, .emptyPassword)
        }
        XCTAssertEqual(verifier.calls, 0)
        XCTAssertFalse(passwords.hasStoredPassword)
    }

    func testSaveAndReadWhileLockedThrow() async throws {
        let session = makeSession()
        await session.unlock(reason: "test")
        let passwords = makePasswordStore(session)
        try await passwords.save("correct horse")
        session.lock()

        do {
            _ = try await passwords.readPassword()
            XCTFail("read while locked")
        } catch {
            XCTAssertEqual(error as? FacePasswordError, .sessionLocked)
        }
        do {
            try await passwords.save("correct horse")
            XCTFail("save while locked")
        } catch {
            XCTAssertEqual(error as? FacePasswordError, .sessionLocked)
        }
        XCTAssertEqual(verifier.calls, 1, "a locked session never reaches the verifier")
    }

    func testReadRecordsActivityOnlyOnSuccess() async throws {
        let session = makeSession()
        await session.unlock(reason: "test")
        let passwords = makePasswordStore(session)
        try await passwords.save("correct horse")
        let unlockedAt = clock.now

        clock.advance(by: 3 * day)
        _ = try await passwords.readPassword()
        XCTAssertEqual(session.lastActivityAt, unlockedAt.addingTimeInterval(3 * day))

        // Corrupt the file: the failed read must not extend the idle window.
        try Data(repeating: 7, count: 64).write(to: passwords.fileURL)
        clock.advance(by: day)
        do {
            _ = try await passwords.readPassword()
            XCTFail("a corrupt file decrypted")
        } catch {
            XCTAssertEqual(error as? FacePasswordError, .decryptionFailed)
        }
        XCTAssertEqual(session.lastActivityAt, unlockedAt.addingTimeInterval(3 * day))
    }

    func testDeleteRemovesTheFile() async throws {
        let session = makeSession()
        await session.unlock(reason: "test")
        let passwords = makePasswordStore(session)
        try await passwords.save("correct horse")
        try passwords.delete()
        XCTAssertFalse(passwords.hasStoredPassword)
        XCTAssertFalse(FileManager.default.fileExists(atPath: passwords.fileURL.path))
        do {
            _ = try await passwords.readPassword()
            XCTFail("read after delete")
        } catch {
            XCTAssertEqual(error as? FacePasswordError, .noStoredPassword)
        }
    }

    // MARK: - Auto-lock maths

    func testAutoLockDeadlineMaths() {
        let start = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(AutoLockInterval.sevenDays.deadline(after: start), start.addingTimeInterval(7 * day))
        XCTAssertEqual(AutoLockInterval.fourteenDays.deadline(after: start), start.addingTimeInterval(14 * day))
        XCTAssertEqual(AutoLockInterval.thirtyDays.deadline(after: start), start.addingTimeInterval(30 * day))
        XCTAssertNil(AutoLockInterval.never.deadline(after: start), "never has no deadline")
        XCTAssertNil(AutoLockInterval.sevenDays.deadline(after: nil), "a locked session has nothing to age")

        let deadline = start.addingTimeInterval(7 * day)
        XCTAssertFalse(AutoLockInterval.sevenDays.shouldLock(lastActivityAt: start, now: deadline.addingTimeInterval(-1)))
        XCTAssertTrue(AutoLockInterval.sevenDays.shouldLock(lastActivityAt: start, now: deadline))
        XCTAssertFalse(AutoLockInterval.never.shouldLock(lastActivityAt: start, now: start.addingTimeInterval(10_000 * day)))
        XCTAssertFalse(AutoLockInterval.sevenDays.shouldLock(lastActivityAt: nil, now: deadline))
        XCTAssertFalse(AutoLockInterval.sevenDays.shouldLock(lastActivityAt: start, now: start.addingTimeInterval(-day)),
                       "a clock set backwards does not lock")
        XCTAssertEqual(AutoLockInterval.default, .thirtyDays)
    }

    // MARK: - Auto-locker

    /// Lets the observation hop (`onChange` → main-actor task) run.
    private func settle(until condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { await Task.yield() }
    }

    func testLockerSchedulesOneDeadlineAndFollowsActivityIntervalAndLock() async {
        let interval = IntervalBox(.sevenDays)
        let session = makeSession()
        let locker = FaceSessionAutoLocker(session: session) { interval.value }
        XCTAssertNil(locker.scheduledDeadline, "no timer while locked")

        await session.unlock(reason: "test")
        let start = clock.now
        await settle { locker.scheduledDeadline != nil }
        XCTAssertEqual(locker.scheduledDeadline, start.addingTimeInterval(7 * day))

        clock.advance(by: day)
        session.recordActivity()
        await settle { locker.scheduledDeadline == start.addingTimeInterval(8 * day) }
        XCTAssertEqual(locker.scheduledDeadline, start.addingTimeInterval(8 * day), "activity pushes the deadline")

        interval.value = .fourteenDays
        await settle { locker.scheduledDeadline == start.addingTimeInterval(15 * day) }
        XCTAssertEqual(locker.scheduledDeadline, start.addingTimeInterval(15 * day), "an interval change reschedules")

        interval.value = .never
        await settle { locker.scheduledDeadline == nil }
        XCTAssertNil(locker.scheduledDeadline, "never means no timer")
        XCTAssertEqual(session.state, .unlocked)

        interval.value = .sevenDays
        await settle { locker.scheduledDeadline != nil }
        session.lock()
        await settle { locker.scheduledDeadline == nil }
        XCTAssertNil(locker.scheduledDeadline, "lock cancels the timer")
    }

    func testWakeReevaluatesAgainstTheWallClock() async {
        let interval = IntervalBox(.sevenDays)
        let session = makeSession()
        let locker = FaceSessionAutoLocker(session: session) { interval.value }
        await session.unlock(reason: "test")
        let start = clock.now

        // Woken before the deadline: stays unlocked, deadline unchanged.
        clock.advance(by: 6 * day)
        locker.evaluate(reason: "wake")
        XCTAssertEqual(session.state, .unlocked)
        XCTAssertEqual(locker.scheduledDeadline, start.addingTimeInterval(7 * day))

        // Slept through it: no timer fired, but the wake check locks.
        clock.advance(by: 2 * day)
        locker.evaluate(reason: "wake")
        XCTAssertEqual(session.state, .locked)
        XCTAssertNil(locker.scheduledDeadline)
    }

    func testWakeNeverLocksOnNever() async {
        let interval = IntervalBox(.never)
        let session = makeSession()
        let locker = FaceSessionAutoLocker(session: session) { interval.value }
        await session.unlock(reason: "test")
        clock.advance(by: 1_000 * day)
        locker.evaluate(reason: "wake")
        XCTAssertEqual(session.state, .unlocked)
        XCTAssertNil(locker.scheduledDeadline)
    }

    func testWakeReArmsTheTimerWithTheWallClockTimeLeft() async {
        let interval = IntervalBox(.sevenDays)
        let session = makeSession()
        let locker = FaceSessionAutoLocker(session: session) { interval.value }
        await session.unlock(reason: "test")
        let deadline = clock.now.addingTimeInterval(7 * day)
        await settle { locker.scheduledDeadline != nil }
        XCTAssertEqual(locker.scheduledDelay, 7 * day)
        let armed = locker.armCount

        // Asleep for three days: the armed timer's own countdown did not move.
        clock.advance(by: 3 * day)
        locker.evaluate(reason: "wake")
        XCTAssertEqual(session.state, .unlocked)
        XCTAssertEqual(locker.armCount, armed + 1, "the stale timer is replaced, not kept")
        XCTAssertEqual(locker.scheduledDeadline, deadline)
        XCTAssertEqual(locker.scheduledDelay, deadline.timeIntervalSince(clock.now))
        XCTAssertEqual(locker.scheduledDelay, 4 * day)
    }

    // MARK: - File modes

    func testSavedFilesAreOwnerOnlyInAnOwnerOnlyDirectory() async throws {
        let session = makeSession()
        await session.unlock(reason: "test")
        let store = FaceEnrollmentStore(session: session)
        await store.unlock()
        try await store.commitEnrollment(name: "A", samples: [sample([1, 0])])
        let passwords = makePasswordStore(session)
        try await passwords.save("correct horse")

        func mode(_ path: String) throws -> Int? {
            try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        }
        XCTAssertEqual(try mode(directory.path), 0o700)
        XCTAssertEqual(try mode(store.fileURL.path), 0o600)
        XCTAssertEqual(try mode(passwords.fileURL.path), 0o600)

        // A rewrite replaces the file and keeps the mode.
        try await passwords.save("correct horse")
        try store.setEnabled(false, for: store.identities[0].id)
        XCTAssertEqual(try mode(store.fileURL.path), 0o600)
        XCTAssertEqual(try mode(passwords.fileURL.path), 0o600)
        XCTAssertEqual(try mode(session.sessionRecordURL.path), 0o600, "the restart record too")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(Set(leftovers), [FaceUnlockSession.faceIdentitiesFileName, FaceUnlockSession.passwordFileName,
                                        FaceSessionRecord.fileName],
                       "no temporary file is left behind")
    }

    // MARK: - Lock during a prompt

    /// Real clock waits: the prompt may be answered off the main actor.
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<1_000 where !condition() { try? await Task.sleep(for: .milliseconds(2)) }
    }

    func testLockDuringTheUnlockPromptCancelsItAndStaysLocked() async {
        let prompt = SuspendingOwnerAuthenticator()
        let clock = self.clock!
        let session = FaceUnlockSession(vault: vault, authenticator: prompt, directory: directory, now: { clock.now })
        let unlocking = Task { await session.unlock(reason: "test") }
        await waitUntil { prompt.isWaiting }
        XCTAssertTrue(prompt.isWaiting)
        XCTAssertEqual(session.state, .unlocking)

        session.lock()
        await waitUntil { prompt.wasCancelled }
        XCTAssertTrue(prompt.wasCancelled, "locking takes the prompt down")

        prompt.resume()
        let verified = await unlocking.value
        XCTAssertFalse(verified)
        XCTAssertEqual(session.state, .locked, "an answer that lands after the lock is void")
        XCTAssertNil(session.lastActivityAt)
        XCTAssertNil(session.lastError)
        do {
            _ = try await session.key(creatingIfNeeded: true)
            XCTFail("a locked session must not hand out a key")
        } catch {
            XCTAssertEqual(error as? FaceUnlockSessionError, .locked)
        }
        XCTAssertEqual(vault.creates, 0)
    }

    func testLockDuringAnOwnerCheckVoidsIt() async {
        let prompt = SuspendingOwnerAuthenticator()
        let session = FaceUnlockSession(vault: vault, authenticator: prompt, directory: directory)
        let checking = Task { await session.verifyOwner(reason: "test") }
        await waitUntil { prompt.isWaiting }
        session.lock()
        await waitUntil { prompt.wasCancelled }
        XCTAssertTrue(prompt.wasCancelled)
        prompt.resume()
        let verified = await checking.value
        XCTAssertFalse(verified)
    }

    // MARK: - Owner check without the key

    func testVerifyOwnerSkipsThePromptWhenVerifiedAndFailsWhenRefused() async {
        let session = makeSession()
        await session.unlock(reason: "test")
        let verified = await session.verifyOwner(reason: "test")
        XCTAssertTrue(verified)
        XCTAssertEqual(authenticator.calls, 1, "a verified session does not prompt again")

        session.lock()
        authenticator.error = LAError(.userCancel)
        let refused = await session.verifyOwner(reason: "test")
        XCTAssertFalse(refused)
        XCTAssertEqual(session.state, .locked)
    }

    func testUnreadableKeyStillLetsTheOwnerDeleteEverything() async throws {
        let writer = makeSession()
        await writer.unlock(reason: "test")
        let writerStore = FaceEnrollmentStore(session: writer)
        await writerStore.unlock()
        try await writerStore.commitEnrollment(name: "A", samples: [sample([1, 0])])
        try await makePasswordStore(writer).save("correct horse")

        vault.readError = FaceKeyVaultError.keychain(errSecDecode)
        let session = makeSession()
        let store = FaceEnrollmentStore(session: session)
        let passwords = makePasswordStore(session)
        await store.unlock()
        XCTAssertEqual(session.state, .locked)
        XCTAssertTrue(session.keyReadFailed)
        XCTAssertNotNil(session.lastError)

        let calls = authenticator.calls
        let verified = await session.verifyOwner(reason: "test")
        XCTAssertTrue(verified)
        XCTAssertEqual(authenticator.calls, calls + 1, "a locked session asks the owner")
        XCTAssertEqual(session.state, .locked, "the owner check alone unlocks nothing")

        store.deleteAll()
        XCTAssertFalse(store.fileExists)
        XCTAssertTrue(session.keyReadFailed, "the password still needs the unreadable key")
        try passwords.delete()
        XCTAssertFalse(session.keyReadFailed)
        XCTAssertNil(session.lastError)
        XCTAssertFalse(session.hasEncryptedData)
        XCTAssertEqual(vault.creates, 1, "no key is minted over unreadable data")
    }

    // MARK: - Activity

    func testSuccessfulWritesCountAsActivity() async throws {
        let session = makeSession()
        await session.unlock(reason: "test")
        let store = FaceEnrollmentStore(session: session)
        await store.unlock()
        let passwords = makePasswordStore(session)

        clock.advance(by: day)
        let face = try await store.commitEnrollment(name: "A", samples: [sample([1, 0])])
        XCTAssertEqual(session.lastActivityAt, clock.now, "an enrolment")
        clock.advance(by: day)
        try store.setEnabled(false, for: face.id)
        XCTAssertEqual(session.lastActivityAt, clock.now, "a toggle")
        clock.advance(by: day)
        try await passwords.save("correct horse")
        XCTAssertEqual(session.lastActivityAt, clock.now, "a password save")
        clock.advance(by: day)
        try passwords.delete()
        XCTAssertEqual(session.lastActivityAt, clock.now, "a password delete")
        clock.advance(by: day)
        try store.delete(face.id)
        XCTAssertEqual(session.lastActivityAt, clock.now, "a face delete")

        // A failed write is not use.
        let before = clock.now
        clock.advance(by: day)
        do {
            try await passwords.save("wrong")
            XCTFail("a wrong password was stored")
        } catch {}
        XCTAssertEqual(session.lastActivityAt, before)
    }
}

// MARK: - Fakes

@MainActor
final class FaceTestClock {
    var now: Date
    init(_ now: Date) { self.now = now }
    func advance(by interval: TimeInterval) { now = now.addingTimeInterval(interval) }
}

@Observable
@MainActor
final class IntervalBox {
    var value: AutoLockInterval
    init(_ value: AutoLockInterval) { self.value = value }
}

/// Stands in for LocalAuthentication: passes unless `error` is set.
nonisolated final class FakeOwnerAuthenticator: OwnerAuthenticator, @unchecked Sendable {
    private let lock = NSLock()
    private var _error: Error?
    private var _calls = 0
    private var _reasons: [String] = []

    var error: Error? {
        get { lock.withLock { _error } }
        set { lock.withLock { _error = newValue } }
    }
    var calls: Int { lock.withLock { _calls } }
    /// The reason each prompt was shown with, in order.
    var reasons: [String] { lock.withLock { _reasons } }

    func authenticate(reason: String) async throws {
        let error = lock.withLock { () -> Error? in
            _calls += 1
            _reasons.append(reason)
            return _error
        }
        if let error { throw error }
    }
}

/// An owner-check prompt that stays up until `resume` is called. Records
/// task cancellation but, like a prompt that ignores it, does not end on it.
nonisolated final class SuspendingOwnerAuthenticator: OwnerAuthenticator, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var _cancelled = false

    var isWaiting: Bool { lock.withLock { continuation != nil } }
    var wasCancelled: Bool { lock.withLock { _cancelled } }

    func authenticate(reason: String) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock { self.continuation = continuation }
            }
        } onCancel: {
            lock.withLock { _cancelled = true }
        }
    }

    func resume() {
        let pending = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume()
    }
}

/// Stands in for OpenDirectory: one correct password.
nonisolated final class FakePasswordVerifier: PasswordVerifier, @unchecked Sendable {
    private let lock = NSLock()
    private let correct: String
    private var _error: Error?
    private var _calls = 0

    init(correct: String) { self.correct = correct }

    var error: Error? {
        get { lock.withLock { _error } }
        set { lock.withLock { _error = newValue } }
    }
    var calls: Int { lock.withLock { _calls } }

    func verify(password: String) throws -> Bool {
        try lock.withLock {
            _calls += 1
            if let error = _error { throw error }
            return password == correct
        }
    }
}
