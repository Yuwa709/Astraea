// Adapted from Glance (github.com/jonnyoo/glance), MIT, (c) 2026 Jonathan Zhou.
// See THIRD-PARTY-LICENSES.md.

@preconcurrency import AVFoundation
import AppKit
import Observation
import os

enum CameraPermission: Equatable {
    case notDetermined, granted, denied, restricted

    static var current: CameraPermission {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        default: .denied
        }
    }

    /// Opens Privacy & Security → Camera.
    static func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Owns the capture session for an enrolment or a lock-screen scan, and
/// nothing longer: it runs only while the enrolment sheet is open or inside
/// one of `FaceUnlockCoordinator`'s scans (at most 2 minutes each), and stops
/// when the display sleeps (hard rule 9). The camera indicator light is the
/// user's proof.
///
/// The public face is main-actor; device discovery, session configuration,
/// start and stop all run on the session's own serial queue, so a lock
/// session's first wake does not configure the camera on the main thread.
@Observable
@MainActor
final class FaceCamera: NSObject {

    @ObservationIgnored private static let logger = Logger(subsystem: "com.techie.PopNotch", category: "FaceUnlock")

    private(set) var permission: CameraPermission = .current
    private(set) var isRunning = false
    private(set) var currentFrame: CameraFrame?
    private(set) var errorMessage: String?

    /// Which cameras this one may open; fixed for its life.
    @ObservationIgnored let policy: FaceCameraPolicy
    @ObservationIgnored private let demand: FrameDemand
    @ObservationIgnored private let capture: CaptureSessionController
    @ObservationIgnored private let sink: FrameSink
    /// Bumped by every `start()` and `stop()`: a start that finds it changed
    /// on its way back was overtaken and leaves the state alone.
    @ObservationIgnored private var runGeneration = 0
    @ObservationIgnored private var isStarting = false

    /// Read-only so the preview layer can attach to the same session.
    var session: AVCaptureSession { capture.session }

    init(policy: FaceCameraPolicy) {
        self.policy = policy
        let demand = FrameDemand()
        let sink = FrameSink()
        let publisher = CameraFramePublisher(demand: demand) { [sink, demand] frame in
            Task { @MainActor in
                sink.owner?.publish(frame)
                demand.handoffFinished()
            }
        }
        self.demand = demand
        self.sink = sink
        self.capture = CaptureSessionController(policy: policy, publisher: publisher)
        super.init()
        sink.owner = self
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(displayDidSleep),
            name: NSWorkspace.screensDidSleepNotification, object: nil)
    }

    /// Enrolment's camera: the built-in one, else whatever the system offers.
    override convenience init() {
        self.init(policy: .anyCamera)
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        // Whoever forgot to call stop(), the light goes off.
        capture.stop()
    }

    /// Asks for camera access the first time; only ever called from the
    /// user's click on "Add a Face", never at launch.
    func start() async {
        runGeneration &+= 1
        let generation = runGeneration
        if permission == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            permission = granted ? .granted : .denied
            Self.logger.notice("Camera permission \(granted ? "granted" : "denied", privacy: .public)")
            guard generation == runGeneration else { return }
        }
        guard permission == .granted else { return }

        errorMessage = nil
        isStarting = true
        let result = await capture.start()
        // stop() ran meanwhile: its stop is queued behind this start, so the
        // session ends stopped. Leave the state as stop() left it.
        guard generation == runGeneration else { return }
        isStarting = false
        switch result {
        case .started:
            isRunning = true
            Self.logger.notice("Camera started")
        case .failed(let message):
            errorMessage = message
            Self.logger.error("Camera did not start: \(message, privacy: .public)")
        }
    }

    func stop() {
        runGeneration &+= 1
        guard isRunning || isStarting else { return }
        capture.stop()
        isRunning = false
        isStarting = false
        currentFrame = nil
        demand.setConvertsEveryFrame(true)
        Self.logger.notice("Camera stopped")
    }

    /// Every frame (the default, and what enrolment uses), or only one per
    /// `requestFrame()`. Reset to every frame on `stop()`.
    func setConvertsEveryFrame(_ value: Bool) {
        demand.setConvertsEveryFrame(value)
    }

    func requestFrame() {
        demand.request()
    }

    @objc private func displayDidSleep() {
        guard isRunning || isStarting else { return }
        stop()
        errorMessage = "The camera stopped while the display was asleep."
    }

    fileprivate func publish(_ frame: CameraFrame) {
        // A late frame arriving after stop() must not resurrect the preview state.
        guard isRunning else { return }
        currentFrame = frame
    }
}

