import XCTest
import CoreGraphics
@testable import PopNotch

/// Face Unlock, phase 3: the fail-closed lock-screen guard, the typer's
/// ordering and abort rules, and the password buffer.
final class FaceUnlockLockScreenTests: XCTestCase {

    private let uid: uid_t = 501

    // MARK: - Lock guard parsing (fail closed)

    func testMissingDictionaryIsNeitherLockedNorUnlocked() {
        XCTAssertEqual(LockScreenState.evaluate(nil, uid: uid), .unknown)
    }

    /// Measured on macOS 27.0.1 while unlocked: the lock key is absent.
    func testAbsentLockKeyOnConsoleForThisUserIsUnlocked() {
        let dictionary: [String: Any] = ["kCGSSessionOnConsoleKey": true, "kCGSSessionUserIDKey": 501]
        XCTAssertEqual(LockScreenState.evaluate(dictionary, uid: uid), .unlocked)
    }

    func testLockedOnConsoleForThisUserIsLocked() {
        let dictionary: [String: Any] = ["CGSSessionScreenIsLocked": true,
                                         "kCGSSessionOnConsoleKey": true, "kCGSSessionUserIDKey": 501]
        XCTAssertEqual(LockScreenState.evaluate(dictionary, uid: uid), .locked)
    }

    func testLockedButNotOnConsoleIsUnknown() {
        let dictionary: [String: Any] = ["CGSSessionScreenIsLocked": true,
                                         "kCGSSessionOnConsoleKey": false, "kCGSSessionUserIDKey": 501]
        XCTAssertEqual(LockScreenState.evaluate(dictionary, uid: uid), .unknown)
    }

    func testLockedWithNoConsoleKeyIsUnknown() {
        let dictionary: [String: Any] = ["CGSSessionScreenIsLocked": true, "kCGSSessionUserIDKey": 501]
        XCTAssertEqual(LockScreenState.evaluate(dictionary, uid: uid), .unknown)
    }

    func testAnotherUsersSessionIsUnknown() {
        let dictionary: [String: Any] = ["CGSSessionScreenIsLocked": true,
                                         "kCGSSessionOnConsoleKey": true, "kCGSSessionUserIDKey": 502]
        XCTAssertEqual(LockScreenState.evaluate(dictionary, uid: uid), .unknown)
    }

    func testMissingUserIDIsUnknown() {
        let dictionary: [String: Any] = ["CGSSessionScreenIsLocked": true, "kCGSSessionOnConsoleKey": true]
        XCTAssertEqual(LockScreenState.evaluate(dictionary, uid: uid), .unknown)
    }

    func testMalformedLockValueIsUnknown() {
        let dictionary: [String: Any] = ["CGSSessionScreenIsLocked": "yes",
                                         "kCGSSessionOnConsoleKey": true, "kCGSSessionUserIDKey": 501]
        XCTAssertEqual(LockScreenState.evaluate(dictionary, uid: uid), .unknown)
    }

    func testOnlyLockedMayType() {
        let lockGuard = FakeLockGuard(.locked)
        XCTAssertTrue(lockGuard.mayType())
        lockGuard.displayAsleep = true
        XCTAssertFalse(lockGuard.mayType(), "never with the display asleep")
        lockGuard.displayAsleep = false
        lockGuard.secureInput = false
        XCTAssertFalse(lockGuard.mayType(), "never without the password field (account picker)")
        XCTAssertTrue(lockGuard.isAwakeAtLockScreen())
        lockGuard.secureInput = true
        lockGuard.state = .unknown
        XCTAssertFalse(lockGuard.mayType())
        XCTAssertFalse(lockGuard.isDefinitelyUnlocked(), "unknown is not unlocked either")
    }

    // MARK: - Typer

    private func secret(_ text: String) -> SecretBytes {
        var data = Data(text.utf8)
        return SecretBytes(taking: &data)
    }

    func testTyperClearsTheFieldTypesThenPressesReturn() throws {
        let poster = RecordingKeyPoster()
        let typer = KeystrokeTyper(lockGuard: FakeLockGuard(.locked), accessibility: FakeAccessibility(), poster: poster)
        try typer.typePasswordAndReturn(secret("hunter2"))
        XCTAssertEqual(poster.events, [
            .key(KeystrokeTyper.rightArrowKey, command: true),
            .key(KeystrokeTyper.deleteKey, command: true),
            .unicode(Array("hunter2".utf16)),
            .key(KeystrokeTyper.returnKey, command: false),
        ])
    }

