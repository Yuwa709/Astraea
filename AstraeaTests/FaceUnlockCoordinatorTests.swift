import XCTest
import LocalAuthentication
@testable import Astraea

/// Face Unlock, phase 3: the lock-screen state machine. Real session and
/// stores over a temporary directory, a memory key vault and a fake owner
/// check; fake lock screen, camera, model, keyboard and clock. Nothing here
/// touches the real Keychain, LocalAuthentication, camera or keyboard.
@MainActor
final class FaceUnlockCoordinatorTests: XCTestCase {

    private let password = "correct horse"
    private let enrolled: [Float] = [1, 0, 0, 0]
    private let stranger: [Float] = [0, 1, 0, 0]

    private var directory: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var vault: MemoryKeyVault!
    private var authenticator: FakeOwnerAuthenticator!
    private var session: FaceUnlockSession!
    private var faceStore: FaceEnrollmentStore!
    private var passwordStore: FacePasswordStore!
    private var settings: SettingsStore!

    private var lockGuard: FakeLockGuard!
    private var events: FakeLockEvents!
    private var accessibility: FakeAccessibility!
    private var permissions: FakePermissions!
    private var camera: FakeFrameSource!
    private var recognizer: FakeRecognizer!
    private var livenessSampler: FakeLivenessSampler!
    private var typer: FakeTyper!
    private var clock: FakeFaceUnlockClock!

    /// Owner checks and keychain reads made during setup; nothing at the
    /// lock screen may add to them.
    private var authCallsAfterSetup = 0
    private var vaultReadsAfterSetup = 0

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appending(path: "AstraeaFaceCoordinatorTests-\(UUID().uuidString)")
        suiteName = "com.techie.Astraea.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        vault = MemoryKeyVault()
        authenticator = FakeOwnerAuthenticator()
        session = FaceUnlockSession(vault: vault, authenticator: authenticator, directory: directory)
        faceStore = FaceEnrollmentStore(session: session)
        passwordStore = FacePasswordStore(session: session, verifier: FakePasswordVerifier(correct: password))
        settings = SettingsStore(defaults: defaults)

        lockGuard = FakeLockGuard(.unlocked)
        events = FakeLockEvents()
        accessibility = FakeAccessibility()
        permissions = FakePermissions()
        camera = FakeFrameSource()
        let enrolled = self.enrolled
        recognizer = FakeRecognizer { _ in enrolled }
        livenessSampler = FakeLivenessSampler()
        typer = FakeTyper()
        clock = FakeFaceUnlockClock()

        // The owner sets everything up while the screen is unlocked.
        await session.unlock(reason: "test")
        try await passwordStore.save(password)
        await faceStore.unlock()
        try await faceStore.commitEnrollment(name: "Owner", samples: [sample(enrolled)])
        settings.update {
            $0.faceUnlockAtLockScreenEnabled = true
            // The state machine's tests pin liveness off, which must behave
            // exactly as before phase 4: a single match types. The liveness
            // tests at the end of the file turn it on.
            $0.faceUnlockLiveness = .off
        }
        authCallsAfterSetup = authenticator.calls
        vaultReadsAfterSetup = vault.reads
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    private func sample(_ embedding: [Float]) -> FaceSample {
        FaceSample(embedding: embedding, pose: "center", capturedAt: Date(timeIntervalSince1970: 0), quality: 0.6)
    }

    /// `makeRecognizer` replaces the default factory, which hands out
    /// `recognizer`.
    private func makeCoordinator(faceStore: FaceEnrollmentStore? = nil,
                                 makeRecognizer: (@Sendable () throws -> any FaceScanRecognizing)? = nil,
                                 settled: Bool = true) async -> FaceUnlockCoordinator {
        let permissions = self.permissions!, camera = self.camera!
        let recognizer = self.recognizer!
        let environment = FaceUnlockEnvironment(
            lockGuard: lockGuard, lockEvents: events,
            accessibility: accessibility,
            cameraPermission: { permissions.camera },
            requestCameraAccess: { await permissions.requestCamera() },
            openCameraSettings: { permissions.openCameraSettings() },
            makeFrameSource: { camera },
            makeRecognizer: makeRecognizer ?? { recognizer.noteCreated(); return recognizer },
            livenessSampler: livenessSampler,
            typer: typer, clock: clock)
        let coordinator = FaceUnlockCoordinator(settings: settings, session: session,
                                                faceStore: faceStore ?? self.faceStore,
                                                passwordStore: passwordStore, environment: environment)
        if settled { await settle(coordinator) }
        return coordinator
    }

    /// Polls in real time, for tests that hold a task open and so cannot
    /// wait for idle. false on timeout.
    private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    /// Locks and wakes without waiting for the scan and check to finish.
    private func lockAndWakeWithoutWaiting() {
        lockGuard.state = .locked
        events.send(.screenLocked)
        clock.advance(by: 3)
        events.send(.wake)
    }

    /// One lock session in which the typed password is rejected, then an
    /// unlock: leaves a rejection count of 1 for a later step to keep or lose.
    private func rejectOnce(_ coordinator: FaceUnlockCoordinator, file: StaticString = #filePath, line: UInt = #line) async {
        await lockAndWake(coordinator)
        XCTAssertEqual(coordinator.consecutiveRejections, 1, file: file, line: line)
        await unlock(coordinator)
    }

    private static let verifySleepLengths: Set<TimeInterval> = [
        FaceUnlockCoordinator.unlockConfirmationWindow,
        FaceUnlockCoordinator.verifyTimeout - FaceUnlockCoordinator.unlockConfirmationWindow,
    ]

    /// Lets observation tasks run, then waits out every pending task.
    private func settle(_ coordinator: FaceUnlockCoordinator) async {
        for _ in 0..<3 {
            for _ in 0..<10 { await Task.yield() }
            await coordinator.waitUntilIdle()
        }
    }

    private func lockAndWake(_ coordinator: FaceUnlockCoordinator) async {
        lockGuard.state = .locked
        events.send(.screenLocked)
        clock.advance(by: 3)
        events.send(.wake)
        await settle(coordinator)
    }

    /// Another wake in the same lock session, after the debounce.
    private func wakeAgain(_ coordinator: FaceUnlockCoordinator) async {
        clock.advance(by: 3)
        events.send(.wake)
        await settle(coordinator)
    }

    private func unlock(_ coordinator: FaceUnlockCoordinator) async {
        lockGuard.state = .unlocked
        events.send(.screenUnlocked)
        await settle(coordinator)
    }

    private func assertNothingPrompted(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(authenticator.calls, authCallsAfterSetup, "no owner check at the lock screen", file: file, line: line)
        XCTAssertEqual(vault.reads, vaultReadsAfterSetup, "no keychain read at the lock screen", file: file, line: line)
        XCTAssertEqual(accessibility.requests, 0, "no Accessibility prompt", file: file, line: line)
        XCTAssertEqual(permissions.cameraRequests, 0, "no camera prompt", file: file, line: line)
        XCTAssertEqual(permissions.cameraSettingsOpens, 0, "System Settings not opened", file: file, line: line)
    }

    // MARK: - The happy path

    func testMatchAtTheLockScreenTypesThePasswordOnceAndVerifies() async {
        let lockGuard = self.lockGuard!
        typer.onType = { lockGuard.state = .unlocked } // macOS accepts it
        let coordinator = await makeCoordinator()
        XCTAssertEqual(coordinator.status, .ready)
        XCTAssertTrue(events.isStarted)

        await lockAndWake(coordinator)

        XCTAssertEqual(typer.calls, 1)
        XCTAssertEqual(typer.typed.first, Array(password.utf8))
        XCTAssertEqual(coordinator.lastOutcome, .unlocked)
        XCTAssertNotNil(coordinator.lastOutcomeAt)
        XCTAssertEqual(coordinator.lastBestSimilarity ?? 0, 1, accuracy: 0.0001)
        XCTAssertEqual(coordinator.lastBestBand, .above, "what Settings shows instead of the score")
        XCTAssertFalse(camera.isRunning, "the camera stops at the end of every cycle")
        XCTAssertEqual(coordinator.consecutiveRejections, 0)
        assertNothingPrompted()
    }

    func testPasswordBytesAreWipedAfterTyping() async {
        let coordinator = await makeCoordinator()
        await lockAndWake(coordinator)
        XCTAssertEqual(typer.calls, 1)
        XCTAssertEqual(typer.typed.first, Array(password.utf8), "the typer saw the real password")
        XCTAssertEqual(typer.buffers.count, 1)
        XCTAssertTrue(typer.buffers.allSatisfy(\.isWiped), "the buffer the typer read is zeroed afterwards")
        _ = coordinator
    }

    func testTheModelIsLoadedPerLockSessionAndReleasedOnUnlock() async {
        let coordinator = await makeCoordinator()
        XCTAssertEqual(recognizer.created, 0, "nothing is loaded until a scan")
        recognizer.script = { _ in nil }
        await lockAndWake(coordinator)
        await wakeAgain(coordinator)
        XCTAssertEqual(camera.startCount, 2, "two scans")
        XCTAssertEqual(recognizer.created, 1, "one model for the whole lock session")
        await unlock(coordinator)
        await lockAndWake(coordinator)
        XCTAssertEqual(recognizer.created, 2, "released on unlock, loaded again next time")
    }

