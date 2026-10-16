import XCTest
import CoreGraphics
@testable import PopNotch

// Fakes for lock-screen Face Unlock (phase 3). None of them touches the real
// lock screen, camera, model, keyboard or Accessibility.

/// The session server, scripted. Thread-safe: the typer reads it off the
/// main actor.
nonisolated final class FakeLockGuard: LockScreenGuard, @unchecked Sendable {
    private let lock = NSLock()
    private var _state: LockScreenState
    private var _displayAsleep = false
    private var _secureInput = true
    private var _secureInputOwner: String? = SecureInputOwner.loginWindow
    private var _checks = 0
    private var _flipAfterChecks: Int?
    private var _flipTo: LockScreenState = .unlocked

    init(_ state: LockScreenState = .locked) { _state = state }

    var state: LockScreenState {
        get { lock.withLock { _state } }
        set { lock.withLock { _state = newValue } }
    }
    var displayAsleep: Bool {
        get { lock.withLock { _displayAsleep } }
        set { lock.withLock { _displayAsleep = newValue } }
    }
    /// Secure Event Input: on means the password field is focused.
    var secureInput: Bool {
        get { lock.withLock { _secureInput } }
        set { lock.withLock { _secureInput = newValue } }
    }
    /// Who holds secure input when it is on; loginwindow by default.
    var secureInputOwner: String? {
        get { lock.withLock { _secureInputOwner } }
        set { lock.withLock { _secureInputOwner = newValue } }
    }
    /// Lock-state reads (`currentState()` calls).
    var checks: Int { lock.withLock { _checks } }
    /// Reports `state` (`.unlocked` by default) from this many more checks on.
    func flip(to state: LockScreenState = .unlocked, afterChecks count: Int) {
        lock.withLock {
            _flipTo = state
            _flipAfterChecks = _checks + count
        }
    }

    func currentState() -> LockScreenState {
        lock.withLock {
            _checks += 1
            if let flip = _flipAfterChecks, _checks > flip {
                _state = _flipTo
                _flipAfterChecks = nil
            }
            return _state
        }
    }
    func isSecureInputEnabled() -> Bool { secureInput }
    func secureInputOwnerName() -> String? { secureInputOwner }
    func isMainDisplayAsleep() -> Bool { displayAsleep }
}

@MainActor
final class FakeLockEvents: LockEventSource {
    var onEvent: ((LockEvent) -> Void)?
    private(set) var isStarted = false
    func start() { isStarted = true }
    func stop() { isStarted = false }
    func send(_ event: LockEvent) { onEvent?(event) }
}

nonisolated final class FakeAccessibility: AccessibilityAuthorizing, @unchecked Sendable {
    private let lock = NSLock()
    private var _trusted: Bool
    private var _requests = 0
    init(trusted: Bool = true) { _trusted = trusted }
    var trusted: Bool {
        get { lock.withLock { _trusted } }
        set { lock.withLock { _trusted = newValue } }
    }
    var requests: Int { lock.withLock { _requests } }
    func isTrusted() -> Bool { trusted }
    func requestTrust() { lock.withLock { _requests += 1 } }
}

@MainActor
final class FakePermissions {
    var camera: CameraPermission = .granted
}

/// While running, a new frame on every read when converting every frame;
/// in on-request mode, a new frame only on the first read after a request,
/// and the last frame again otherwise.
@MainActor
final class FakeFrameSource: FaceFrameSource {
    static let image: CGImage = {
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }()

    private(set) var isRunning = false
    private(set) var startCount = 0
    private(set) var stopCount = 0
    /// New frames produced ("converted").
    private(set) var reads = 0
    private(set) var convertsEveryFrame = true
    private(set) var requests = 0
    var errorMessage: String?
    var failsToStart = false
    /// After this many frames no new one comes, though it keeps running:
    /// a closed lid, or a camera that reports running without frames.
    var stallAfter: Int?
    /// Called on every new frame with the frame count.
    var onRead: ((Int) -> Void)?
    private var nextID: UInt64 = 0
    private var pendingRequest = false
    private var lastFrame: CameraFrame?