    func testTyperBatchesWithoutSplittingASurrogatePair() throws {
        let poster = RecordingKeyPoster()
        let typer = KeystrokeTyper(lockGuard: FakeLockGuard(.locked), accessibility: FakeAccessibility(), poster: poster)
        // 19 ASCII characters, then an emoji (a surrogate pair) at 20...21.
        let password = String(repeating: "a", count: 19) + "😀" + "bc"
        try typer.typePasswordAndReturn(secret(password))
        let batches = poster.events.compactMap { event -> [UInt16]? in
            if case .unicode(let units) = event { return units }
            return nil
        }
        XCTAssertEqual(batches.count, 2)
        XCTAssertEqual(batches[0].count, 19, "the pair moves whole into the next batch")
        XCTAssertEqual(batches.flatMap { $0 }, Array(password.utf16))
        XCTAssertEqual(poster.events.last, .key(KeystrokeTyper.returnKey, command: false))
    }

    /// The guard flips while typing: typing stops and Return is never pressed.
    func testTyperAbortsWithoutReturnWhenTheLockScreenGoesAway() {
        let poster = RecordingKeyPoster()
        let lockGuard = FakeLockGuard(.locked)
        let typer = KeystrokeTyper(lockGuard: lockGuard, accessibility: FakeAccessibility(), poster: poster)
        // Allowed: before typing, both clears, the first batch; then unlocked.
        lockGuard.flip(afterChecks: 4)
        let password = String(repeating: "x", count: 45)
        XCTAssertThrowsError(try typer.typePasswordAndReturn(secret(password))) { error in
            XCTAssertEqual(error as? KeystrokeTyperError, .stoppedPartway, "keys were posted before it stopped")
        }
        XCTAssertFalse(poster.events.contains(.key(KeystrokeTyper.returnKey, command: false)),
                       "Return must never follow an aborted password")
        XCTAssertEqual(poster.events.filter { if case .unicode = $0 { return true }; return false }.count, 1)
    }

    /// Measured on hardware: secure input off means no password field. If
    /// it drops mid-password, typing stops and Return is never pressed.
    func testTyperAbortsWithoutReturnWhenSecureInputDrops() {
        let poster = RecordingKeyPoster()
        let lockGuard = FakeLockGuard(.locked)
        poster.onPost = { event in
            if case .unicode = event { lockGuard.secureInput = false }
        }
        let typer = KeystrokeTyper(lockGuard: lockGuard, accessibility: FakeAccessibility(), poster: poster)
        let password = String(repeating: "x", count: 45)
        XCTAssertThrowsError(try typer.typePasswordAndReturn(secret(password))) { error in
            XCTAssertEqual(error as? KeystrokeTyperError, .stoppedPartway)
        }
        XCTAssertFalse(poster.events.contains(.key(KeystrokeTyper.returnKey, command: false)),
                       "Return must never follow a password the field lost")
        XCTAssertEqual(poster.events.filter { if case .unicode = $0 { return true }; return false }.count, 1,
                       "the next batch was checked and refused")
    }

    func testTyperPostsNothingWithSecureInputOff() {
        let poster = RecordingKeyPoster()
        let lockGuard = FakeLockGuard(.locked)
        lockGuard.secureInput = false
        let typer = KeystrokeTyper(lockGuard: lockGuard, accessibility: FakeAccessibility(), poster: poster)
        XCTAssertThrowsError(try typer.typePasswordAndReturn(secret("hunter2")))
        XCTAssertTrue(poster.events.isEmpty, "nothing typed into the account picker")
    }

    func testTyperAbortsBeforeReturnWhenTheGuardFlipsOnTheLastCheck() {
        let poster = RecordingKeyPoster()
        let lockGuard = FakeLockGuard(.locked)
        let typer = KeystrokeTyper(lockGuard: lockGuard, accessibility: FakeAccessibility(), poster: poster)
        lockGuard.flip(afterChecks: 4) // before, clear, clear, one batch
        XCTAssertThrowsError(try typer.typePasswordAndReturn(secret("short")))
        XCTAssertFalse(poster.events.contains(.key(KeystrokeTyper.returnKey, command: false)))
    }

    func testTyperPostsNothingWhenNotLocked() {
        for state in [LockScreenState.unlocked, .unknown] {
            let poster = RecordingKeyPoster()
            let typer = KeystrokeTyper(lockGuard: FakeLockGuard(state), accessibility: FakeAccessibility(), poster: poster)
            XCTAssertThrowsError(try typer.typePasswordAndReturn(secret("hunter2")))
            XCTAssertTrue(poster.events.isEmpty)
        }
    }

