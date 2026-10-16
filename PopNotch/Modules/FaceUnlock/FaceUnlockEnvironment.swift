import Foundation
import CoreGraphics

// The coordinator's outside world, one protocol per dependency, so its state
// machine runs in tests against fakes: no camera, model, keyboard, clock or
// lock screen.

/// Camera frames for a scan. `FaceCamera` is the real one.
@MainActor
protocol FaceFrameSource: AnyObject {
    var currentFrame: CameraFrame? { get }
    var errorMessage: String? { get }
    var isRunning: Bool { get }
    func start() async
    func stop()
    /// Every frame (the default), or only one per `requestFrame()`, to save
    /// power once a scan checks a few frames a second.
    func setConvertsEveryFrame(_ value: Bool)
    func requestFrame()
}

extension FaceCamera: FaceFrameSource {}

/// The largest face in a frame: its embedding, and where it is, for the
/// liveness cues.
nonisolated struct FaceScan: Sendable {
    let embedding: [Float]
    /// Pixel space of the frame's image, top-left origin.
    let faceBox: CGRect
}

/// One frame in, the largest face out, or nil when there is no usable face.
/// Blocking and CPU-bound: called off the main actor.
nonisolated protocol FaceScanRecognizing: Sendable {
    func scan(_ frame: CameraFrame) throws -> FaceScan?
}

/// Detect, take the largest face, align, embed. Holds the Core ML model, so
/// the coordinator creates one per lock session and drops it on unlock.
nonisolated final class PipelineFaceScanRecognizer: FaceScanRecognizing {
    private let pipeline: FaceRecognitionPipeline

    init() throws {
        pipeline = try FaceRecognitionPipeline()
    }

    func scan(_ frame: CameraFrame) throws -> FaceScan? {
        guard let face = FaceDetector.largestFace(in: try FaceDetector.detectFaces(in: frame.image)),
              let embedding = try pipeline.recognize(face, in: frame.image)?.embedding else {
            return nil
        }
        return FaceScan(embedding: embedding, faceBox: face.boundingBox)
    }
}

/// Monotonic time and one-shot sleeps. A fake lets tests run a 2-minute
/// scan without waiting.
@MainActor
protocol FaceUnlockClock: AnyObject {
    /// Seconds on a monotonic clock; only differences mean anything.
    func now() -> TimeInterval
    /// Returns early, without throwing, when the task is cancelled.
    func sleep(for seconds: TimeInterval) async
}

@MainActor
final class ContinuousFaceUnlockClock: FaceUnlockClock {
    private let clock = ContinuousClock()
    private let origin = ContinuousClock.now

    func now() -> TimeInterval {
        let elapsed = origin.duration(to: clock.now).components
        return TimeInterval(elapsed.seconds) + TimeInterval(elapsed.attoseconds) / 1e18
    }

    func sleep(for seconds: TimeInterval) async {
        try? await Task.sleep(for: .seconds(seconds))
    }
}

/// Everything the coordinator talks to. `live()` is the real Mac.
struct FaceUnlockEnvironment {
    var lockGuard: any LockScreenGuard
    var lockEvents: any LockEventSource
    var accessibility: any AccessibilityAuthorizing
    /// Read only, never requested here.
    var cameraPermission: () -> CameraPermission
    /// The camera prompt, and Privacy & Security → Camera. Only ever from
    /// the Settings Camera row's button.
    var requestCameraAccess: @MainActor () async -> Void
    var openCameraSettings: @MainActor () -> Void
    var makeFrameSource: () -> any FaceFrameSource
    /// Loads the model. Called off the main actor, on a lock session's first
    /// scan.
    var makeRecognizer: @Sendable () throws -> any FaceScanRecognizing
    /// Run on every face frame while liveness is on; never when it is off.
    var livenessSampler: any LivenessSampling
    var typer: any PasswordTyping
    var clock: any FaceUnlockClock

    /// The lock screen's camera: built-in only, so a USB webcam, Continuity
    /// Camera or capture dongle can never feed a scan. With none present
    /// (lid closed) `start()` fails with a message the coordinator records.
    static func makeLockScreenFrameSource() -> FaceCamera {
        FaceCamera(policy: .builtInOnly)
    }

    static func live() -> FaceUnlockEnvironment {
        let lockGuard = SystemLockScreenGuard()
        let accessibility = SystemAccessibility()
        return FaceUnlockEnvironment(
            lockGuard: lockGuard,
            lockEvents: LockMonitor(),
            accessibility: accessibility,
            cameraPermission: { CameraPermission.current },
            requestCameraAccess: { await CameraPermission.request() },
            openCameraSettings: { CameraPermission.openSystemSettings() },
            makeFrameSource: { makeLockScreenFrameSource() },
            makeRecognizer: { try PipelineFaceScanRecognizer() },
            livenessSampler: VisionLivenessSampler(),
            typer: KeystrokeTyper(lockGuard: lockGuard, accessibility: accessibility),
            clock: ContinuousFaceUnlockClock())
    }
}