    var currentFrame: CameraFrame? {
        guard isRunning else { return nil }
        let stalled = stallAfter.map { reads >= $0 } ?? false
        guard !stalled, convertsEveryFrame || pendingRequest else { return lastFrame }
        pendingRequest = false
        reads += 1
        nextID += 1
        let frame = CameraFrame(id: nextID, image: Self.image)
        lastFrame = frame
        onRead?(reads)
        return frame
    }

    func start() async {
        startCount += 1
        isRunning = !failsToStart
    }

    func stop() {
        stopCount += 1
        isRunning = false
        lastFrame = nil
        convertsEveryFrame = true
        pendingRequest = false
    }

    func setConvertsEveryFrame(_ value: Bool) {
        convertsEveryFrame = value
        pendingRequest = false
    }

    func requestFrame() {
        requests += 1
        pendingRequest = true
    }
}

/// Embeddings by frame ID: nil is "no face".
nonisolated final class FakeRecognizer: FaceScanRecognizing, @unchecked Sendable {
    private let lock = NSLock()
    private var _script: @Sendable (UInt64) -> [Float]?
    private var _created = 0
    private var _calls = 0

    init(_ script: @escaping @Sendable (UInt64) -> [Float]? = { _ in nil }) { _script = script }

    var script: @Sendable (UInt64) -> [Float]? {
        get { lock.withLock { _script } }
        set { lock.withLock { _script = newValue } }
    }
    var created: Int { lock.withLock { _created } }
    /// Frames checked.
    var calls: Int { lock.withLock { _calls } }
    func noteCreated() { lock.withLock { _created += 1 } }

    /// The face fills the 1x1 fake frame.
    func scan(_ frame: CameraFrame) throws -> FaceScan? {
        lock.withLock { _calls += 1 }
        return script(frame.id).map { FaceScan(embedding: $0, faceBox: CGRect(x: 0, y: 0, width: 1, height: 1)) }
    }
}

/// A recognizer scripted per frame ID with the whole result: a face of any
/// box (for the minimum face size), no face, or an error.
nonisolated final class ScriptedScanRecognizer: FaceScanRecognizing, @unchecked Sendable {
    private let lock = NSLock()
    private let script: @Sendable (UInt64) throws -> FaceScan?
    private var _calls = 0

    init(_ script: @escaping @Sendable (UInt64) throws -> FaceScan?) { self.script = script }

    /// Frames checked, including those that threw.
    var calls: Int { lock.withLock { _calls } }

    func scan(_ frame: CameraFrame) throws -> FaceScan? {
        lock.withLock { _calls += 1 }
        return try script(frame.id)
    }
}

/// What a broken model or Vision request throws.
nonisolated struct FakeRecognitionError: LocalizedError {
    var errorDescription: String? { "the model is broken" }
}

/// Liveness measurements by frame ID; `skin` by default (no glare, and
/// the device cue abstaining).
nonisolated final class FakeLivenessSampler: LivenessSampling, @unchecked Sendable {
    /// Glance's self-test values: a few scattered highlights on skin, and a
    /// big concentrated screen-glare blob.
    static let skin = LivenessSample(glare: GlareSample(cropPixelWidth: 140, specularFraction: 0.004, specularClusterRatio: 0.15))
    static let screenGlare = LivenessSample(glare: GlareSample(cropPixelWidth: 140, specularFraction: 0.09, specularClusterRatio: 0.75))
    /// `skin`, with the rectangle detector having run and found nothing:
    /// both cues read at full confidence, so the frame can count as clean.
    /// `skin` alone leaves the device cue abstaining, which makes a frame
    /// neutral.
    static let clean = LivenessSample(glare: skin.glare, device: .noDevice)

    private let lock = NSLock()
    private var _script: @Sendable (UInt64) -> LivenessSample
    private var _calls = 0

    init(_ script: @escaping @Sendable (UInt64) -> LivenessSample = { _ in FakeLivenessSampler.skin }) { _script = script }

    var script: @Sendable (UInt64) -> LivenessSample {
        get { lock.withLock { _script } }
        set { lock.withLock { _script = newValue } }
    }
    /// Face frames measured.
    var calls: Int { lock.withLock { _calls } }

    func sample(_ frame: CameraFrame, faceBox: CGRect) -> LivenessSample {
        lock.withLock { _calls += 1 }
        return script(frame.id)
    }
}

