// Adapted from Glance (github.com/jonnyoo/glance), MIT, (c) 2026 Jonathan Zhou.
// See THIRD-PARTY-LICENSES.md.

import Foundation
import Carbon
import CoreGraphics
import Security
import os

/// What the CoreGraphics session server says about this user's screen.
///
/// The authority for every decision that types a password. Lock and unlock
/// notifications are only triggers: any process running as the user can
/// post them, and this process can be suspended before one is delivered.
nonisolated enum LockScreenState: Equatable, Sendable {
    /// Locked, this user's session, on the console.
    case locked
    /// This user's session, on the console, and not locked.
    case unlocked
    /// No session dictionary, another user's session, not on the console,
    /// or a value of the wrong type. Neither "locked" nor "unlocked".
    case unknown

    static let screenIsLockedKey = "CGSSessionScreenIsLocked"
    static let onConsoleKey = "kCGSSessionOnConsoleKey"
    static let userIDKey = "kCGSSessionUserIDKey"

    /// Pure, so the fail-closed rules are testable. Measured on macOS 27.0.1
    /// while unlocked: `CGSSessionScreenIsLocked` is absent, the console key
    /// is 1 and the user ID is the user's uid. An absent lock key therefore
    /// means unlocked, but only for this user's session on the console.
    static func evaluate(_ dictionary: [String: Any]?, uid: uid_t) -> LockScreenState {
        guard let dictionary,
              dictionary[onConsoleKey] as? Bool == true,
              let userID = dictionary[userIDKey] as? Int, userID == Int(uid) else {
            return .unknown
        }
        guard let lockValue = dictionary[screenIsLockedKey] else { return .unlocked }
        switch lockValue as? Bool {
        case true?: return .locked
        case false?: return .unlocked
        case nil: return .unknown
        }
    }

    /// Why `evaluate` said `.unknown`, for the logs. Names a check, never a
    /// value from the dictionary.
    static func unknownReason(_ dictionary: [String: Any]?, uid: uid_t) -> String {
        guard let dictionary else { return "no session dictionary" }
        guard dictionary[onConsoleKey] as? Bool == true else { return "session not on the console" }
        guard let userID = dictionary[userIDKey] as? Int, userID == Int(uid) else {
            return "no user ID, or another user's session"
        }
        if let lockValue = dictionary[screenIsLockedKey], !(lockValue is Bool) {
            return "lock value of an unexpected type"
        }
        return "none"
    }
}

