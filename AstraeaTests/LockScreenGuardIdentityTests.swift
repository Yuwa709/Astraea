import XCTest
import CoreGraphics
@testable import Astraea

/// Security review M2: the secure-input holder is trusted as loginwindow
/// only by code identity, never by name. Lock-screen review L1: a key press
/// is all-or-nothing, so ⌘ is never left held down.
final class LockScreenGuardIdentityTests: XCTestCase {

    private static let loginWindowPath = LoginWindowIdentity.executablePath

    /// A locked session for this user, on the console, with `pid` holding
    /// secure input.
    private static func lockedSession(holder pid: pid_t) -> [String: Any] {
        [LockScreenState.screenIsLockedKey: true,
         LockScreenState.onConsoleKey: true,
         LockScreenState.userIDKey: Int(getuid()),
         SecureInputOwner.pidKey: Int(pid)]
    }

    /// The real guard with a scripted session; name and identity are the
    /// real libproc and Security checks unless replaced.
    private static func guardFor(holder pid: pid_t,
                                 processName: (@Sendable (pid_t) -> String?)? = nil,
                                 verify: (@Sendable (pid_t) -> LoginWindowIdentity)? = nil) -> SystemLockScreenGuard {
        let session = lockedSession(holder: pid)
        return SystemLockScreenGuard(sessionDictionary: { session }, secureInputEnabled: { true },
                                     processName: processName, verifyLoginWindow: verify,
                                     displayAsleep: { false })
    }

    // MARK: - The decision, pure

    func testAProcessNamedLoginwindowAtAnotherPathIsRejectedBeforeItsSignature() {
        for path in ["/tmp/x/loginwindow", "/Applications/loginwindow.app/Contents/MacOS/loginwindow",
                     Self.loginWindowPath + "2", "/System/Library/CoreServices/loginwindow.app/Contents/MacOS/../MacOS/loginwindow"] {
            let verdict = LoginWindowIdentity.evaluate(pid: 77, path: { _ in path }, signature: { _ in
                XCTFail("the signature is not consulted for \(path)")
                return .verified
            })
            XCTAssertEqual(verdict, .rejected("executable is not at loginwindow's system path"), path)
        }
    }

    func testIdentityFailsClosed() {
        XCTAssertEqual(LoginWindowIdentity.evaluate(pid: 77, path: { _ in nil }, signature: { _ in .verified }),
                       .rejected("executable path unavailable"))
        XCTAssertEqual(LoginWindowIdentity.evaluate(pid: 77, path: { _ in Self.loginWindowPath },
                                                    signature: { _ in .rejected("bad signature") }),
                       .rejected("bad signature"), "the right path alone is not enough")
        var asked: pid_t?
        XCTAssertEqual(LoginWindowIdentity.evaluate(pid: 77, path: { _ in Self.loginWindowPath },
                                                    signature: { asked = $0; return .verified }), .verified)
        XCTAssertEqual(asked, 77)
    }

    func testVerifiedNameIsLoginwindowOnlyWhenTheIdentityHolds() {
        let session: [String: Any] = [SecureInputOwner.pidKey: 77]
        let named: (pid_t) -> String? = { _ in SecureInputOwner.loginWindow }
        XCTAssertEqual(SecureInputOwner.verifiedName(from: session, resolve: named, verify: { _ in .verified }),
                       SecureInputOwner.loginWindow)
        let impostor = SecureInputOwner.verifiedName(from: session, resolve: named,
                                                     verify: { _ in .rejected("not at the path") })
        XCTAssertNotNil(impostor)
        XCTAssertNotEqual(impostor, SecureInputOwner.loginWindow)
        XCTAssertEqual(impostor, "loginwindow (failed the identity check: not at the path)")
        // Other holders are reported by name without the (costly) check.
        XCTAssertEqual(SecureInputOwner.verifiedName(from: session, resolve: { _ in "Terminal" }, verify: { _ in
            XCTFail("only a holder named loginwindow is checked")
            return .verified
        }), "Terminal")
        XCTAssertNil(SecureInputOwner.verifiedName(from: [:], resolve: named, verify: { _ in .verified }))
    }

    // MARK: - The real checks, on real processes

    /// An impostor: this test process, at its own path, answering to the
    /// name loginwindow. The real path and Security checks must refuse it,
    /// and the real guard must not type.
    func testAnImpostorNamedLoginwindowCannotOpenTheTypingGate() {
        let impostor = Self.guardFor(holder: getpid(), processName: { _ in SecureInputOwner.loginWindow })
        XCTAssertTrue(impostor.isAwakeAtLockScreen(), "everything else says type")
        XCTAssertFalse(impostor.isPasswordFieldFocused())
        XCTAssertFalse(impostor.mayType())
        XCTAssertNotEqual(impostor.secureInputOwnerName(), SecureInputOwner.loginWindow)
        XCTAssertTrue(impostor.secureInputSummary().contains("failed the identity check"), impostor.secureInputSummary())
        XCTAssertEqual(LoginWindowIdentity.verify(getpid()), .rejected("executable is not at loginwindow's system path"))
    }