    // MARK: - Triggers

    func testWakeWhenNotLockedDisarmsAndNeverScans() async {
        let coordinator = await makeCoordinator()
        for state in [LockScreenState.unlocked, .unknown] {
            lockGuard.state = state
            clock.advance(by: 3)
            events.send(.wake)
            await settle(coordinator)
        }
        XCTAssertEqual(camera.startCount, 0)
        XCTAssertEqual(typer.calls, 0)
        XCTAssertEqual(coordinator.status, .ready)
    }

    func testSeveralWakeSignalsWithinTwoSecondsAreOneWake() async {
        recognizer.script = { _ in nil }
        let coordinator = await makeCoordinator()
        lockGuard.state = .locked
        events.send(.wake)
        events.send(.wake)
        clock.advance(by: 1)
        events.send(.wake)
        await settle(coordinator)
        XCTAssertEqual(camera.startCount, 1)
        XCTAssertEqual(coordinator.lastOutcome, .scanCapReached)

        clock.advance(by: 3)
        events.send(.wake)
        await settle(coordinator)
        XCTAssertEqual(camera.startCount, 2, "a wake after the window is a new wake")
    }

    func testWakeWhileGoingToSleepIsIgnored() async {
        let coordinator = await makeCoordinator()
        lockGuard.state = .locked
        events.send(.wake)
        events.send(.sleep)
        await settle(coordinator)
        XCTAssertEqual(camera.startCount, 0)
        XCTAssertEqual(typer.calls, 0)
    }

    func testLockingWithTheDisplayOnScans() async {
        let coordinator = await makeCoordinator()
        lockGuard.state = .locked
        events.send(.screenLocked)
        await settle(coordinator)
        XCTAssertEqual(camera.startCount, 1, "entering the lock screen scans without a wake")
        XCTAssertTrue(coordinator.lockSessionActive)
        await unlock(coordinator)
        XCTAssertFalse(coordinator.lockSessionActive)
    }

    func testAWakeDuringAScanStartsNoSecondScan() async {
        let stranger = self.stranger, enrolled = self.enrolled
        recognizer.script = { id in id < 50 ? stranger : enrolled }
        let events = self.events!, clock = self.clock!
        camera.onRead = { reads in
            guard reads == 5 else { return }
            clock.advance(by: 3)
            events.send(.wake)
        }
        let coordinator = await makeCoordinator()
        await lockAndWake(coordinator)
        XCTAssertEqual(camera.startCount, 1, "a wake during a scan starts nothing")
        XCTAssertEqual(typer.calls, 1, "the running scan went on to the match")
        assertNothingPrompted()
    }

    // MARK: - Recognition

    func testAMatchAfterWrongFramesStillUnlocks() async {
        let stranger = self.stranger, enrolled = self.enrolled
        recognizer.script = { id in id < 80 ? stranger : enrolled }
        let coordinator = await makeCoordinator()
        await lockAndWake(coordinator)
        XCTAssertEqual(typer.calls, 1)
    }

    func testTheThresholdSettingIsUsed() async {
        // Cosine similarity 0.74: above balanced (0.72), below strict (0.76).
        let near: [Float] = [0.74, (1 - 0.74 * 0.74).squareRoot(), 0, 0]
        recognizer.script = { _ in near }
        settings.update { $0.faceUnlockMatchThreshold = .strict }
        let coordinator = await makeCoordinator()
        await lockAndWake(coordinator)
        XCTAssertEqual(typer.calls, 0)
        XCTAssertEqual(coordinator.lastOutcome, .scanCapReached)

        settings.update { $0.faceUnlockMatchThreshold = .balanced }
        await wakeAgain(coordinator)
        XCTAssertEqual(typer.calls, 1)
    }

    func testADisabledIdentityNeverMatches() async throws {
        let id = try XCTUnwrap(faceStore.identities.first?.id)
        try faceStore.setEnabled(false, for: id)
        let coordinator = await makeCoordinator()
        XCTAssertEqual(coordinator.status, .noEnrolledFace)
        await lockAndWake(coordinator)
        XCTAssertEqual(camera.startCount, 0)
        XCTAssertEqual(typer.calls, 0)
    }

    // MARK: - Gates: refuse without prompting

    func testLockedSessionPausesWithoutPrompting() async {
        let coordinator = await makeCoordinator()
        session.lock()
        await settle(coordinator)
        XCTAssertEqual(coordinator.status, .sessionLocked)
        XCTAssertEqual(coordinator.status.text, "Face Unlock is paused — unlock it in Settings.")
        await lockAndWake(coordinator)
        XCTAssertEqual(camera.startCount, 0)
        XCTAssertEqual(typer.calls, 0)
        XCTAssertEqual(coordinator.status, .sessionLocked)
        assertNothingPrompted()
    }

    func testNoStoredPasswordRefuses() async throws {
        try passwordStore.delete()
        let coordinator = await makeCoordinator()
        XCTAssertEqual(coordinator.status, .noStoredPassword)
        await lockAndWake(coordinator)
        XCTAssertEqual(camera.startCount, 0)
        assertNothingPrompted()
    }

    func testAccessibilityNotGrantedRefuses() async {
        accessibility.trusted = false
        let coordinator = await makeCoordinator()
        XCTAssertEqual(coordinator.status, .accessibilityNeeded)
        XCTAssertFalse(coordinator.isAccessibilityTrusted)
        await lockAndWake(coordinator)
        XCTAssertEqual(camera.startCount, 0)
        assertNothingPrompted()

        accessibility.trusted = true
        coordinator.refreshPermissions()
        XCTAssertTrue(coordinator.isAccessibilityTrusted)
    }

    func testRequestAccessibilityIsTheOnlyPrompt() async {
        let coordinator = await makeCoordinator()
        coordinator.requestAccessibility()
        XCTAssertEqual(accessibility.requests, 1)
    }

    func testCameraGrantActionPerPermission() {
        XCTAssertEqual(CameraPermission.notDetermined.grantAction, .request)
        XCTAssertEqual(CameraPermission.denied.grantAction, .openSystemSettings)
        XCTAssertEqual(CameraPermission.restricted.grantAction, .openSystemSettings)
        XCTAssertNil(CameraPermission.granted.grantAction)
    }

    func testRequestCameraAccessPromptsWhenNotYetAskedAndRefreshes() async {
        permissions.camera = .notDetermined
        let coordinator = await makeCoordinator()
        XCTAssertEqual(coordinator.status, .cameraNotYetRequested)
        await coordinator.requestCameraAccess()
        XCTAssertEqual(permissions.cameraRequests, 1)
        XCTAssertEqual(permissions.cameraSettingsOpens, 0)
        XCTAssertEqual(coordinator.cameraPermission, .granted)
        XCTAssertEqual(coordinator.status, .ready)
    }

    func testRequestCameraAccessRefusedShowsDenied() async {
        permissions.camera = .notDetermined
        permissions.cameraAnswer = .denied
        let coordinator = await makeCoordinator()
        await coordinator.requestCameraAccess()
        XCTAssertEqual(coordinator.cameraPermission, .denied)
        XCTAssertEqual(coordinator.status, .cameraNotAuthorized)
    }

    func testRequestCameraAccessAfterRefusalOpensSystemSettingsOnly() async {
        for permission in [CameraPermission.denied, .restricted] {
            permissions.camera = permission
            let coordinator = await makeCoordinator()
            await coordinator.requestCameraAccess()
            XCTAssertEqual(coordinator.cameraPermission, permission)
        }
        XCTAssertEqual(permissions.cameraRequests, 0, "a refusal is never asked again")
        XCTAssertEqual(permissions.cameraSettingsOpens, 2)
    }

    func testRequestCameraAccessWhenGrantedDoesNothing() async {
        let coordinator = await makeCoordinator()
        await coordinator.requestCameraAccess()
        assertNothingPrompted()
    }

    func testCameraNotAuthorizedRefusesAndNeverRequests() async {
        let expected: [(CameraPermission, FaceUnlockStatus)] = [
            (.notDetermined, .cameraNotYetRequested), (.denied, .cameraNotAuthorized), (.restricted, .cameraNotAuthorized),
        ]
        for (permission, status) in expected {
            permissions.camera = permission
            let coordinator = await makeCoordinator()
            XCTAssertEqual(coordinator.status, status)
            await lockAndWake(coordinator)
            XCTAssertEqual(camera.startCount, 0, "FaceCamera.start() would request access")
            await unlock(coordinator)
        }
        assertNothingPrompted()
    }

    func testDisabledDoesNothing() async {
        settings.update { $0.faceUnlockAtLockScreenEnabled = false }
        let coordinator = await makeCoordinator()
        XCTAssertEqual(coordinator.status, .disabled)
        XCTAssertFalse(events.isStarted, "no lock observers while off")
        events.onEvent?(.wake)
        await settle(coordinator)
        XCTAssertEqual(camera.startCount, 0)
        XCTAssertEqual(recognizer.created, 0)
    }

    /// The faces load as soon as the session is unlocked, from the key
    /// already in memory, so the lock screen never needs the keychain.
    func testFacesPreloadFromTheKeyInMemoryWithoutPrompting() async {
        let freshStore = FaceEnrollmentStore(session: session)
        XCTAssertEqual(freshStore.state, .locked)
        let coordinator = await makeCoordinator(faceStore: freshStore)
        XCTAssertEqual(freshStore.state, .ready)
        XCTAssertEqual(coordinator.status, .ready)
        assertNothingPrompted()
    }

