import XCTest
import LocalAuthentication
import CryptoKit
@testable import PopNotch

/// "Ask once after login": at most one owner check per launch, never while
/// the screen is locked (or its state is unknown), deferred until the first
/// unlock, and not at all when the feature is off or no password is stored.
@MainActor
final class FaceUnlockLoginPromptTests: XCTestCase {

    private var directory: URL!
    private var authenticator: FakeOwnerAuthenticator!
    private var session: FaceUnlockSession!
    private var lockGuard: FakeLockGuard!
    private var clock: FakeFaceUnlockClock!
    private var enabled = true
    private var hasPassword = true

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appending(path: "PopNotchFaceLoginPromptTests-\(UUID().uuidString)")
        authenticator = FakeOwnerAuthenticator()
        session = FaceUnlockSession(vault: MemoryKeyVault(), authenticator: authenticator, directory: directory)
        lockGuard = FakeLockGuard(.unlocked)
        clock = FakeFaceUnlockClock()
        enabled = true
        hasPassword = true
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func makePrompt(authenticatedBy session: FaceUnlockSession? = nil) -> FaceUnlockLoginPrompt {
        FaceUnlockLoginPrompt(session: session ?? self.session, lockGuard: lockGuard, clock: clock,
                              isEnabled: { [unowned self] in self.enabled },
                              autoLockInterval: { .sevenDays },
                              hasStoredPassword: { [unowned self] in self.hasPassword })
    }

    private func run(_ prompt: FaceUnlockLoginPrompt) async {
        await prompt.waitUntilSettled()
        for _ in 0..<5 { await Task.yield() }
        await prompt.waitUntilSettled()
    }

    func testPromptsOnceAfterTheLaunchDelay() async {
        let prompt = makePrompt()
        prompt.schedule()
        await run(prompt)
        XCTAssertEqual(authenticator.calls, 1)
        XCTAssertEqual(clock.sleeps.first, FaceUnlockLoginPrompt.launchDelay)
        XCTAssertEqual(session.state, .unlocked)
        XCTAssertEqual(prompt.phase, .done)

        session.lock()
        prompt.schedule()
        prompt.screenDidUnlock()
        await run(prompt)
        XCTAssertEqual(authenticator.calls, 1, "never twice in one launch")
    }

    func testNoPromptWhenDisabled() async {
        enabled = false
        let prompt = makePrompt()
        prompt.schedule()
        await run(prompt)
        XCTAssertEqual(authenticator.calls, 0)
        XCTAssertEqual(prompt.phase, .done)
    }

    func testNoPromptWithoutAStoredPassword() async {
        hasPassword = false
        let prompt = makePrompt()
        prompt.schedule()
        await run(prompt)
        XCTAssertEqual(authenticator.calls, 0)
        prompt.screenDidUnlock()
        await run(prompt)
        XCTAssertEqual(authenticator.calls, 0)
    }

    func testNoPromptWhenTheSessionIsAlreadyUnlocked() async {
        await session.unlock(reason: "earlier")
        let prompt = makePrompt()
        prompt.schedule()
        await run(prompt)
        XCTAssertEqual(authenticator.calls, 1, "only the earlier unlock")
    }

    func testLockedScreenDefersThePromptUntilTheFirstUnlock() async {
        lockGuard.state = .locked
        let prompt = makePrompt()
        prompt.schedule()
        await run(prompt)
        XCTAssertEqual(authenticator.calls, 0, "never at the lock screen")
        XCTAssertEqual(prompt.phase, .deferredUntilUnlock)

        // An unlock notification that the session server does not confirm.
        prompt.screenDidUnlock()
        await run(prompt)
        XCTAssertEqual(authenticator.calls, 0)

        lockGuard.state = .unlocked
        prompt.screenDidUnlock()
        await run(prompt)
        XCTAssertEqual(authenticator.calls, 1)

        session.lock()
        prompt.screenDidUnlock()
        await run(prompt)
        XCTAssertEqual(authenticator.calls, 1, "still once")
    }