/// Records what it was asked to type; keeps the buffer so tests can check
/// it was wiped afterwards.
nonisolated final class FakeTyper: PasswordTyping, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    private var _typed: [[UInt8]] = []
    private var _buffers: [SecretBytes] = []
    private var _error: Error?
    /// Runs while "typing", off the main actor.
    var onType: (@Sendable () -> Void)?

    var calls: Int { lock.withLock { _calls } }
    var typed: [[UInt8]] { lock.withLock { _typed } }
    var buffers: [SecretBytes] { lock.withLock { _buffers } }
    var error: Error? {
        get { lock.withLock { _error } }
        set { lock.withLock { _error = newValue } }
    }

    func typePasswordAndReturn(_ password: SecretBytes) throws {
        let error = lock.withLock { () -> Error? in
            _calls += 1
            _typed.append(password.withUnsafeBytes { Array($0) })
            _buffers.append(password)
            return _error
        }
        onType?()
        if let error { throw error }
    }
}

/// Virtual time: every sleep returns at once, having moved the clock on,
/// unless `holdSleep` holds it: a held sleep waits for `releaseHeldSleeps()`
/// (and then moves the clock on) or for its task to be cancelled (and then
/// does not).
@MainActor
final class FakeFaceUnlockClock: FaceUnlockClock {
    private(set) var current: TimeInterval = 1_000
    private(set) var sleeps: [TimeInterval] = []
    /// Asked at the start of every sleep, with its length.
    var holdSleep: ((TimeInterval) -> Bool)?
    /// Called at the start of every sleep, with its length.
    var onSleep: ((TimeInterval) -> Void)?
    private var held: [UUID: CheckedContinuation<Void, Never>] = [:]

    var heldCount: Int { held.count }

    func now() -> TimeInterval { current }

    func sleep(for seconds: TimeInterval) async {
        sleeps.append(seconds)
        onSleep?(seconds)
        guard holdSleep?(seconds) == true else {
            current += seconds
            await Task.yield()
            return
        }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { return continuation.resume() }
                held[id] = continuation
            }
        } onCancel: {
            Task { @MainActor in self.resume(id) }
        }
        if !Task.isCancelled { current += seconds }
    }

    /// Lets every held sleep finish and holds no more.
    func releaseHeldSleeps() {
        holdSleep = nil
        held.keys.forEach(resume)
    }

    private func resume(_ id: UUID) {
        held.removeValue(forKey: id)?.resume()
    }

    func advance(by seconds: TimeInterval) { current += seconds }
}

/// A door a background thread waits at until the test opens it. Bounded, so
/// a broken test fails instead of hanging.
nonisolated final class TestGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var _waiting = 0
    private var _open = false

    /// How many have arrived, including any already let through.
    var waiting: Int { lock.withLock { _waiting } }

    func wait() {
        let isOpen = lock.withLock { () -> Bool in
            _waiting += 1
            return _open
        }
        guard !isOpen else { return }
        _ = semaphore.wait(timeout: .now() + 5)
    }

    /// Lets every waiter, present and future, through.
    func open() {
        let count = lock.withLock { () -> Int in
            _open = true
            return _waiting
        }
        for _ in 0..<count { semaphore.signal() }
    }
}

/// Records key events instead of posting them.
nonisolated final class RecordingKeyPoster: KeyEventPosting, @unchecked Sendable {
    enum Event: Equatable {
        case key(CGKeyCode, command: Bool)
        case unicode([UInt16])
    }
    private let lock = NSLock()
    private var _events: [Event] = []
    var events: [Event] { lock.withLock { _events } }
    /// Called after each event is recorded, with the event.
    var onPost: (@Sendable (Event) -> Void)?

    func postKey(_ keyCode: CGKeyCode, withCommand: Bool) throws {
        record(.key(keyCode, command: withCommand))
    }

    func postUnicode(_ units: UnsafeBufferPointer<UInt16>) throws {
        record(.unicode(Array(units)))
    }

    private func record(_ event: Event) {
        lock.withLock { _events.append(event) }
        onPost?(event)
    }
}