    func testUnreadableFaceDataIsNotReady() async throws {
        try Data(repeating: 7, count: 64).write(to: session.faceIdentitiesURL)
        let freshStore = FaceEnrollmentStore(session: session)
        let coordinator = await makeCoordinator(faceStore: freshStore)
        XCTAssertEqual(coordinator.status, .faceDataNotReady)
        await lockAndWake(coordinator)
        XCTAssertEqual(camera.startCount, 0)
        assertNothingPrompted()
    }

    /// Faces enrolled with the old 512-d ArcFace model, loaded after the
    /// swap to the 256-d model: kept, never scanned against, and the status
    /// asks for a recapture rather than saying nothing is enrolled.
    func testOnlyOldModelFacesAskForARecaptureAndNeverScan() async throws {
        let old = FaceIdentity(name: "Owner", samples: [sample([Float](repeating: 0.04, count: 512))],
                               modelIdentifier: "arcface-w600k_mbf-v1", embeddingDimension: 512)
        let key = try XCTUnwrap(vault.readKey())
        try FaceFileWriter.replace(session.faceIdentitiesURL,
                                   with: FaceCrypto.seal(JSONEncoder().encode([old]), using: key))
        let before = try Data(contentsOf: session.faceIdentitiesURL)

        let freshStore = FaceEnrollmentStore(session: session)
        let coordinator = await makeCoordinator(faceStore: freshStore)
        XCTAssertEqual(freshStore.identities.map(\.id), [old.id], "kept, not deleted")
        XCTAssertEqual(freshStore.staleIdentities.map(\.id), [old.id])
        XCTAssertEqual(coordinator.status, .enrolledFacesNeedRecapture)
        XCTAssertTrue(coordinator.status.needsAttention)

        await lockAndWake(coordinator)
        XCTAssertEqual(camera.startCount, 0)
        XCTAssertEqual(recognizer.created, 0)
        XCTAssertEqual(typer.calls, 0)
        XCTAssertEqual(try Data(contentsOf: session.faceIdentitiesURL), before, "never rewritten")
    }

    func testCameraThatFailsToStartEndsTheCycle() async {
        camera.failsToStart = true
        camera.errorMessage = "No camera was found."
        let coordinator = await makeCoordinator()
        await lockAndWake(coordinator)
        XCTAssertEqual(coordinator.lastOutcome, .failed("No camera was found."))
        XCTAssertEqual(typer.calls, 0)
    }

    // MARK: - Disable and abort

    func testDisablingMidScanStopsTheCamera() async {
        recognizer.script = { _ in nil }
        let settings = self.settings!
        camera.onRead = { reads in
            if reads == 10 { settings.update { $0.faceUnlockAtLockScreenEnabled = false } }
        }
        let coordinator = await makeCoordinator()
        await lockAndWake(coordinator)
        XCTAssertFalse(camera.isRunning)
        XCTAssertGreaterThanOrEqual(camera.stopCount, 1)
        XCTAssertLessThan(camera.reads, 30, "the scan ended right after the switch")
        XCTAssertEqual(coordinator.status, .disabled)
        XCTAssertFalse(events.isStarted)
        XCTAssertEqual(typer.calls, 0)
    }

    func testAnAbortedTypingIsRecordedAndNotVerified() async {
        typer.error = KeystrokeTyperError.notAtLockScreen
        let coordinator = await makeCoordinator()
        await lockAndWake(coordinator)
        XCTAssertEqual(typer.calls, 1)
        XCTAssertEqual(coordinator.lastOutcome, .aborted)
        XCTAssertEqual(coordinator.consecutiveRejections, 0)
        XCTAssertTrue(typer.buffers.allSatisfy(\.isWiped))
    }

    /// Review finding 3: the camera never runs with the display asleep. The
    /// wake waits, and the display's own wake signal, even inside the
    /// debounce, starts the scan.
    func testAWakeWithTheDisplayAsleepStartsNoScanUntilTheDisplayWakes() async {
        lockGuard.displayAsleep = true
        let coordinator = await makeCoordinator()
        await lockAndWake(coordinator)
        XCTAssertEqual(camera.startCount, 0, "no camera with the display asleep")
        XCTAssertEqual(typer.calls, 0)

        lockGuard.displayAsleep = false
        events.send(.wake) // the display's wake, well inside the debounce
        await settle(coordinator)
        XCTAssertEqual(camera.startCount, 1)
        XCTAssertEqual(typer.calls, 1)
        assertNothingPrompted()
    }

    // MARK: - One injection per lock session, and the pause

    func testOneInjectionPerLockSessionThenPauseAfterTwoRejections() async throws {
        let coordinator = await makeCoordinator()

        // Lock session 1: typed, but the Mac stays locked.
        await lockAndWake(coordinator)
        XCTAssertEqual(typer.calls, 1)
        XCTAssertEqual(coordinator.lastOutcome, .passwordRejected)
        XCTAssertEqual(coordinator.status, .passwordRejected)
        XCTAssertEqual(coordinator.consecutiveRejections, 1)

        // Another wake in the same lock session types nothing.
        await wakeAgain(coordinator)
        XCTAssertEqual(typer.calls, 1)
        XCTAssertEqual(camera.startCount, 1, "no scan once the password was typed")

        // The user types it by hand; lock session 2 is rejected too.
        await unlock(coordinator)
        await lockAndWake(coordinator)
        XCTAssertEqual(typer.calls, 2)
        XCTAssertEqual(coordinator.consecutiveRejections, 2)
        XCTAssertEqual(coordinator.status, .pausedAfterRejections)

        // Lock session 3: paused, nothing scanned or typed.
        await unlock(coordinator)
        await lockAndWake(coordinator)
        XCTAssertEqual(typer.calls, 2)
        XCTAssertEqual(camera.startCount, 2)
        XCTAssertEqual(coordinator.status, .pausedAfterRejections)

        // Re-saving the password resumes.
        await unlock(coordinator)
        try await passwordStore.save(password)
        await settle(coordinator)
        XCTAssertEqual(coordinator.consecutiveRejections, 0)
        XCTAssertEqual(coordinator.status, .ready)
    }

    func testUnlockingTheSessionAgainResumesAfterThePause() async {
        let coordinator = await makeCoordinator()
        await lockAndWake(coordinator)
        await unlock(coordinator)
        await lockAndWake(coordinator)
        XCTAssertEqual(coordinator.status, .pausedAfterRejections)
        await unlock(coordinator)

        session.lock()
        await session.unlock(reason: "test")
        await settle(coordinator)
        XCTAssertEqual(coordinator.consecutiveRejections, 0)
        XCTAssertEqual(coordinator.status, .ready)
    }

    func testASuccessResetsTheRejectionCount() async {
        let coordinator = await makeCoordinator()
        await lockAndWake(coordinator)
        XCTAssertEqual(coordinator.consecutiveRejections, 1)
        await unlock(coordinator)

        let lockGuard = self.lockGuard!
        typer.onType = { lockGuard.state = .unlocked }
        await lockAndWake(coordinator)
        XCTAssertEqual(coordinator.lastOutcome, .unlocked)
        XCTAssertEqual(coordinator.consecutiveRejections, 0)
    }

    /// Every timed check is held, so only the unlock notification can end
    /// this one.
    func testTheUnlockEventEndsVerificationEarly() async {
        let coordinator = await makeCoordinator()
        await rejectOnce(coordinator)
        clock.holdSleep = { $0 == FaceUnlockCoordinator.unlockConfirmationWindow }
        let lockGuard = self.lockGuard!
        typer.onType = { lockGuard.state = .unlocked }
        lockAndWakeWithoutWaiting()
        let verifying = await waitUntil { coordinator.status == .verifying && self.clock.heldCount == 1 }
        XCTAssertTrue(verifying)

        events.send(.screenUnlocked)
        let ended = await waitUntil { coordinator.lastOutcome == .unlocked }
        clock.releaseHeldSleeps()
        await settle(coordinator)
        XCTAssertTrue(ended, "the unlock notification ended the check, not a timer")
        XCTAssertEqual(coordinator.consecutiveRejections, 0)
        XCTAssertFalse(coordinator.lockSessionActive)
    }

    // MARK: - Fail closed on an unknown lock state (H1)