    func testTyperPostsNothingWithTheDisplayAsleep() {
        let poster = RecordingKeyPoster()
        let lockGuard = FakeLockGuard(.locked)
        lockGuard.displayAsleep = true
        let typer = KeystrokeTyper(lockGuard: lockGuard, accessibility: FakeAccessibility(), poster: poster)
        XCTAssertThrowsError(try typer.typePasswordAndReturn(secret("hunter2")))
        XCTAssertTrue(poster.events.isEmpty)
    }

    func testTyperPostsNothingWithoutAccessibility() {
        let poster = RecordingKeyPoster()
        let typer = KeystrokeTyper(lockGuard: FakeLockGuard(.locked),
                                   accessibility: FakeAccessibility(trusted: false), poster: poster)
        XCTAssertThrowsError(try typer.typePasswordAndReturn(secret("hunter2"))) { error in
            XCTAssertEqual(error as? KeystrokeTyperError, .accessibilityNotGranted)
        }
        XCTAssertTrue(poster.events.isEmpty)
    }

    func testTyperRefusesInvalidUTF8() {
        let poster = RecordingKeyPoster()
        let typer = KeystrokeTyper(lockGuard: FakeLockGuard(.locked), accessibility: FakeAccessibility(), poster: poster)
        var data = Data([0x61, 0xFF, 0x62])
        XCTAssertThrowsError(try typer.typePasswordAndReturn(SecretBytes(taking: &data))) { error in
            XCTAssertEqual(error as? KeystrokeTyperError, .invalidPassword)
        }
        XCTAssertFalse(poster.events.contains(.key(KeystrokeTyper.returnKey, command: false)))
    }

    // MARK: - Password buffer

    func testTakingZeroesTheSourceAndWipeZeroesTheBuffer() {
        for text in ["short", String(repeating: "long password ", count: 4)] {
            var data = Data(text.utf8)
            let bytes = SecretBytes(taking: &data)
            XCTAssertTrue(data.allSatisfy { $0 == 0 }, "the caller's copy is zeroed in place")
            XCTAssertEqual(bytes.withUnsafeBytes { Array($0) }, Array(text.utf8))
            bytes.wipe()
            XCTAssertTrue(bytes.isWiped)
        }
    }
}

// MARK: - Secure input owner, typer report, frame demand (review fixes)

extension FaceUnlockLockScreenTests {

    func testSecureInputOwnerPIDFailsClosed() {
        let key = SecureInputOwner.pidKey
        XCTAssertNil(SecureInputOwner.pid(from: nil))
        XCTAssertNil(SecureInputOwner.pid(from: [:]), "absent")
        XCTAssertNil(SecureInputOwner.pid(from: [key: "123"]), "not an integer")
        XCTAssertNil(SecureInputOwner.pid(from: [key: 0]))
        XCTAssertNil(SecureInputOwner.pid(from: [key: -4]))
        XCTAssertNil(SecureInputOwner.pid(from: [key: Int(Int32.max) + 1]))
        XCTAssertEqual(SecureInputOwner.pid(from: [key: 123]), 123)
        XCTAssertEqual(SecureInputOwner.pid(from: [key: NSNumber(value: 456)]), 456, "as the CF dictionary has it")
    }

    func testSecureInputOwnerNameFailsClosed() {
        let dictionary: [String: Any] = [SecureInputOwner.pidKey: 77]
        XCTAssertNil(SecureInputOwner.name(from: dictionary) { _ in nil }, "an unresolvable PID")
        XCTAssertNil(SecureInputOwner.name(from: dictionary) { _ in "" })
        XCTAssertNil(SecureInputOwner.name(from: [:]) { _ in "loginwindow" }, "no PID")
        var asked: pid_t?
        XCTAssertEqual(SecureInputOwner.name(from: dictionary) { asked = $0; return "loginwindow" }, "loginwindow")
        XCTAssertEqual(asked, 77)
    }

    func testProcessNameResolvesThisProcessAndNotABogusPID() {
        XCTAssertNotNil(SecureInputOwner.processName(getpid()))
        XCTAssertNil(SecureInputOwner.processName(-1))
    }