    func testUnknownLockStateNeverPrompts() async {
        lockGuard.state = .unknown
        let prompt = makePrompt()
        prompt.schedule()
        prompt.screenDidUnlock()
        await run(prompt)
        XCTAssertEqual(authenticator.calls, 0)
        XCTAssertEqual(prompt.phase, .deferredUntilUnlock)
    }

    func testACancelledPromptIsNotRepeated() async {
        authenticator.error = LAError(.userCancel)
        let prompt = makePrompt()
        prompt.schedule()
        await run(prompt)
        XCTAssertEqual(authenticator.calls, 1)
        XCTAssertEqual(session.state, .locked, "stays locked; Settings is the way on")
        prompt.screenDidUnlock()
        prompt.schedule()
        await run(prompt)
        XCTAssertEqual(authenticator.calls, 1)
    }

    private var recordURL: URL { directory.appending(path: FaceSessionRecord.fileName) }

    /// A record from an earlier run whose restore failed only because the
    /// key could not be read: the restore contract keeps it for a later
    /// launch (`RestoreOutcome.keyUnavailable`).
    private func makeSessionWithAKeptRecord(_ authenticator: any OwnerAuthenticator) throws -> FaceUnlockSession {
        try FaceFileWriter.replace(directory.appending(path: FaceUnlockSession.passwordFileName), with: Data(repeating: 1, count: 64))
        try FaceSessionRecord(lastActivityAt: Date(), key: SymmetricKey(size: .bits256), epoch: 0).write(to: recordURL)
        let vault = MemoryKeyVault(key: SymmetricKey(size: .bits256))
        vault.readError = FaceKeyVaultError.keychain(errSecAuthFailed)
        return FaceUnlockSession(vault: vault, authenticator: authenticator, directory: directory)
    }

    func testLockingTheScreenTakesThePromptDown() async throws {
        let suspending = SuspendingOwnerAuthenticator()
        let session = try makeSessionWithAKeptRecord(suspending)
        let prompt = makePrompt(authenticatedBy: session)
        prompt.schedule()
        for _ in 0..<50 where !suspending.isWaiting { await Task.yield() }
        XCTAssertTrue(suspending.isWaiting)
        XCTAssertEqual(prompt.phase, .prompting)

        prompt.screenDidLock()
        XCTAssertTrue(suspending.wasCancelled)
        XCTAssertEqual(session.state, .locked)
        XCTAssertEqual(prompt.phase, .deferredUntilUnlock, "held back, not done")
        suspending.resume()
        await run(prompt)
        XCTAssertEqual(session.state, .locked, "a late answer does not unlock")
        XCTAssertEqual(prompt.phase, .deferredUntilUnlock, "the stale prompt task cannot mark the login done")
        XCTAssertTrue(FileManager.default.fileExists(atPath: recordURL.path),
                      "withdrawn, not locked: the record a later launch restores from is kept")
    }

    /// The prompt the screen lock took down is asked again after the next
    /// unlock, and answering it then unlocks.
    func testAPromptTakenDownByALockIsAskedAgainAfterTheNextUnlock() async {
        let first = SuspendingOwnerAuthenticator()
        let session = FaceUnlockSession(vault: MemoryKeyVault(), authenticator: first, directory: directory)
        let prompt = makePrompt(authenticatedBy: session)
        prompt.schedule()
        for _ in 0..<50 where !first.isWaiting { await Task.yield() }
        lockGuard.state = .locked
        prompt.screenDidLock()
        first.resume()
        await run(prompt)
        XCTAssertEqual(prompt.phase, .deferredUntilUnlock)

        // Not while the session server still says locked.
        prompt.screenDidUnlock()
        await run(prompt)
        XCTAssertEqual(prompt.phase, .deferredUntilUnlock)
        XCTAssertFalse(first.isWaiting)

        lockGuard.state = .unlocked
        prompt.screenDidUnlock()
        for _ in 0..<50 where !first.isWaiting { await Task.yield() }
        XCTAssertTrue(first.isWaiting, "asked again")
        XCTAssertEqual(prompt.phase, .prompting)
        first.resume()
        await run(prompt)
        XCTAssertEqual(session.state, .unlocked)
        XCTAssertEqual(prompt.phase, .done)
    }