    func testAnUnknownLockStateNeitherEndsTheLockSessionNorCountsAsSuccess() async {
        let coordinator = await makeCoordinator()
        await rejectOnce(coordinator)

        clock.holdSleep = { $0 == FaceUnlockCoordinator.unlockConfirmationWindow }
        lockAndWakeWithoutWaiting()
        let verifying = await waitUntil { coordinator.status == .verifying && self.clock.heldCount == 1 }
        XCTAssertTrue(verifying)
        XCTAssertEqual(typer.calls, 2)

        // The session server stops answering while the check is pending.
        lockGuard.state = .unknown
        events.send(.screenUnlocked)
        let firstRecheck = FaceUnlockCoordinator.unknownRecheckDelays[0]
        let suspended = await waitUntil { self.clock.sleeps.contains(firstRecheck) }
        XCTAssertTrue(suspended, "the unknown state was seen")
        XCTAssertTrue(coordinator.lockSessionActive, "and did not end the lock session")
        XCTAssertEqual(coordinator.consecutiveRejections, 1, "unknown is not a success")
        XCTAssertEqual(coordinator.lastOutcome, .passwordRejected, "nothing new is recorded")
        XCTAssertEqual(coordinator.status, .verifying, "the check is still pending")

        // Locked again: the same lock session, so no second password.
        lockGuard.state = .locked
        let checks = lockGuard.checks
        clock.advance(by: 3)
        events.send(.wake)
        let rearmed = await waitUntil { self.lockGuard.checks > checks }
        XCTAssertTrue(rearmed, "the wake was evaluated")
        _ = await waitUntil(timeout: 0.2) { self.camera.startCount > 2 }
        XCTAssertEqual(typer.calls, 2)
        XCTAssertEqual(camera.startCount, 2, "no scan after the password was typed")

        clock.releaseHeldSleeps()
        await settle(coordinator)
        XCTAssertEqual(typer.calls, 2)
        XCTAssertEqual(coordinator.consecutiveRejections, 2, "the check found it still locked")
        XCTAssertEqual(coordinator.lastOutcome, .passwordRejected)
        assertNothingPrompted()
    }

    func testAnUnknownStateAtTheTimeoutIsInconclusive() async {
        let coordinator = await makeCoordinator()
        await rejectOnce(coordinator)

        let lockGuard = self.lockGuard!
        typer.onType = { lockGuard.state = .unknown }
        await lockAndWake(coordinator)
        XCTAssertEqual(typer.calls, 2)
        XCTAssertEqual(coordinator.lastOutcome, .verificationInconclusive)
        XCTAssertEqual(coordinator.consecutiveRejections, 1, "neither reset nor raised")

        // The same lock session once it answers again: still one password.
        lockGuard.state = .locked
        await wakeAgain(coordinator)
        XCTAssertTrue(coordinator.lockSessionActive)
        XCTAssertEqual(typer.calls, 2)
        XCTAssertEqual(camera.startCount, 2)
    }

    // MARK: - Confirmation window (M2)

    /// The typed password fails; the user types the right one by hand after
    /// the confirmation window. The timeout sees "unlocked", but that proves
    /// nothing about the stored password.
    func testAnUnlockSeenOnlyAtTheTimeoutIsNotCountedEitherWay() async {
        let coordinator = await makeCoordinator()
        await rejectOnce(coordinator)

        let lockGuard = self.lockGuard!, typer = self.typer!
        var verifySleeps = 0
        clock.onSleep = { seconds in
            guard typer.calls == 2, Self.verifySleepLengths.contains(seconds) else { return }
            verifySleeps += 1
            if verifySleeps == 2 { lockGuard.state = .unlocked } // after the window
        }
        await lockAndWake(coordinator)
        XCTAssertEqual(typer.calls, 2)
        XCTAssertEqual(verifySleeps, 2)
        XCTAssertEqual(coordinator.lastOutcome, .unlockedUnconfirmed)
        XCTAssertEqual(coordinator.consecutiveRejections, 1, "neither reset nor raised")
    }

    func testAnUnlockEventAfterTheConfirmationWindowIsNotCountedEitherWay() async {
        let coordinator = await makeCoordinator()
        await rejectOnce(coordinator)

        let typer = self.typer!
        var verifySleeps = 0
        clock.holdSleep = { seconds in
            guard typer.calls == 2, Self.verifySleepLengths.contains(seconds) else { return false }
            verifySleeps += 1
            return verifySleeps == 2 // the confirmation window passes; the rest is held
        }
        lockAndWakeWithoutWaiting()
        let verifying = await waitUntil { coordinator.status == .verifying && self.clock.heldCount == 1 }
        XCTAssertTrue(verifying)

        // Unlocked by hand 2.5 s after Return (plus the settle delay).
        clock.advance(by: 0.5)
        lockGuard.state = .unlocked
        events.send(.screenUnlocked)
        let ended = await waitUntil { coordinator.lastOutcome == .unlockedUnconfirmed }
        clock.releaseHeldSleeps()
        await settle(coordinator)
        XCTAssertTrue(ended)
        XCTAssertEqual(coordinator.consecutiveRejections, 1, "neither reset nor raised")
        XCTAssertFalse(coordinator.lockSessionActive)
    }

    // MARK: - After a success (L2)

    /// No unlock notification: the check itself ends the lock session.
    func testASuccessEndsTheLockSessionAndReleasesTheModel() async {
        let lockGuard = self.lockGuard!
        typer.onType = { lockGuard.state = .unlocked }
        let coordinator = await makeCoordinator()
        await lockAndWake(coordinator)
        XCTAssertEqual(coordinator.lastOutcome, .unlocked)
        XCTAssertFalse(coordinator.lockSessionActive, "ended without waiting for the notification")

        await lockAndWake(coordinator)
        XCTAssertEqual(recognizer.created, 2, "the model was released, and loads again")
        XCTAssertEqual(typer.calls, 2, "a new lock session")
    }

    // MARK: - Stale typing (L3)

    func testTypingThatOutlivesItsLockSessionIsNotChecked() async {
        let gate = TestGate()
        typer.onType = { gate.wait() }
        let coordinator = await makeCoordinator()
        lockAndWakeWithoutWaiting()
        let typing = await waitUntil { gate.waiting == 1 }
        XCTAssertTrue(typing)

        // While typing: the screen unlocks, then a new lock session begins.
        lockGuard.state = .unlocked
        events.send(.screenUnlocked)
        let ended = await waitUntil { !coordinator.lockSessionActive }
        XCTAssertTrue(ended)
        // The display is off, so the new lock session's scan stays pending
        // and the only typing in this test is the first session's.
        lockGuard.displayAsleep = true
        lockGuard.state = .locked
        events.send(.screenLocked)
        let relocked = await waitUntil { coordinator.lockSessionActive }
        XCTAssertTrue(relocked)

        gate.open()
        let finished = await waitUntil { self.typer.buffers.first?.isWiped == true }
        XCTAssertTrue(finished)
        await settle(coordinator)
        XCTAssertEqual(coordinator.consecutiveRejections, 0, "not counted against the new lock session")
        XCTAssertNil(coordinator.lastOutcome)
        XCTAssertEqual(coordinator.status, .ready)
    }

    // MARK: - Preload (M1)

    func testThePreloadNeverPromptsWhenTheSessionLocksBeforeItRuns() async {
        let freshStore = FaceEnrollmentStore(session: session)
        let coordinator = await makeCoordinator(faceStore: freshStore, settled: false)
        // The preload was scheduled during init and has not run yet.
        session.lock()
        await settle(coordinator)
        XCTAssertEqual(authenticator.calls, authCallsAfterSetup, "no owner check")
        XCTAssertEqual(freshStore.state, .locked)
        XCTAssertEqual(coordinator.status, .sessionLocked)
    }

    // MARK: - Password read (L4)

    func testTheSecretReadUsesOnlyTheKeyInMemory() throws {
        let secret = try passwordStore.readPasswordSecret()
        XCTAssertEqual(secret.withUnsafeBytes { Array($0) }, Array(password.utf8))
        secret.wipe()
        XCTAssertTrue(secret.isWiped)

        session.lock()
        XCTAssertThrowsError(try passwordStore.readPasswordSecret()) { error in
            XCTAssertEqual(error as? FacePasswordError, .sessionLocked)
        }
        assertNothingPrompted()
    }

    // MARK: - More aborts (L6)

    func testSleepingMidScanStopsTheCameraAndTypesNothing() async {
        let enrolled = self.enrolled, events = self.events!
        recognizer.script = { id in id < 10 ? nil : enrolled }
        camera.onRead = { reads in if reads == 5 { events.send(.sleep) } }
        let coordinator = await makeCoordinator()
        await lockAndWake(coordinator)
        XCTAssertEqual(typer.calls, 0)
        XCTAssertFalse(camera.isRunning)
        XCTAssertGreaterThanOrEqual(camera.stopCount, 1)
        XCTAssertLessThan(camera.reads, 10, "the scan ended at the sleep")
    }

    func testASupersededScanNeitherStopsTheNewerCameraNorTypes() async {
        let oldFrame = TestGate(), newFrame = TestGate()
        let enrolled = self.enrolled
        // Frame 3 is the first cycle's last; frame 5 is in the second.
        recognizer.script = { id in
            switch id {
            case 3: oldFrame.wait(); return enrolled
            case 5: newFrame.wait(); return enrolled
            default: return nil
            }
        }
        let events = self.events!, clock = self.clock!
        camera.onRead = { reads in
            guard reads == 3 else { return }
            // The Mac sleeps and wakes again while frame 3 is being checked.
            events.send(.sleep)
            clock.advance(by: 3)
            events.send(.wake)
        }
        let coordinator = await makeCoordinator()
        lockAndWakeWithoutWaiting()
        let scanning = await waitUntil { newFrame.waiting == 1 }
        XCTAssertTrue(scanning, "the second cycle is scanning")
        XCTAssertEqual(camera.startCount, 2)
        XCTAssertTrue(camera.isRunning)
        let stopsBefore = camera.stopCount

        // The first cycle wakes to a matching face; give it time to act.
        oldFrame.open()
        _ = await waitUntil(timeout: 0.5) { self.camera.stopCount != stopsBefore || self.typer.calls > 0 }
        XCTAssertEqual(camera.stopCount, stopsBefore, "the old cycle leaves the newer camera alone")
        XCTAssertTrue(camera.isRunning)
        XCTAssertEqual(typer.calls, 0, "and cannot type")

        newFrame.open()
        await settle(coordinator)
        XCTAssertEqual(typer.calls, 1, "the current cycle types once")
    }