    /// Secure input is system-wide: only loginwindow's is the password field.
    func testOnlyLoginwindowsSecureInputIsThePasswordField() {
        let lockGuard = FakeLockGuard(.locked)
        for owner in ["Terminal", "1Password", "LoginWindow", "loginwindow2"] {
            lockGuard.secureInputOwner = owner
            XCTAssertFalse(lockGuard.mayType(), owner)
            XCTAssertEqual(lockGuard.secureInputSummary(), "secure input held by \(owner)")
        }
        lockGuard.secureInputOwner = nil
        XCTAssertFalse(lockGuard.mayType(), "an unknown holder")
        XCTAssertEqual(lockGuard.secureInputSummary(), "secure input held by an unknown process")
        lockGuard.secureInputOwner = SecureInputOwner.loginWindow
        XCTAssertTrue(lockGuard.mayType())
        lockGuard.secureInput = false
        XCTAssertFalse(lockGuard.mayType(), "a stale owner with secure input off")
        XCTAssertEqual(lockGuard.secureInputSummary(), "secure input off")
    }

    func testTyperPostsNothingWhenAnotherAppHoldsSecureInput() {
        let poster = RecordingKeyPoster()
        let lockGuard = FakeLockGuard(.locked)
        lockGuard.secureInputOwner = "Terminal"
        let typer = KeystrokeTyper(lockGuard: lockGuard, accessibility: FakeAccessibility(), poster: poster)
        XCTAssertThrowsError(try typer.typePasswordAndReturn(secret("hunter2"))) { error in
            XCTAssertEqual(error as? KeystrokeTyperError, .notAtLockScreen)
        }
        XCTAssertTrue(poster.events.isEmpty)
    }

    /// Finding 5: the typer says whether anything reached the field.
    func testTyperReportsWhetherAnyKeyWasPosted() {
        let untouched = RecordingKeyPoster()
        let off = FakeLockGuard(.locked)
        off.secureInput = false
        XCTAssertThrowsError(try KeystrokeTyper(lockGuard: off, accessibility: FakeAccessibility(), poster: untouched)
            .typePasswordAndReturn(secret("hunter2"))) { error in
            XCTAssertEqual(error as? KeystrokeTyperError, .notAtLockScreen)
            XCTAssertEqual((error as? KeystrokeTyperError)?.postedNothing, true)
        }
        XCTAssertTrue(untouched.events.isEmpty)

        let poster = RecordingKeyPoster()
        let lockGuard = FakeLockGuard(.locked)
        lockGuard.flip(afterChecks: 2) // before typing, the first clear; then gone
        XCTAssertThrowsError(try KeystrokeTyper(lockGuard: lockGuard, accessibility: FakeAccessibility(), poster: poster)
            .typePasswordAndReturn(secret("hunter2"))) { error in
            XCTAssertEqual(error as? KeystrokeTyperError, .stoppedPartway)
            XCTAssertEqual((error as? KeystrokeTyperError)?.postedNothing, false)
        }
        XCTAssertEqual(poster.events, [.key(KeystrokeTyper.rightArrowKey, command: true)])
    }

    /// Enrolment keeps every frame; a scan's slow phase converts one per
    /// request.
    func testFrameDemandConvertsEveryFrameByDefaultAndOnePerRequestOtherwise() {
        let demand = FrameDemand()
        XCTAssertTrue(demand.convertsEveryFrame)
        XCTAssertTrue(demand.takeFrame())
        XCTAssertTrue(demand.takeFrame())

        demand.setConvertsEveryFrame(false)
        XCTAssertFalse(demand.takeFrame(), "nothing asked for")
        demand.request()
        demand.request()
        XCTAssertTrue(demand.takeFrame())
        XCTAssertFalse(demand.takeFrame(), "one frame per request, however many")

        demand.request()
        demand.setConvertsEveryFrame(false)
        XCTAssertFalse(demand.takeFrame(), "a mode change drops a pending request")
        demand.setConvertsEveryFrame(true)
        XCTAssertTrue(demand.takeFrame())
    }

    func testUnknownReasonNamesTheFailedCheck() {
        let uid: uid_t = 501
        XCTAssertEqual(LockScreenState.unknownReason(nil, uid: uid), "no session dictionary")
        XCTAssertEqual(LockScreenState.unknownReason(["kCGSSessionUserIDKey": 501], uid: uid),
                       "session not on the console")
        XCTAssertEqual(LockScreenState.unknownReason(["kCGSSessionOnConsoleKey": true, "kCGSSessionUserIDKey": 502], uid: uid),
                       "no user ID, or another user's session")
        XCTAssertEqual(LockScreenState.unknownReason(["kCGSSessionOnConsoleKey": true, "kCGSSessionUserIDKey": 501,
                                                      "CGSSessionScreenIsLocked": "yes"], uid: uid),
                       "lock value of an unexpected type")
        XCTAssertEqual(LockScreenState.unknownReason(["kCGSSessionOnConsoleKey": true, "kCGSSessionUserIDKey": 501], uid: uid),
                       "none")
    }
}