    /// The signature check alone, bypassing the path: this process is not
    /// Apple's, and launchd is Apple's but not loginwindow (the renamed
    /// Apple binary case). A PID that does not exist resolves to nothing.
    func testTheSignatureCheckRejectsAnythingButLoginwindow() {
        for pid in [getpid(), 1, pid_t(Int32.max)] {
            guard case .rejected = LoginWindowIdentity.checkSignature(pid) else {
                return XCTFail("pid \(pid) passed the loginwindow signature check")
            }
        }
        if case .rejected = LoginWindowIdentity.verify(1) {} else { XCTFail("launchd verified as loginwindow") }
    }

    func testProcessPathResolvesThisProcessAndNotABogusPID() {
        let path = SecureInputOwner.processPath(getpid())
        XCTAssertTrue(path?.hasPrefix("/") == true, path ?? "nil")
        XCTAssertEqual(path.map { ($0 as NSString).lastPathComponent }, SecureInputOwner.processName(getpid()))
        XCTAssertNil(SecureInputOwner.processPath(-1))
    }

    /// The positive path on a real Mac: the running loginwindow passes both
    /// checks, and the real guard opens the gate for it. Skipped where no
    /// loginwindow runs (no GUI session).
    func testTheRealLoginwindowIsVerified() throws {
        guard let pid = Self.runningLoginWindowPID() else { throw XCTSkip("no loginwindow process") }
        XCTAssertEqual(LoginWindowIdentity.verify(pid), .verified)
        let lockGuard = Self.guardFor(holder: pid)
        XCTAssertEqual(lockGuard.secureInputOwnerName(), SecureInputOwner.loginWindow)
        XCTAssertTrue(lockGuard.mayType())
    }

    private static func runningLoginWindowPID() -> pid_t? {
        let capacity = 8192
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return nil }
        return pids.prefix(Int(count)).first { pid in
            pid > 0 && SecureInputOwner.processName(pid) == SecureInputOwner.loginWindow
                && SecureInputOwner.processPath(pid) == loginWindowPath
        }
    }

    // MARK: - Key presses, all or nothing (review L1)

    /// Records what would have been posted, and fails the Nth creation.
    private final class EventRecorder: @unchecked Sendable {
        var created = 0
        var failOnCreation: Int?
        var posted: [(key: Int64, down: Bool, command: Bool)] = []
        /// Down or up, as asked at creation: a modifier's event is
        /// `.flagsChanged` either way, so its type cannot tell.
        private var isDown: [ObjectIdentifier: Bool] = [:]

        func make(_ key: CGKeyCode, _ down: Bool) -> CGEvent? {
            created += 1
            if created == failOnCreation { return nil }
            let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down)
            if let event { isDown[ObjectIdentifier(event)] = down }
            return event
        }

        func post(_ event: CGEvent) {
            posted.append((event.getIntegerValueField(.keyboardEventKeycode), isDown[ObjectIdentifier(event)] ?? false,
                           event.flags.contains(.maskCommand)))
        }

        var poster: CGEventKeyPoster {
            CGEventKeyPoster(makeEvent: { self.make($0, $1) }, post: { self.post($0) }, pause: { _ in })
        }
    }

    func testACommandKeyPressIsBalanced() throws {
        let recorder = EventRecorder()
        try recorder.poster.postKey(KeystrokeTyper.deleteKey, withCommand: true)
        let command = Int64(CGEventKeyPoster.commandKey)
        let delete = Int64(KeystrokeTyper.deleteKey)
        XCTAssertEqual(recorder.posted.map(\.key), [command, delete, delete, command])
        XCTAssertEqual(recorder.posted.map(\.down), [true, true, false, false])
        XCTAssertEqual(recorder.posted.map(\.command), [true, true, true, false], "⌘ released last, flag cleared")
    }

    func testAPlainKeyPressHasNoCommand() throws {
        let recorder = EventRecorder()
        try recorder.poster.postKey(KeystrokeTyper.returnKey, withCommand: false)
        XCTAssertEqual(recorder.posted.map(\.key), [Int64(KeystrokeTyper.returnKey), Int64(KeystrokeTyper.returnKey)])
        XCTAssertEqual(recorder.posted.map(\.command), [false, false])
    }

    /// Whichever of the four events cannot be created, nothing is posted:
    /// no ⌘ down without its ⌘ up.
    func testAFailedEventCreationPostsNothing() {
        for failing in 1...4 {
            let recorder = EventRecorder()
            recorder.failOnCreation = failing
            XCTAssertThrowsError(try recorder.poster.postKey(KeystrokeTyper.rightArrowKey, withCommand: true)) { error in
                XCTAssertEqual(error as? KeystrokeTyperError, .eventCreationFailed, "creation \(failing)")
            }
            XCTAssertTrue(recorder.posted.isEmpty, "creation \(failing) failed, yet something was posted")
        }
    }

    func testAFailedUnicodeEventPostsNothing() {
        for failing in 1...2 {
            let recorder = EventRecorder()
            recorder.failOnCreation = failing
            let units: [UInt16] = Array("ab".utf16)
            let poster = recorder.poster
            let result = units.withUnsafeBufferPointer { buffer in Result { try poster.postUnicode(buffer) } }
            XCTAssertThrowsError(try result.get())
            XCTAssertTrue(recorder.posted.isEmpty)
        }
    }
}