    func testTheGuardFlippingAfterTheMatchStopsTypingBeforeItStarts() async {
        let lockGuard = self.lockGuard!, enrolled = self.enrolled
        recognizer.script = { _ in
            lockGuard.state = .unlocked // between the match and the typing
            return enrolled
        }
        let coordinator = await makeCoordinator()
        await lockAndWake(coordinator)
        XCTAssertEqual(typer.calls, 0, "nothing typed, so no Return")
        XCTAssertEqual(coordinator.lastOutcome, .aborted)
    }

    func testTypingResumesAfterTheRejectedPasswordIsReSaved() async throws {
        let coordinator = await makeCoordinator()
        await rejectOnce(coordinator)
        await lockAndWake(coordinator)
        XCTAssertEqual(coordinator.status, .pausedAfterRejections)
        await unlock(coordinator)

        try await passwordStore.save(password)
        await settle(coordinator)
        let lockGuard = self.lockGuard!
        typer.onType = { lockGuard.state = .unlocked }
        await lockAndWake(coordinator)
        XCTAssertEqual(typer.calls, 3, "typing resumed")
        XCTAssertEqual(coordinator.lastOutcome, .unlocked)
        XCTAssertEqual(coordinator.consecutiveRejections, 0)
    }
}

extension FaceUnlockCoordinatorTests {

    /// Measured on hardware: after a typed unlock the session server can
    /// answer "unknown" for seconds, with no later event to ask again. A
    /// recheck must still end that lock session, or the next lock could
    /// never type.
    func testALockSessionStuckOnUnknownEndsOnARecheck() async {
        let lockGuard = self.lockGuard!
        typer.onType = { lockGuard.state = .unknown }
        // Holds the third recheck: the first two find it still unknown.
        clock.holdSleep = { $0 == FaceUnlockCoordinator.unknownRecheckDelays[2] }
        let coordinator = await makeCoordinator()
        lockAndWakeWithoutWaiting()
        let waiting = await waitUntil { self.clock.heldCount == 1 }
        XCTAssertTrue(waiting, "rechecks run after an unknown answer")
        XCTAssertEqual(typer.calls, 1)

        lockGuard.state = .unlocked
        clock.releaseHeldSleeps()
        await settle(coordinator)
        XCTAssertFalse(coordinator.lockSessionActive)

        typer.onType = nil
        await lockAndWake(coordinator)
        XCTAssertEqual(typer.calls, 2, "a new lock session may type again")
        assertNothingPrompted()
    }

    func testRechecksOfAnUnknownStateAreBounded() async {
        let lockGuard = self.lockGuard!
        typer.onType = { lockGuard.state = .unknown }
        let coordinator = await makeCoordinator()
        await lockAndWake(coordinator)
        for _ in 0..<5 { await settle(coordinator) }
        let delays = FaceUnlockCoordinator.unknownRecheckDelays
        let rechecks = clock.sleeps.filter { delays.contains($0) && $0 != FaceUnlockCoordinator.unlockConfirmationWindow }
        XCTAssertLessThanOrEqual(rechecks.count, delays.count, "no endless re-reading")
        XCTAssertEqual(clock.sleeps.filter { $0 == delays.last }.count, 1, "the last delay runs once")

        // Still unknown: fail closed, the same lock session, no second password.
        lockGuard.state = .locked
        clock.advance(by: 3)
        events.send(.wake)
        await settle(coordinator)
        XCTAssertEqual(typer.calls, 1)
    }
}

// MARK: - Continuous scan and the password-field gate (2026-10-15)

extension FaceUnlockCoordinatorTests {

    /// Measured on hardware: a match on the account picker (secure input
    /// off) typed the password into the picker. Now it holds, the scan goes
    /// on, and the first fresh match once the field is up types, once.
    func testAMatchWithoutThePasswordFieldHoldsThenTypesOnALaterFreshMatch() async {
        let enrolled = self.enrolled, lockGuard = self.lockGuard!
        lockGuard.secureInput = false
        // Frames 1–10 match on the picker; 11–20 see no face; 21 on match.
        recognizer.script = { id in (11...20).contains(id) ? nil : enrolled }
        camera.onRead = { reads in if reads == 15 { lockGuard.secureInput = true } }
        let coordinator = await makeCoordinator()
        await lockAndWake(coordinator)
        XCTAssertEqual(typer.calls, 1, "typed exactly once")
        XCTAssertEqual(recognizer.calls, 21, "on the first match after the field came up")
        XCTAssertEqual(camera.startCount, 1, "one scan throughout")
        XCTAssertFalse(camera.isRunning)
        XCTAssertEqual(coordinator.lastOutcome, .passwordRejected)
        assertNothingPrompted()
    }

    /// The hardware sequence: matches on the picker, then the session goes
    /// off the console. Nothing is typed, and the scan stops.
    func testAMatchOnTheAccountPickerNeverTypes() async {
        let lockGuard = self.lockGuard!
        lockGuard.secureInput = false
        camera.onRead = { reads in if reads == 300 { lockGuard.state = .unknown } }
        let coordinator = await makeCoordinator()
        await lockAndWake(coordinator)
        XCTAssertEqual(typer.calls, 0)
        XCTAssertEqual(recognizer.calls, 300, "every match held; the scan went on until the state was lost")
        XCTAssertFalse(camera.isRunning)
        XCTAssertEqual(coordinator.lastOutcome, .aborted, "the last match met the lost state and was refused")
        assertNothingPrompted()
    }

    func testAWrongFaceKeepsScanningAndALaterMatchTypes() async {
        let stranger = self.stranger, enrolled = self.enrolled
        recognizer.script = { id in id <= 400 ? stranger : enrolled }
        let coordinator = await makeCoordinator()
        let start = clock.now()
        await lockAndWake(coordinator)
        XCTAssertEqual(typer.calls, 1)
        XCTAssertEqual(recognizer.calls, 401, "no give-up on a wrong face")
        XCTAssertGreaterThan(clock.now() - start, 10, "well past the old 2 s wrong-face limit")
        XCTAssertEqual(camera.startCount, 1)
        assertNothingPrompted()
    }

    func testTheScanStopsAtTheCapAndALaterWakeRestarts() async {
        recognizer.script = { _ in nil }
        let clock = self.clock!
        var firstFrameAt: TimeInterval?
        camera.onRead = { _ in if firstFrameAt == nil { firstFrameAt = clock.now() } }
        let coordinator = await makeCoordinator()
        await lockAndWake(coordinator)
        XCTAssertEqual(coordinator.lastOutcome, .scanCapReached)
        XCTAssertEqual(coordinator.lastOutcome?.text, "Stopped looking after 2 minutes — close and reopen the lid, or let the display sleep and wake it, to try again.")
        XCTAssertFalse(camera.isRunning, "the camera stops at the cap")
        XCTAssertGreaterThanOrEqual(camera.stopCount, 1)
        let elapsed = clock.now() - (firstFrameAt ?? 0)
        XCTAssertEqual(elapsed, FaceUnlockCoordinator.scanCap, accuracy: FaceUnlockCoordinator.slowFrameInterval + 0.01)
        XCTAssertEqual(coordinator.status, .ready)

        await wakeAgain(coordinator)
        XCTAssertEqual(camera.startCount, 2, "a later wake starts a new scan")
        XCTAssertEqual(typer.calls, 0)
        assertNothingPrompted()
    }

    func testFramesArePacedAfterTheFastPhase() async {
        recognizer.script = { _ in nil }
        let clock = self.clock!
        var readTimes: [TimeInterval] = []
        camera.onRead = { _ in readTimes.append(clock.now()) }
        let coordinator = await makeCoordinator()
        await lockAndWake(coordinator)
        guard let first = readTimes.first else { return XCTFail("no frames read") }

        let fastEnd = first + FaceUnlockCoordinator.fastPhase
        let fastFrames = readTimes.filter { $0 < fastEnd }.count
        let slowFrames = readTimes.filter { $0 >= fastEnd }.count
        XCTAssertGreaterThanOrEqual(fastFrames, Int(FaceUnlockCoordinator.fastPhase / FaceUnlockCoordinator.frameWait) - 1,
                                    "every frame in the fast phase")
        XCTAssertGreaterThan(slowFrames, 100, "the scan goes on past the fast phase")
        let tooSoon = zip(readTimes, readTimes.dropFirst()).filter { previous, next in
            previous >= fastEnd && next - previous < FaceUnlockCoordinator.slowFrameInterval - 1e-9
        }
        XCTAssertEqual(tooSoon.count, 0, "after the fast phase, at most one frame per slowFrameInterval")
        let bound = Int(FaceUnlockCoordinator.fastPhase / FaceUnlockCoordinator.frameWait)
            + Int((FaceUnlockCoordinator.scanCap - FaceUnlockCoordinator.fastPhase) / FaceUnlockCoordinator.slowFrameInterval) + 2
        XCTAssertLessThanOrEqual(recognizer.calls, bound)
        XCTAssertEqual(recognizer.calls, readTimes.count, "every frame read was checked")
    }