/// Who holds Secure Event Input, from the session dictionary.
///
/// Secure input is system-wide: `IsSecureEventInputEnabled()` is true while
/// any app holds it (Terminal's Secure Keyboard Entry, a password manager),
/// so on its own it cannot say the lock screen's password field is up.
/// Measured on macOS 27.0.1 (2026-10-15): while secure input is on, the
/// session dictionary carries the holder's PID, and macOS reports the
/// responsible app (a command-line tool's PID came back as Terminal's). At
/// the lock screen the holder should be loginwindow; not yet seen on
/// hardware, so every gap fails closed.
nonisolated enum SecureInputOwner {
    static let pidKey = "kCGSSessionSecureInputPID"
    /// The lock screen's process name, compared exactly.
    static let loginWindow = "loginwindow"

    /// Pure, so the fail-closed rules are testable: nil when the key is
    /// absent, not an integer, or not a plausible PID.
    static func pid(from dictionary: [String: Any]?) -> pid_t? {
        guard let value = dictionary?[pidKey] as? Int, value > 0, value <= Int(Int32.max) else { return nil }
        return pid_t(value)
    }

    /// The holder's process name, or nil when there is no PID or `resolve`
    /// cannot name it.
    static func name(from dictionary: [String: Any]?, resolve: (pid_t) -> String?) -> String? {
        guard let pid = pid(from: dictionary), let name = resolve(pid), !name.isEmpty else { return nil }
        return name
    }

    /// The holder's name for the typing gate. A process merely *named*
    /// loginwindow is not trusted: it is `loginWindow` only when `verify`
    /// says its code is the real loginwindow. An impostor gets a name that
    /// can never equal `loginWindow`, so every comparison fails closed.
    static func verifiedName(from dictionary: [String: Any]?, resolve: (pid_t) -> String?,
                             verify: (pid_t) -> LoginWindowIdentity) -> String? {
        guard let pid = pid(from: dictionary), let name = resolve(pid), !name.isEmpty else { return nil }
        guard name == loginWindow else { return name }
        let verdict = verify(pid)
        LoginWindowIdentity.logIfChanged(pid: pid, verdict)
        switch verdict {
        case .verified: return loginWindow
        case .rejected(let reason): return "\(name) (failed the identity check: \(reason))"
        }
    }

    /// The process name from libproc, or nil.
    static func processName(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// The executable's full path from libproc, or nil.
    static func processPath(_ pid: pid_t) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE, a macro Swift does not import.
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

/// Whether a process is the real loginwindow, by what it is rather than what
/// it is called: `proc_name` is whatever the binary's file is named, so any
/// same-user program can call itself loginwindow (security review M2).
///
/// Two independent checks, both required:
/// 1. The executable is at loginwindow's path on the sealed, SIP-protected
///    system volume, where nothing but an OS install can put a binary.
/// 2. The running code satisfies `anchor apple and identifier
///    "com.apple.loginwindow"`: Apple-signed with loginwindow's identifier,
///    so a renamed copy of another Apple binary fails too.
/// Any API failure is a rejection. Measured on macOS 27.0.1 (2026-10-15):
/// the real loginwindow passes both in 2-11 ms; launchd fails the
/// requirement (-67050); a PID that has gone fails to resolve (100003).
///
/// Looked up by PID, so a PID reused between the check and the keystroke
/// is not covered; the window is milliseconds, and the gate re-runs before
/// every key group.
nonisolated enum LoginWindowIdentity: Equatable, Sendable {
    case verified
    /// Names the check that failed, never anything secret.
    case rejected(String)

    static let executablePath = "/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow"
    static let codeRequirement = "anchor apple and identifier \"com.apple.loginwindow\""

    private static let logger = Logger(subsystem: "com.techie.Astraea", category: "FaceUnlock")
    /// The last verdict logged, as "pid verdict", so the gate's repeated
    /// checks log once per change rather than once per key group.
    private static let lastLogged = OSAllocatedUnfairLock<String?>(initialState: nil)

    /// The real checks.
    static func verify(_ pid: pid_t) -> LoginWindowIdentity {
        evaluate(pid: pid, path: SecureInputOwner.processPath, signature: checkSignature)
    }

    /// Pure, so the order and fail-closed rules are testable: the path
    /// first (cheap), then the signature, which only a process at the right
    /// path reaches.
    static func evaluate(pid: pid_t, path: (pid_t) -> String?,
                         signature: (pid_t) -> LoginWindowIdentity) -> LoginWindowIdentity {
        guard let actual = path(pid) else { return .rejected("executable path unavailable") }
        guard actual == executablePath else { return .rejected("executable is not at loginwindow's system path") }
        return signature(pid)
    }

    /// The code-signing check on the running process, by PID.
    static func checkSignature(_ pid: pid_t) -> LoginWindowIdentity {
        var requirement: SecRequirement?
        let compiled = SecRequirementCreateWithString(codeRequirement as CFString, [], &requirement)
        guard compiled == errSecSuccess, let requirement else {
            return .rejected("code requirement did not compile (OSStatus \(compiled))")
        }
        var code: SecCode?
        let attributes = [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary
        let found = SecCodeCopyGuestWithAttributes(nil, attributes, [], &code)
        guard found == errSecSuccess, let code else {
            return .rejected("no code object for the process (OSStatus \(found))")
        }
        let valid = SecCodeCheckValidity(code, [], requirement)
        guard valid == errSecSuccess else {
            return .rejected("code signature is not Apple's loginwindow (OSStatus \(valid))")
        }
        return .verified
    }

    /// `.notice`, once per change of holder or verdict.
    static func logIfChanged(pid: pid_t, _ verdict: LoginWindowIdentity) {
        let key = "\(pid) \(verdict)"
        let changed = lastLogged.withLock { last -> Bool in
            guard last != key else { return false }
            last = key
            return true
        }
        guard changed else { return }
        switch verdict {
        case .verified:
            logger.notice("Secure input holder pid \(pid, privacy: .public) verified as loginwindow: system path, Apple signature, identifier com.apple.loginwindow")
        case .rejected(let reason):
            logger.notice("Secure input holder pid \(pid, privacy: .public) is named loginwindow but failed the identity check (\(reason, privacy: .public)); typing refused")
        }
    }
}

/// The lock-screen checks, behind a protocol so tests can fake them.
/// Called from the main actor and from the typing thread alike.
nonisolated protocol LockScreenGuard: Sendable {
    func currentState() -> LockScreenState
    /// Which check made `currentState()` unknown, for the logs.
    func unknownReason() -> String
    /// Secure Event Input, held by anyone. Measured on macOS 27.0.1
    /// (2026-10-15): at the lock screen it is on exactly while the password
    /// field is up, and off on the account picker, where typed keys are not
    /// a password. System-wide, so typing also needs `secureInputOwnerName()`.
    func isSecureInputEnabled() -> Bool
    /// The process holding secure input, by name, or nil when unknown.
    /// `SecureInputOwner.loginWindow` only for the verified loginwindow
    /// (`LoginWindowIdentity`), never for a process merely named so.
    func secureInputOwnerName() -> String?
    func isMainDisplayAsleep() -> Bool
}

nonisolated extension LockScreenGuard {
    func unknownReason() -> String { "unavailable" }

    /// True only when the session server positively says this user's screen
    /// is locked. Anything else, including no answer, is false: we never
    /// type on a guess.
    func isAtLockScreen() -> Bool { currentState() == .locked }

    /// True only when the session server positively says this user's screen
    /// is unlocked. The owner-check prompt after login waits for this, so a
    /// missing answer never lets it show at the lock screen.
    func isDefinitelyUnlocked() -> Bool { currentState() == .unlocked }

    /// At the lock screen with the display on: everything typing needs but
    /// the password field.
    func isAwakeAtLockScreen() -> Bool { isAtLockScreen() && !isMainDisplayAsleep() }

    /// The lock screen's password field has focus: secure input is on and
    /// the verified loginwindow holds it. Another app's secure input (seen
    /// from the account picker, say), or an impostor's, is not the field.
    func isPasswordFieldFocused() -> Bool {
        isSecureInputEnabled() && secureInputOwnerName() == SecureInputOwner.loginWindow
    }

    /// The typing gate: at the lock screen, with the display on and the
    /// password field focused.
    func mayType() -> Bool { isAwakeAtLockScreen() && isPasswordFieldFocused() }

    /// For the logs: on or off, and the holder's process name only.
    func secureInputSummary() -> String {
        guard isSecureInputEnabled() else { return "secure input off" }
        return "secure input held by \(secureInputOwnerName() ?? "an unknown process")"
    }
}

/// The real Mac. Every probe is injectable, so tests run the real decision
/// logic, and the real identity check, against a scripted session.
nonisolated struct SystemLockScreenGuard: LockScreenGuard {

    typealias SessionDictionary = @Sendable () -> [String: Any]?

    private let sessionDictionary: SessionDictionary
    private let secureInputEnabled: @Sendable () -> Bool
    private let processName: @Sendable (pid_t) -> String?
    private let verifyLoginWindow: @Sendable (pid_t) -> LoginWindowIdentity
    private let displayAsleep: @Sendable () -> Bool

    /// Every probe defaults to the real Mac.
    init(sessionDictionary: SessionDictionary? = nil,
         secureInputEnabled: (@Sendable () -> Bool)? = nil,
         processName: (@Sendable (pid_t) -> String?)? = nil,
         verifyLoginWindow: (@Sendable (pid_t) -> LoginWindowIdentity)? = nil,
         displayAsleep: (@Sendable () -> Bool)? = nil) {
        self.sessionDictionary = sessionDictionary ?? { CGSessionCopyCurrentDictionary() as? [String: Any] }
        self.secureInputEnabled = secureInputEnabled ?? { IsSecureEventInputEnabled() }
        self.processName = processName ?? { SecureInputOwner.processName($0) }
        self.verifyLoginWindow = verifyLoginWindow ?? { LoginWindowIdentity.verify($0) }
        self.displayAsleep = displayAsleep ?? { CGDisplayIsAsleep(CGMainDisplayID()) != 0 }
    }

    func currentState() -> LockScreenState {
        LockScreenState.evaluate(sessionDictionary(), uid: getuid())
    }

    func unknownReason() -> String {
        LockScreenState.unknownReason(sessionDictionary(), uid: getuid())
    }

    func isSecureInputEnabled() -> Bool {
        secureInputEnabled()
    }

    /// Fresh every call: a verdict is never cached, so a holder that
    /// changes between key groups is checked again.
    func secureInputOwnerName() -> String? {
        SecureInputOwner.verifiedName(from: sessionDictionary(), resolve: processName, verify: verifyLoginWindow)
    }

    func isMainDisplayAsleep() -> Bool {
        displayAsleep()
    }
}