/// The publisher's weak way back to the camera, set once `self` exists.
@MainActor
private final class FrameSink {
    weak var owner: FaceCamera?
}

/// The `AVCaptureSession` and everything that configures it, confined to
/// `queue`. Nonisolated, so none of it runs on the main actor.
nonisolated final class CaptureSessionController: @unchecked Sendable {

    enum StartResult: Sendable, Equatable {
        case started
        case failed(String)
    }

    private static let logger = Logger(subsystem: "com.techie.PopNotch", category: "FaceUnlock")

    /// The preview layer attaches to it from the main actor; everything else
    /// touches it only on `queue`.
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.techie.PopNotch.FaceUnlock.camera.session")
    private let outputQueue = DispatchQueue(label: "com.techie.PopNotch.FaceUnlock.camera.frames")
    private let output = AVCaptureVideoDataOutput()
    private let policy: FaceCameraPolicy
    private let publisher: CameraFramePublisher
    /// Set once configured; on `queue` only.
    private var device: AVCaptureDevice?

    init(policy: FaceCameraPolicy, publisher: CameraFramePublisher) {
        self.policy = policy
        self.publisher = publisher
    }

    func start() async -> StartResult {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.startOnQueue()) }
        }
    }

    /// Queued behind any start, so a stop always wins.
    func stop() {
        queue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    private func startOnQueue() -> StartResult {
        let device: AVCaptureDevice
        switch configureIfNeeded() {
        case .success(let configured): device = configured
        case .failure(let failure): return .failed(failure.message)
        }
        if !session.isRunning { session.startRunning() }
        guard session.isRunning else {
            // Rediscover next time: the device may have gone (lid closed,
            // camera unplugged) and come back as a new object.
            resetConfiguration()
            return .failed("The camera could not be started.")
        }
        FaceCameraDeviceFinder.logEffects(device)
        return .started
    }

    private struct ConfigurationFailure: Error {
        let message: String
    }

    private func resetConfiguration() {
        session.beginConfiguration()
        session.inputs.forEach(session.removeInput)
        session.outputs.forEach(session.removeOutput)
        session.commitConfiguration()
        device = nil
    }

    private func configureIfNeeded() -> Result<AVCaptureDevice, ConfigurationFailure> {
        if let device, device.isConnected { return .success(device) }
        if device != nil {
            Self.logger.notice("Camera disconnected since it was configured; choosing again")
            resetConfiguration()
        }
        guard let chosen = FaceCameraDeviceFinder.device(for: policy) else {
            Self.logger.error("No camera allowed by policy \(self.policy.rawValue, privacy: .public)")
            return .failure(ConfigurationFailure(message: policy.noCameraMessage))
        }
        FaceCameraDeviceFinder.logChosen(chosen, policy: policy)
        guard let input = try? AVCaptureDeviceInput(device: chosen) else {
            return .failure(ConfigurationFailure(message: "The camera could not be opened."))
        }

        session.beginConfiguration()
        // `.high` and the frame downscale are plenty for Vision. Glance also
        // forced the sensor's largest format, which is only for its liveness
        // crops and can pick a low frame rate.
        session.sessionPreset = .high
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(publisher, queue: outputQueue)
        let added = session.canAddInput(input) && session.canAddOutput(output)
        if added {
            session.addInput(input)
            session.addOutput(output)
        }
        session.commitConfiguration()
        guard added else {
            return .failure(ConfigurationFailure(message: "The camera could not be opened."))
        }
        device = chosen
        return .success(chosen)
    }
}