    private enum ScanStop: CaseIterable { case displaySleep, systemSleep, unlock, disable, unknown }

    func testEveryStopEndsTheContinuousScanAndTheCamera() async {
        recognizer.script = { _ in nil }
        for stop in ScanStop.allCases {
            camera = FakeFrameSource()
            lockGuard.state = .unlocked
            lockGuard.displayAsleep = false
            settings.update { $0.faceUnlockAtLockScreenEnabled = true }
            let coordinator = await makeCoordinator()
            let camera = self.camera!, lockGuard = self.lockGuard!, events = self.events!, settings = self.settings!
            // Well into the slow phase, so the scan is the continuous one.
            camera.onRead = { reads in
                guard reads == 300 else { return }
                switch stop {
                case .displaySleep:
                    lockGuard.displayAsleep = true
                    events.send(.sleep)
                case .systemSleep: events.send(.sleep)
                case .unlock:
                    lockGuard.state = .unlocked
                    events.send(.screenUnlocked)
                case .disable: settings.update { $0.faceUnlockAtLockScreenEnabled = false }
                case .unknown:
                    lockGuard.state = .unknown
                    events.send(.screenUnlocked)
                }
            }
            await lockAndWake(coordinator)
            XCTAssertFalse(camera.isRunning, "\(stop): camera off")
            XCTAssertGreaterThanOrEqual(camera.stopCount, 1, "\(stop)")
            XCTAssertLessThan(camera.reads, 320, "\(stop): stopped right away, not at the cap")
            XCTAssertNotEqual(coordinator.lastOutcome, .scanCapReached, "\(stop)")
            XCTAssertEqual(camera.startCount, 1, "\(stop)")
        }
        XCTAssertEqual(typer.calls, 0)
        assertNothingPrompted()
    }
}

// MARK: - Review fixes (2026-10-15)

extension FaceUnlockCoordinatorTests {

    /// Finding 1: secure input is system-wide. Held by another app (here
    /// Terminal's Secure Keyboard Entry), it is not the password field.
    func testSecureInputHeldByAnotherAppHoldsTypingUntilLoginwindowHoldsIt() async {
        let lockGuard = self.lockGuard!
        lockGuard.secureInputOwner = "Terminal"
        camera.onRead = { reads in if reads == 15 { lockGuard.secureInputOwner = SecureInputOwner.loginWindow } }
        let coordinator = await makeCoordinator()
        await lockAndWake(coordinator)
        XCTAssertEqual(recognizer.calls, 15, "every match held while Terminal held secure input")
        XCTAssertEqual(typer.calls, 1, "typed once loginwindow held it")
        assertNothingPrompted()
    }

    func testSecureInputWithAnUnknownHolderNeverTypes() async {
        let lockGuard = self.lockGuard!
        lockGuard.secureInputOwner = nil
        camera.onRead = { reads in if reads == 50 { lockGuard.state = .unknown } }
        let coordinator = await makeCoordinator()
        await lockAndWake(coordinator)
        XCTAssertEqual(typer.calls, 0)
        XCTAssertEqual(recognizer.calls, 50)
    }

    /// Finding 2a: a wake while the lock state is unknown stays pending, and
    /// the recheck that reads "locked" starts its scan.
    func testAWakeDuringAnUnknownStateScansWhenARecheckReadsLocked() async {
        let lockGuard = self.lockGuard!
        let coordinator = await makeCoordinator()
        lockGuard.state = .locked
        events.send(.screenLocked)
        await settle(coordinator)

        lockGuard.state = .unknown
        let firstRecheck = FaceUnlockCoordinator.unknownRecheckDelays[0]
        clock.onSleep = { seconds in if seconds == firstRecheck { lockGuard.state = .locked } }
        clock.advance(by: 3)
        events.send(.wake)
        let scanned = await waitUntil { self.camera.startCount == 1 }
        await settle(coordinator)
        XCTAssertTrue(scanned, "the recheck started the pending scan")
        XCTAssertEqual(typer.calls, 1)
        assertNothingPrompted()
    }

    /// Finding 2b: an unknown state seen inside the scan loop goes through
    /// the unknown path, so a recheck still ends the lock session.
    func testAnUnknownStateInsideTheScanStillSchedulesRechecks() async {
        recognizer.script = { _ in nil }
        let lockGuard = self.lockGuard!
        camera.onRead = { reads in if reads == 20 { lockGuard.state = .unknown } }
        let firstRecheck = FaceUnlockCoordinator.unknownRecheckDelays[0]
        clock.onSleep = { seconds in if seconds == firstRecheck { lockGuard.state = .unlocked } }
        let coordinator = await makeCoordinator()
        await lockAndWake(coordinator)
        let ended = await waitUntil { !coordinator.lockSessionActive }
        XCTAssertTrue(clock.sleeps.contains(firstRecheck), "a recheck ran")
        XCTAssertTrue(ended, "and ended the lock session once it read unlocked")
        XCTAssertFalse(camera.isRunning)
        XCTAssertLessThan(camera.reads, 25)
    }

    /// Finding 2c: the debounce merges one wake's signals; a wake after a
    /// sleep is a new one, however soon.
    func testAWakeSoonAfterASleepIsNotDebounced() async {
        recognizer.script = { _ in nil }
        let events = self.events!
        camera.onRead = { reads in if reads == 5 { events.send(.sleep) } }
        let coordinator = await makeCoordinator()
        await lockAndWake(coordinator)
        XCTAssertEqual(camera.startCount, 1)

        camera.onRead = nil
        events.send(.wake) // under a second after the first wake
        await settle(coordinator)
        XCTAssertEqual(camera.startCount, 2, "the lid reopened: a new scan")
    }

    /// Finding 3: the display sleeping ends the scan even before (or
    /// without) a sleep notification.
    func testTheDisplaySleepingEndsTheScanWithoutAnEvent() async {
        recognizer.script = { _ in nil }
        let lockGuard = self.lockGuard!
        camera.onRead = { reads in if reads == 300 { lockGuard.displayAsleep = true } }
        let coordinator = await makeCoordinator()
        await lockAndWake(coordinator)
        XCTAssertFalse(camera.isRunning)
        XCTAssertLessThan(camera.reads, 305, "stopped right away, not at the cap")
        XCTAssertNotEqual(coordinator.lastOutcome, .scanCapReached)
        XCTAssertEqual(typer.calls, 0)
    }

    func testACameraThatStopsEndsTheScan() async {
        recognizer.script = { _ in nil }
        camera.onRead = { [unowned camera = self.camera!] reads in
            guard reads == 20 else { return }
            camera.errorMessage = "The camera stopped."
            camera.stop()
        }
        let coordinator = await makeCoordinator()
        await lockAndWake(coordinator)
        XCTAssertEqual(camera.reads, 20)
        XCTAssertEqual(coordinator.lastOutcome, .failed("The camera stopped."))
        XCTAssertEqual(typer.calls, 0)
    }

    /// A camera that reports running but sends nothing (a closed lid) ends
    /// the scan after `frameTimeout`, not at the 2-minute cap.
    func testACameraThatSendsNoFramesEndsTheScanAfterTheTimeout() async {
        recognizer.script = { _ in nil }
        camera.stallAfter = 10
        let clock = self.clock!
        var stalledAt: TimeInterval?
        camera.onRead = { reads in if reads == 10 { stalledAt = clock.now() } }
        let coordinator = await makeCoordinator()
        await lockAndWake(coordinator)
        XCTAssertEqual(coordinator.lastOutcome, .failed("the camera sent no picture for 3 seconds"))
        XCTAssertFalse(camera.isRunning)
        let waited = clock.now() - (stalledAt ?? 0)
        XCTAssertEqual(waited, FaceUnlockCoordinator.frameTimeout, accuracy: 0.1)
        XCTAssertEqual(typer.calls, 0)
    }

    /// Finding 4: with no new frame, the lock state is read at most every
    /// `stateCheckInterval`, not on every 20 ms poll.
    func testWaitingForAFrameReadsTheLockStateSparingly() async {
        recognizer.script = { _ in nil }
        camera.stallAfter = 10
        let lockGuard = self.lockGuard!
        var checksAtStall = 0
        camera.onRead = { reads in if reads == 10 { checksAtStall = lockGuard.checks } }
        let coordinator = await makeCoordinator()
        await lockAndWake(coordinator)
        let checks = lockGuard.checks - checksAtStall
        let bound = Int(FaceUnlockCoordinator.frameTimeout / FaceUnlockCoordinator.stateCheckInterval) + 4
        XCTAssertLessThanOrEqual(checks, bound, "about one read per \(FaceUnlockCoordinator.stateCheckInterval) s")
        XCTAssertEqual(coordinator.lastOutcome, .failed("the camera sent no picture for 3 seconds"))
    }

