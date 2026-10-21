// Adapted from Glance (github.com/jonnyoo/glance), MIT, (c) 2026 Jonathan Zhou.
// See THIRD-PARTY-LICENSES.md.

import ApplicationServices
import CoreGraphics
import Foundation
import os

nonisolated enum KeystrokeTyperError: LocalizedError, Equatable {
    case accessibilityNotGranted
    /// The lock screen went away, the display slept, or the password field
    /// lost focus, before the first key event. Nothing was posted.
    case notAtLockScreen
    /// The same, after at least one key event was posted: part of the
    /// password may be in the field. Return was not pressed.
    case stoppedPartway
    case invalidPassword
    case eventCreationFailed

    var errorDescription: String? {
        switch self {
        case .accessibilityNotGranted: "Astraea needs Accessibility permission to type your password."
        case .notAtLockScreen: "The Mac's password field was no longer showing, so nothing was typed."
        case .stoppedPartway: "The Mac's password field went away partway through, so typing stopped before Return."
        case .invalidPassword: "The stored password could not be typed."
        case .eventCreationFailed: "A keystroke could not be created."
        }
    }

    /// Thrown before any key event was posted, so the field is untouched.
    var postedNothing: Bool {
        switch self {
        case .accessibilityNotGranted, .notAtLockScreen, .invalidPassword: true
        case .stoppedPartway, .eventCreationFailed: false
        }
    }
}

/// Accessibility (the permission CGEvent posting needs). Never prompts
/// except through `requestTrust()`.
nonisolated protocol AccessibilityAuthorizing: Sendable {
    func isTrusted() -> Bool
    /// Shows the system's Accessibility prompt. For a Settings button only.
    func requestTrust()
}

nonisolated struct SystemAccessibility: AccessibilityAuthorizing {
    func isTrusted() -> Bool { AXIsProcessTrusted() }

    func requestTrust() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}

/// Types a password and presses Return. Blocking: callers run it off the
/// main actor.
nonisolated protocol PasswordTyping: Sendable {
    func typePasswordAndReturn(_ password: SecretBytes) throws
}

/// The raw key events, behind a protocol so the typer's ordering and abort
/// rules are testable without posting anything.
nonisolated protocol KeyEventPosting: Sendable {
    func postKey(_ keyCode: CGKeyCode, withCommand: Bool) throws
    func postUnicode(_ units: UnsafeBufferPointer<UInt16>) throws
}

/// Clears the focused field, types the password in small Unicode batches,
/// then presses Return.
///
/// **Strict:** the lock-screen guard is re-checked before the first event
/// and before every key group after it. The moment it says anything but
/// "locked, display on, password field focused", typing stops and Return is
/// never pressed: half a
/// password typed into whatever took focus is bad, a whole one followed by
/// Return is worse.
nonisolated struct KeystrokeTyper: PasswordTyping {

    private static let logger = Logger(subsystem: "com.techie.Astraea", category: "FaceUnlock")

    static let rightArrowKey: CGKeyCode = 0x7C
    static let deleteKey: CGKeyCode = 0x33
    static let returnKey: CGKeyCode = 0x24
    /// Quartz reliably delivers only a short Unicode payload per event.
    static let maximumBatchLength = 20

    let lockGuard: any LockScreenGuard
    let accessibility: any AccessibilityAuthorizing
    let poster: any KeyEventPosting

    init(lockGuard: any LockScreenGuard = SystemLockScreenGuard(),
         accessibility: any AccessibilityAuthorizing = SystemAccessibility(),
         poster: any KeyEventPosting = CGEventKeyPoster()) {
        self.lockGuard = lockGuard
        self.accessibility = accessibility
        self.poster = poster
    }

    /// Throws `.notAtLockScreen` when it stopped before posting anything,
    /// `.stoppedPartway` when it stopped after.
    func typePasswordAndReturn(_ password: SecretBytes) throws {
        guard accessibility.isTrusted() else { throw KeystrokeTyperError.accessibilityNotGranted }
        var posted = false
        try requireLockScreen(before: "typing", posted: posted)
        try Self.withUTF16(of: password) { units in
            // ⌘→ then ⌘⌫ wipes a stray keypress already in the field.
            // Positional keys, so it works on every keyboard layout.
            try requireLockScreen(before: "clearing the field", posted: posted)
            posted = true
            try poster.postKey(Self.rightArrowKey, withCommand: true)
            try requireLockScreen(before: "clearing the field", posted: posted)
            try poster.postKey(Self.deleteKey, withCommand: true)

            var start = 0
            while start < units.count {
                var end = min(start + Self.maximumBatchLength, units.count)
                // Never split a surrogate pair across two events.
                if end < units.count, (0xD800...0xDBFF).contains(units[end - 1]) { end -= 1 }
                try requireLockScreen(before: "a batch", posted: posted)
                try poster.postUnicode(UnsafeBufferPointer(rebasing: units[start..<end]))
                start = end
            }
            try requireLockScreen(before: "Return", posted: posted)
            try poster.postKey(Self.returnKey, withCommand: false)
        }
    }

    private func requireLockScreen(before step: String, posted: Bool) throws {
        guard lockGuard.mayType() else {
            Self.logger.notice("Typing aborted before \(step, privacy: .public) (\(self.lockGuard.secureInputSummary(), privacy: .public)): not at the lock screen's password field with the display on; \(posted ? "partially typed" : "nothing typed", privacy: .public); Return not pressed")
            throw posted ? KeystrokeTyperError.stoppedPartway : KeystrokeTyperError.notAtLockScreen
        }
    }

    /// Decodes UTF-8 into a manually allocated UTF-16 buffer, zeroed and
    /// freed on every path, so no `String` of the password ever exists.
    static func withUTF16(of password: SecretBytes,
                          _ body: (UnsafeBufferPointer<UInt16>) throws -> Void) throws {
        // UTF-16 never needs more code units than UTF-8 has bytes.
        let capacity = max(password.count, 1)
        let units = UnsafeMutableBufferPointer<UInt16>.allocate(capacity: capacity)
        units.initialize(repeating: 0)
        defer {
            if let base = units.baseAddress {
                _ = memset_s(base, capacity * MemoryLayout<UInt16>.stride, 0, capacity * MemoryLayout<UInt16>.stride)
            }
            units.deallocate()
        }
        var length = 0
        let failed = password.withUnsafeBytes { bytes in
            transcode(bytes.makeIterator(), from: UTF8.self, to: UTF16.self, stoppingOnError: true) { unit in
                guard length < capacity else { return }
                units[length] = unit
                length += 1
            }
        }
        guard !failed, length > 0 else { throw KeystrokeTyperError.invalidPassword }
        try body(UnsafeBufferPointer(rebasing: units[0..<length]))
    }
}