    /// An unknown answer is asked once more after a short wait: here the
    /// session server has caught up by then, so the prompt shows.
    func testAnUnknownLockStateIsCheckedOnceMore() async {
        lockGuard.state = .unknown
        let lockGuard = self.lockGuard!
        clock.onSleep = { seconds in
            if seconds == FaceUnlockLoginPrompt.unknownStateRecheckDelay { lockGuard.state = .unlocked }
        }
        let prompt = makePrompt()
        prompt.schedule()
        await run(prompt)
        XCTAssertEqual(clock.sleeps, [FaceUnlockLoginPrompt.launchDelay, FaceUnlockLoginPrompt.unknownStateRecheckDelay])
        XCTAssertEqual(authenticator.calls, 1)
        XCTAssertEqual(prompt.phase, .done)
    }

    /// Still unknown on the recheck: no third look, no prompt; the next
    /// unlock event decides.
    func testAnUnknownLockStateIsRecheckedOnlyOnce() async {
        lockGuard.state = .unknown
        let prompt = makePrompt()
        prompt.schedule()
        await run(prompt)
        XCTAssertEqual(clock.sleeps, [FaceUnlockLoginPrompt.launchDelay, FaceUnlockLoginPrompt.unknownStateRecheckDelay],
                       "one recheck, then it gives up")
        XCTAssertEqual(authenticator.calls, 0)
        XCTAssertEqual(prompt.phase, .deferredUntilUnlock)

        lockGuard.state = .unlocked
        prompt.screenDidUnlock()
        await run(prompt)
        XCTAssertEqual(authenticator.calls, 1)
    }

    /// The screen locks after the "unlocked" check but before the prompt's
    /// task runs: the task checks again and does not show it.
    func testAScreenThatLocksBeforeThePromptRunsDefersIt() async {
        let prompt = makePrompt()
        lockGuard.state = .locked
        prompt.schedule()
        await run(prompt)
        XCTAssertEqual(prompt.phase, .deferredUntilUnlock)

        lockGuard.state = .unlocked
        lockGuard.flip(to: .locked, afterChecks: 1) // the check in evaluate passes, then locked
        prompt.screenDidUnlock()
        XCTAssertEqual(prompt.phase, .prompting)
        await run(prompt)
        XCTAssertEqual(authenticator.calls, 0, "never at the lock screen")
        XCTAssertEqual(prompt.phase, .deferredUntilUnlock)

        lockGuard.state = .unlocked
        prompt.screenDidUnlock()
        await run(prompt)
        XCTAssertEqual(authenticator.calls, 1, "shown at the next unlock")
    }

    /// The lock notification lands before the session server catches up, and
    /// before the prompt's task has started: the prompt is held back.
    func testLockingBeforeThePromptStartsHoldsItBack() async {
        let prompt = makePrompt()
        lockGuard.state = .locked
        prompt.schedule()
        await run(prompt)

        lockGuard.state = .unlocked
        prompt.screenDidUnlock() // the prompt's task is created, not yet run
        prompt.screenDidLock()
        XCTAssertEqual(prompt.phase, .deferredUntilUnlock)
        await run(prompt)
        XCTAssertEqual(authenticator.calls, 0)
        XCTAssertEqual(session.state, .locked)

        prompt.screenDidUnlock()
        await run(prompt)
        XCTAssertEqual(authenticator.calls, 1, "shown at the next unlock")
        XCTAssertEqual(prompt.phase, .done)
    }
}