    /// Finding 4: past the fast phase the camera converts only the frames
    /// the scan asks for.
    func testPastTheFastPhaseTheCameraConvertsOnlyRequestedFrames() async {
        recognizer.script = { _ in nil }
        let clock = self.clock!
        var frames: [(at: TimeInterval, everyFrame: Bool)] = []
        camera.onRead = { [unowned camera = self.camera!] _ in frames.append((clock.now(), camera.convertsEveryFrame)) }
        let coordinator = await makeCoordinator()
        await lockAndWake(coordinator)
        guard let first = frames.first?.at else { return XCTFail("no frames") }
        let fast = frames.filter { $0.at < first + FaceUnlockCoordinator.fastPhase }
        let slow = frames.filter { $0.at >= first + FaceUnlockCoordinator.fastPhase + FaceUnlockCoordinator.slowFrameInterval }
        XCTAssertTrue(fast.allSatisfy(\.everyFrame), "every frame in the fast phase")
        XCTAssertGreaterThan(slow.count, 100)
        XCTAssertTrue(slow.allSatisfy { !$0.everyFrame }, "then only requested frames are converted")
        XCTAssertGreaterThanOrEqual(camera.requests, slow.count)
        XCTAssertTrue(camera.convertsEveryFrame, "back to every frame once stopped")
    }

    /// Finding 5: typing that stopped before its first key event does not
    /// spend the lock session's one password.
    func testAnAbortBeforeAnyKeyLeavesTheLockSessionsPasswordUnspent() async {
        typer.error = KeystrokeTyperError.notAtLockScreen
        let coordinator = await makeCoordinator()
        await lockAndWake(coordinator)
        XCTAssertEqual(typer.calls, 1)
        XCTAssertEqual(coordinator.lastOutcome, .aborted)
        XCTAssertEqual(coordinator.lastOutcome?.text,
                       "Stopped before typing: the Mac left the lock screen or the password field lost focus.")

        typer.error = nil
        await wakeAgain(coordinator)
        XCTAssertEqual(typer.calls, 2, "nothing reached the field, so a later wake may type")
        assertNothingPrompted()
    }

    func testAnAbortPartwaySpendsThePasswordAndSaysToClearTheField() async {
        typer.error = KeystrokeTyperError.stoppedPartway
        let coordinator = await makeCoordinator()
        await lockAndWake(coordinator)
        XCTAssertEqual(coordinator.lastOutcome, .abortedPartway)
        XCTAssertEqual(coordinator.lastOutcome?.text,
                       "Partially typed; Return not pressed — clear the field before typing your password.")
        XCTAssertEqual(coordinator.consecutiveRejections, 0, "not a rejection: Return was never pressed")

        typer.error = nil
        await wakeAgain(coordinator)
        XCTAssertEqual(typer.calls, 1, "part of the password went out: no second attempt this lock session")
        XCTAssertEqual(camera.startCount, 1)
    }
}

// MARK: - Liveness (phase 4)

extension FaceUnlockCoordinatorTests {

    /// Light liveness on, with the sampler's script: a clean, fully checked
    /// face by default.
    private func useLightLiveness(_ script: @escaping @Sendable (UInt64) -> LivenessSample = { _ in FakeLivenessSampler.clean }) {
        settings.update { $0.faceUnlockLiveness = .light }
        livenessSampler.script = script
    }

    /// Similarity 0.66 to the enrolled face: under balanced (0.72), over its
    /// count floor (0.56). The owner on a frame that missed.
    private var nearMiss: [Float] { [0.66, (1 - 0.66 * 0.66).squareRoot(), 0, 0] }

    func testLivenessDefaultsToLight() {
        XCTAssertEqual(AppSettings().faceUnlockLiveness, .light)
    }

    func testLightLivenessTypesOnTheFifthCleanFaceFrame() async {
        useLightLiveness()
        let coordinator = await makeCoordinator()
        await lockAndWake(coordinator)
        XCTAssertEqual(typer.calls, 1)
        XCTAssertEqual(recognizer.calls, 5, "four matched frames held, the fifth types")
        XCTAssertEqual(livenessSampler.calls, 5, "every face frame is measured")
        assertNothingPrompted()
    }

    /// On a strict threshold the owner's similarity hovers round the line.
    /// Matches need not come in a row: near misses count toward the run.
    func testAnOwnerWhoseMatchesAlternateStillTypes() async {
        let enrolled = self.enrolled, nearMiss = self.nearMiss
        recognizer.script = { id in id.isMultiple(of: 2) ? nearMiss : enrolled }
        useLightLiveness()
        let coordinator = await makeCoordinator()
        await lockAndWake(coordinator)
        XCTAssertEqual(typer.calls, 1)
        XCTAssertEqual(recognizer.calls, 5, "match, miss, match, miss, match: the fifth frame types")
    }

    func testAMatchTypesAfterNearMissFrames() async {
        let enrolled = self.enrolled, nearMiss = self.nearMiss
        recognizer.script = { id in id <= 4 ? nearMiss : enrolled }
        useLightLiveness()
        let coordinator = await makeCoordinator()
        await lockAndWake(coordinator)
        XCTAssertEqual(typer.calls, 1)
        XCTAssertEqual(recognizer.calls, 5, "the first match types")
    }

    /// Review #2's priming case end to end: a stranger's clean frames, then
    /// a matching face that trips nothing (a careful photo). The match must
    /// earn its own five clean frames.
    func testAStrangersCleanFramesDoNotPrimeAMatch() async {
        let enrolled = self.enrolled, stranger = self.stranger
        recognizer.script = { id in id <= 4 ? stranger : enrolled }
        useLightLiveness()
        let coordinator = await makeCoordinator()
        await lockAndWake(coordinator)
        XCTAssertEqual(typer.calls, 1)
        XCTAssertEqual(recognizer.calls, 9, "frames 5 to 9, not frame 5 on the stranger's credit")
    }

    func testAGlareFrameJustBeforeAMatchHoldsIt() async {
        useLightLiveness { id in id == 2 ? FakeLivenessSampler.screenGlare : FakeLivenessSampler.clean }
        let coordinator = await makeCoordinator()
        await lockAndWake(coordinator)
        XCTAssertEqual(typer.calls, 1)
        XCTAssertEqual(recognizer.calls, 7, "frame 2 tripped: frames 3 to 7 must be clean first")
    }

    func testAMatchWhileLivenessDeniesNeverTypes() async {
        useLightLiveness { _ in FakeLivenessSampler.screenGlare }
        let coordinator = await makeCoordinator()
        await lockAndWake(coordinator)
        XCTAssertEqual(typer.calls, 0, "every frame matched, none typed")
        XCTAssertGreaterThan(recognizer.calls, 3, "the scan went on after the denial")
        XCTAssertEqual(coordinator.lastOutcome, .livenessDenied(.glossGlare), "told apart from a face that never matched")
        XCTAssertFalse(camera.isRunning)
        XCTAssertEqual(coordinator.status, .ready, "a denial is not a password rejection")
        XCTAssertEqual(coordinator.consecutiveRejections, 0)
    }

    /// Review #2: tripping on 2 of every 5 frames stays under the deny
    /// level, and must still never type.
    func testASpoofTrippingOnTwoOfEveryFiveFramesNeverTypes() async {
        useLightLiveness { id in (id - 1) % 5 < 2 ? FakeLivenessSampler.screenGlare : FakeLivenessSampler.clean }
        let coordinator = await makeCoordinator()
        await lockAndWake(coordinator)
        XCTAssertEqual(typer.calls, 0)
        XCTAssertGreaterThan(recognizer.calls, 100, "it ran to the cap")
        XCTAssertEqual(coordinator.lastOutcome, .scanCapReached)
    }

    func testTypingResumesOnceTheDenialClears() async {
        useLightLiveness { id in id <= 3 ? FakeLivenessSampler.screenGlare : FakeLivenessSampler.clean }
        let coordinator = await makeCoordinator()
        await lockAndWake(coordinator)
        XCTAssertEqual(typer.calls, 1)
        XCTAssertEqual(recognizer.calls, 8, "denied on frame 3, held until frames 4 to 8 are all clean")
    }

    /// Review #10: a denial that cleared must not name the cap's outcome.
    func testACapAfterADenialClearedIsNotReportedAsADenial() async {
        let enrolled = self.enrolled, stranger = self.stranger
        recognizer.script = { id in id <= 3 ? enrolled : stranger }
        useLightLiveness { id in id <= 3 ? FakeLivenessSampler.screenGlare : FakeLivenessSampler.clean }
        let coordinator = await makeCoordinator()
        await lockAndWake(coordinator)
        XCTAssertEqual(typer.calls, 0)
        XCTAssertEqual(coordinator.lastOutcome, .scanCapReached, "the match on frame 3 was blocked, but the denial cleared")
    }

    /// One evaluator per scan: a denial ends with its scan.
    func testADenialDoesNotCarryOverToTheNextScan() async {
        let glaring = LockedFlag(true)
        useLightLiveness { _ in glaring.value ? FakeLivenessSampler.screenGlare : FakeLivenessSampler.clean }
        let coordinator = await makeCoordinator()
        await lockAndWake(coordinator)
        XCTAssertEqual(coordinator.lastOutcome, .livenessDenied(.glossGlare))
        let callsBefore = recognizer.calls

        glaring.value = false
        await wakeAgain(coordinator)
        XCTAssertEqual(typer.calls, 1)
        XCTAssertEqual(recognizer.calls - callsBefore, 5, "a fresh window: five clean frames, nothing left over")
    }

    /// Review #3: frames no cue can vouch for never add up to a pass.
    func testFramesNoCueCanVouchForNeverType() async {
        useLightLiveness { _ in LivenessSample.none }
        let coordinator = await makeCoordinator()
        await lockAndWake(coordinator)
        XCTAssertEqual(typer.calls, 0)
        XCTAssertEqual(coordinator.lastOutcome, .scanCapReached)
    }