/// Posts at the HID tap, so events reach the lock screen's secure field.
/// The pauses are Glance's, tuned so no event is dropped.
///
/// Every event of a key press is created before the first is posted, so a
/// creation failure posts nothing and can never leave ⌘ held down.
///
/// `@unchecked Sendable` for the `CGEventSource` its default factory holds,
/// an immutable CF object that only the one typing thread ever uses. The
/// factory, poster and pause are injectable for tests; the defaults are the
/// real HID tap.
nonisolated struct CGEventKeyPoster: KeyEventPosting, @unchecked Sendable {

    /// One keyboard event, or nil when Quartz cannot make it.
    typealias MakeKeyEvent = (_ keyCode: CGKeyCode, _ keyDown: Bool) -> CGEvent?

    static let commandKey: CGKeyCode = 0x37
    private static let keyInterval: TimeInterval = 0.012
    private static let unicodeInterval: TimeInterval = 0.004

    private let makeEvent: MakeKeyEvent
    private let post: (CGEvent) -> Void
    private let pause: (TimeInterval) -> Void

    init(makeEvent: MakeKeyEvent? = nil, post: ((CGEvent) -> Void)? = nil,
         pause: ((TimeInterval) -> Void)? = nil) {
        let source = CGEventSource(stateID: .hidSystemState)
        self.makeEvent = makeEvent ?? { CGEvent(keyboardEventSource: source, virtualKey: $0, keyDown: $1) }
        self.post = post ?? { $0.post(tap: .cghidEventTap) }
        self.pause = pause ?? { Thread.sleep(forTimeInterval: $0) }
    }

    /// A real ⌘ down and up around the key when `withCommand`: some fields
    /// ignore a bare flag.
    func postKey(_ keyCode: CGKeyCode, withCommand: Bool) throws {
        let events = try Self.keyPress(keyCode, withCommand: withCommand, makeEvent: makeEvent)
        for event in events {
            post(event)
            pause(Self.keyInterval)
        }
    }

    /// The events of one key press in posting order: key down and up, inside
    /// ⌘ down and up when `withCommand`. All or nothing: throws, having
    /// returned no event to post, if any one cannot be created.
    static func keyPress(_ keyCode: CGKeyCode, withCommand: Bool,
                         makeEvent: MakeKeyEvent) throws -> [CGEvent] {
        guard let keyDown = makeEvent(keyCode, true), let keyUp = makeEvent(keyCode, false) else {
            throw KeystrokeTyperError.eventCreationFailed
        }
        let flags: CGEventFlags = withCommand ? .maskCommand : []
        keyDown.flags = flags
        keyUp.flags = flags
        guard withCommand else { return [keyDown, keyUp] }
        guard let commandDown = makeEvent(commandKey, true), let commandUp = makeEvent(commandKey, false) else {
            throw KeystrokeTyperError.eventCreationFailed
        }
        commandDown.flags = .maskCommand
        commandUp.flags = []
        return [commandDown, keyDown, keyUp, commandUp]
    }

    /// One batch on a key-down, the same batch on its key-up, as Glance
    /// does, so the secure field sees normal event pairs.
    func postUnicode(_ units: UnsafeBufferPointer<UInt16>) throws {
        guard let base = units.baseAddress,
              let keyDown = makeEvent(0, true),
              let keyUp = makeEvent(0, false) else {
            throw KeystrokeTyperError.eventCreationFailed
        }
        keyDown.keyboardSetUnicodeString(stringLength: units.count, unicodeString: base)
        keyUp.keyboardSetUnicodeString(stringLength: units.count, unicodeString: base)
        post(keyDown)
        pause(Self.unicodeInterval)
        post(keyUp)
        pause(Self.unicodeInterval)
    }
}