    /// Someone else's face first (clean, not matching), then the owner's
    /// photo on a phone: the phone's first match trips the device cue.
    func testAStrangersCleanFaceDoesNotLetAPhoneAfterItType() async {
        let enrolled = self.enrolled, stranger = self.stranger
        let phone = LivenessSample(glare: FakeLivenessSampler.skin.glare,
                                   device: DeviceBezelSample(faceOverlap: 0.9, areaRatio: 3))
        recognizer.script = { id in id <= 3 ? stranger : enrolled }
        useLightLiveness { id in id <= 3 ? FakeLivenessSampler.clean : phone }
        let coordinator = await makeCoordinator()
        await lockAndWake(coordinator)
        XCTAssertEqual(typer.calls, 0)
        XCTAssertEqual(coordinator.lastOutcome, .livenessDenied(.deviceDetected))
    }

    func testLivenessOffTypesOnTheFirstMatchAndMeasuresNothing() async {
        settings.update { $0.faceUnlockLiveness = .off }
        livenessSampler.script = { _ in FakeLivenessSampler.screenGlare }
        let coordinator = await makeCoordinator()
        await lockAndWake(coordinator)
        XCTAssertEqual(typer.calls, 1)
        XCTAssertEqual(recognizer.calls, 1, "a single match types, as before phase 4")
        XCTAssertEqual(livenessSampler.calls, 0, "nothing is measured with liveness off")
    }

    func testAScanWithNoMatchStillEndsAtTheCapNotAsADenial() async {
        let stranger = self.stranger
        recognizer.script = { _ in stranger }
        useLightLiveness { _ in FakeLivenessSampler.screenGlare }
        let coordinator = await makeCoordinator()
        await lockAndWake(coordinator)
        XCTAssertEqual(typer.calls, 0)
        XCTAssertEqual(coordinator.lastOutcome, .scanCapReached, "denied, but no match was ever refused")
    }

    /// Only a scan that runs to the cap reports the denial; one that ends
    /// on the display sleeping records nothing, as before liveness.
    func testADenialFollowedByTheDisplaySleepingRecordsNothing() async {
        useLightLiveness { _ in FakeLivenessSampler.screenGlare }
        let lockGuard = self.lockGuard!
        camera.onRead = { reads in if reads == 20 { lockGuard.displayAsleep = true } }
        let coordinator = await makeCoordinator()
        await lockAndWake(coordinator)
        XCTAssertFalse(camera.isRunning)
        XCTAssertLessThan(camera.reads, 25, "stopped right away, not at the cap")
        XCTAssertEqual(typer.calls, 0)
        XCTAssertNil(coordinator.lastOutcome)
    }

    func testALivenessDenialShowsAsAFailureAtTheLockScreen() {
        XCTAssertTrue(LockScreenOverlayMapping.showsFailure(.livenessDenied(.deviceDetected)))
    }
}

// MARK: - Review fixes: face size, recognition errors, model load, scan cap

extension FaceUnlockCoordinatorTests {

    /// A recognizer that finds the enrolled face, `width` of the 1 px fake
    /// frame wide.
    private func faceOfWidth(_ width: CGFloat) -> ScriptedScanRecognizer {
        let enrolled = self.enrolled
        return ScriptedScanRecognizer { _ in
            FaceScan(embedding: enrolled, faceBox: CGRect(x: 0, y: 0, width: width, height: width))
        }
    }

    /// Review #3: a face too small to measure is no face at the lock screen.
    func testAFaceNarrowerThanTheMinimumIsNoFace() async {
        let tiny = faceOfWidth(0.11)
        let coordinator = await makeCoordinator(makeRecognizer: { tiny })
        await lockAndWake(coordinator)
        XCTAssertEqual(typer.calls, 0, "liveness is off: any face that counted would have typed")
        XCTAssertEqual(coordinator.lastOutcome, .scanCapReached)
        XCTAssertNil(coordinator.lastBestSimilarity, "never scored")
        XCTAssertGreaterThan(tiny.calls, 100)
    }

    func testAFaceAtTheMinimumWidthCounts() async {
        let small = faceOfWidth(0.12)
        let coordinator = await makeCoordinator(makeRecognizer: { small })
        await lockAndWake(coordinator)
        XCTAssertEqual(typer.calls, 1)
        XCTAssertEqual(small.calls, 1)
    }

    /// Review #9: a recognizer that keeps throwing ends the scan as failed
    /// instead of scanning blind for 2 minutes.
    func testPersistentRecognitionErrorsEndTheScanAsFailed() async {
        let broken = ScriptedScanRecognizer { _ in throw FakeRecognitionError() }
        let coordinator = await makeCoordinator(makeRecognizer: { broken })
        await lockAndWake(coordinator)
        XCTAssertEqual(broken.calls, FaceUnlockCoordinator.recognitionErrorLimit)
        XCTAssertEqual(coordinator.lastOutcome, .failed("face recognition failed: the model is broken"))
        XCTAssertFalse(camera.isRunning, "the camera stops")
        XCTAssertEqual(typer.calls, 0)
        XCTAssertEqual(coordinator.status, .ready, "the next wake may try again")
    }

    func testOccasionalRecognitionErrorsDoNotEndTheScan() async {
        let enrolled = self.enrolled
        let errorLimit = UInt64(FaceUnlockCoordinator.recognitionErrorLimit)
        let flaky = ScriptedScanRecognizer { id in
            // Errors in runs one short of the limit, then the face.
            guard id > 3 * errorLimit else {
                if id % errorLimit == 0 { return nil }
                throw FakeRecognitionError()
            }
            return FaceScan(embedding: enrolled, faceBox: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        let coordinator = await makeCoordinator(makeRecognizer: { flaky })
        await lockAndWake(coordinator)
        XCTAssertEqual(typer.calls, 1)
        XCTAssertEqual(flaky.calls, 3 * FaceUnlockCoordinator.recognitionErrorLimit + 1)
    }

    /// Review #8: the model loads while the camera starts, not before it.
    func testTheModelLoadsWhileTheCameraStarts() async {
        let gate = TestGate(), recognizer = self.recognizer!
        let coordinator = await makeCoordinator(makeRecognizer: {
            gate.wait()
            recognizer.noteCreated()
            return recognizer
        })
        lockAndWakeWithoutWaiting()
        let started = await waitUntil { self.camera.startCount == 1 && gate.waiting == 1 }
        XCTAssertTrue(started, "the camera started while the model was still loading")
        XCTAssertEqual(typer.calls, 0)
        gate.open()
        await settle(coordinator)
        XCTAssertEqual(recognizer.created, 1)
        XCTAssertEqual(typer.calls, 1)
    }

    func testAModelThatFailsToLoadStopsTheCamera() async {
        let coordinator = await makeCoordinator(makeRecognizer: { throw FakeRecognitionError() })
        await lockAndWake(coordinator)
        XCTAssertEqual(coordinator.lastOutcome, .failed("the model is broken"))
        XCTAssertEqual(camera.startCount, 1)
        XCTAssertGreaterThanOrEqual(camera.stopCount, 1)
        XCTAssertFalse(camera.isRunning)
        XCTAssertEqual(typer.calls, 0)
    }

    /// H2: each wake used to give another 2-minute scan without limit.
    func testScanStartsAreCappedPerLockSession() async {
        recognizer.script = { _ in nil }
        let limit = FaceUnlockCoordinator.scanStartsPerLockSession
        let coordinator = await makeCoordinator()
        await lockAndWake(coordinator)
        for _ in 1..<limit { await wakeAgain(coordinator) }
        XCTAssertEqual(camera.startCount, limit)
        XCTAssertEqual(coordinator.scansThisLockSession, limit)
        XCTAssertEqual(coordinator.status, .pausedAfterRejections, "paused, as after two rejected passwords")

        await wakeAgain(coordinator)
        XCTAssertEqual(camera.startCount, limit, "no scan past the limit")
        XCTAssertEqual(coordinator.consecutiveRejections, 0, "not counted as a rejection")

        await unlock(coordinator)
        XCTAssertEqual(coordinator.scansThisLockSession, 0)
        XCTAssertEqual(coordinator.status, .ready)
        await lockAndWake(coordinator)
        XCTAssertEqual(camera.startCount, limit + 1, "a new lock session scans again")
        assertNothingPrompted()
    }

    func testUnlockingTheFaceUnlockSessionLiftsTheScanLimit() async {
        recognizer.script = { _ in nil }
        let limit = FaceUnlockCoordinator.scanStartsPerLockSession
        let coordinator = await makeCoordinator()
        await lockAndWake(coordinator)
        for _ in 1..<limit { await wakeAgain(coordinator) }
        XCTAssertEqual(coordinator.status, .pausedAfterRejections)

        session.lock()
        await session.unlock(reason: "test")
        await settle(coordinator)
        XCTAssertEqual(coordinator.scansThisLockSession, 0)
        await wakeAgain(coordinator)
        XCTAssertEqual(camera.startCount, limit + 1)
    }
}

/// A flag a liveness script reads off the main actor.
nonisolated final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Bool
    init(_ value: Bool) { _value = value }
    var value: Bool {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
