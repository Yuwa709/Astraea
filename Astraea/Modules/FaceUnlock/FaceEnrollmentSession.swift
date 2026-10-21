// Adapted from Glance (github.com/jonnyoo/glance), MIT, (c) 2026 Jonathan Zhou.
// See THIRD-PARTY-LICENSES.md.

import Foundation
import CoreGraphics
import Observation
import os

/// One guided enrolment: nine poses, two samples each, held in memory
/// until the user names them, then written in a single save.
@Observable
@MainActor
final class FaceEnrollmentSession {

    enum Step: Equatable {
        case starting
        case permissionNeeded
        case capturing
        case naming
        case saving
        case done
        case failed(String)
    }

    @ObservationIgnored private static let logger = Logger(subsystem: "com.techie.Astraea", category: "FaceUnlock")

    // Glance's tuning, unchanged.
    @ObservationIgnored private let samplesPerPose = 2
    /// Consecutive passing frames before a capture: debounces a lucky frame.
    @ObservationIgnored private let requiredMatchStreak = 3
    /// The user must settle into a pose before frames count.
    @ObservationIgnored private let poseHoldDuration: Duration = .milliseconds(500)
    /// Vision's quality score has no universal cutoff; this is permissive.
    @ObservationIgnored private let qualityFloor: Float = 0.2
    /// So the first samples are not taken mid-blink.
    @ObservationIgnored private let initialCaptureDelay: Duration = .seconds(1.5)
    @ObservationIgnored private let stallTimeout: Duration = .seconds(12)
    /// Enrolment wants a close face, as a fraction of frame width.
    @ObservationIgnored private let minimumFaceWidth: Float = 0.21

    private(set) var step: Step = .starting
    private(set) var currentPoseIndex = 0
    private(set) var capturedPoses: Set<EnrollmentPose> = []
    /// Bumped on each centre capture; the ring pulses on change.
    private(set) var centerPulseTick = 0
    private(set) var faceDetected = false
    private(set) var isTooFar = false
    private(set) var excessiveTurn: ExcessiveTurn?
    private(set) var headTurn: HeadTurn?
    var name: String
    private(set) var nameError: String?

    @ObservationIgnored private let frameSource: any EnrollmentFrameSource
    @ObservationIgnored private let loadRecognizer: @Sendable () throws -> any EnrollmentFaceRecognizing
    @ObservationIgnored private let store: FaceEnrollmentStore
    @ObservationIgnored private let replacingID: UUID?
    @ObservationIgnored private var pipeline: (any EnrollmentFaceRecognizing)?
    /// Set by `cancel()` and never cleared: the sheet is gone, so nothing
    /// may start the camera or the model again, whatever `start()` was
    /// awaiting when it closed.
    @ObservationIgnored private(set) var isCancelled = false
    @ObservationIgnored private var samples: [FaceSample] = []
    @ObservationIgnored private var capturedForCurrentPose = 0
    @ObservationIgnored private var matchStreak = 0
    @ObservationIgnored private var isProcessingFrame = false
    @ObservationIgnored private var poseStartedAt = ContinuousClock.now
    @ObservationIgnored private var captureReadyAt = ContinuousClock.now
    @ObservationIgnored private var poseHoldStartedAt: ContinuousClock.Instant?

    /// The real camera (built-in, else any) and the real model.
    convenience init(store: FaceEnrollmentStore, replacing identity: FaceIdentity? = nil) {
        self.init(store: store, replacing: identity, frameSource: FaceCamera(policy: .anyCamera),
                  loadRecognizer: { try FaceRecognitionPipeline() })
    }

    /// Tests pass a fake camera and model.
    init(store: FaceEnrollmentStore, replacing identity: FaceIdentity? = nil,
         frameSource: any EnrollmentFrameSource,
         loadRecognizer: @escaping @Sendable () throws -> any EnrollmentFaceRecognizing) {
        self.store = store
        self.replacingID = identity?.id
        self.name = identity?.name ?? (store.identities.isEmpty ? NSFullUserName() : "")
        self.frameSource = frameSource
        self.loadRecognizer = loadRecognizer
    }

    /// The real camera, for the preview layer; nil with a test's fake.
    var camera: FaceCamera? { frameSource as? FaceCamera }

    var currentPose: EnrollmentPose? { EnrollmentPose(rawValue: currentPoseIndex) }

    var progress: Double {
        let total = Double(EnrollmentPose.allCases.count * samplesPerPose)
        return min(Double(currentPoseIndex * samplesPerPose + capturedForCurrentPose) / total, 1)
    }

    var instruction: String {
        if let excessiveTurn { return excessiveTurn.instruction }
        if isTooFar { return "Bring your face closer" }
        if !faceDetected { return "Position your face in the circle" }
        return currentPose?.instruction ?? ""
    }

    /// Loads the model, then starts the camera. `isCancelled` is checked
    /// after each wait: a sheet closed during the model load never starts
    /// the camera, and one closed while the camera was starting stops it.
    func start() async {
        guard !isCancelled else { return }
        step = .starting
        let load = loadRecognizer
        let loaded = await Task.detached(priority: .userInitiated) {
            Result { try load() }
        }.value
        guard !isCancelled else {
            Self.logger.notice("Enrolment closed while the face model loaded; camera not started")
            return
        }
        switch loaded {
        case .success(let recognizer):
            pipeline = recognizer
        case .failure(let error):
            step = .failed(error.localizedDescription)
            Self.logger.error("Face model load failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        await frameSource.start()
        guard !isCancelled else {
            // cancel() stopped a camera that may not have been running yet.
            frameSource.stop()
            pipeline = nil
            Self.logger.notice("Enrolment closed while the camera started; camera stopped")
            return
        }
        guard frameSource.permission == .granted else {
            step = .permissionNeeded
            pipeline = nil
            return
        }
        guard frameSource.isRunning else {
            step = .failed(frameSource.errorMessage ?? "The camera could not be started.")
            pipeline = nil
            return
        }
        captureReadyAt = .now + initialCaptureDelay
        poseStartedAt = .now
        step = .capturing
        Self.logger.notice("Enrolment started")
        observeFrames()
    }

    /// Stops the camera and drops the model and any unsaved samples.
    func cancel() {
        isCancelled = true
        frameSource.stop()
        pipeline = nil
        if step == .capturing || step == .naming {
            Self.logger.notice("Enrolment cancelled")
        }
        samples = []
    }

    func save() async {
        guard step == .naming else { return }
        step = .saving
        nameError = nil
        do {
            try await store.commitEnrollment(replacing: replacingID, name: name, samples: samples)
            samples = []
            step = .done
        } catch {
            nameError = error.localizedDescription
            step = .naming
        }
    }

    // MARK: - Frames

    /// Observation fires once per registration, so it re-registers on each
    /// change, and stops re-registering once capture is over.
    private func observeFrames() {
        withObservationTracking {
            _ = frameSource.currentFrame
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.step == .capturing, !self.isCancelled else { return }
                self.observeFrames()
                await self.processFrame()
            }
        }
    }

    private enum FrameOutcome: @unchecked Sendable {
        case noFace, tooFar, unusable(DetectedFace), ready(FaceRecognitionResult)
    }

    private func processFrame() async {
        guard step == .capturing, !isCancelled else { return }
        guard frameSource.isRunning else {
            step = .failed(frameSource.errorMessage ?? "The camera stopped.")
            pipeline = nil
            return
        }
        // Frames that arrive mid-processing are dropped, not queued.
        guard !isProcessingFrame, let frame = frameSource.currentFrame, let pipeline, let pose = currentPose else { return }
        isProcessingFrame = true
        defer { isProcessingFrame = false }

        let image = frame.image
        let minimumWidth = minimumFaceWidth
        let outcome = await Task.detached(priority: .userInitiated) { () -> FrameOutcome in
            guard let faces = try? FaceDetector.detectFaces(in: image),
                  let face = FaceDetector.largestFace(in: faces) else { return .noFace }
            if Float(face.normalizedBoundingBox.width) < minimumWidth { return .tooFar }
            guard let result = try? pipeline.recognize(face, in: image) else { return .unusable(face) }
            return .ready(result)
        }.value
        guard step == .capturing, !isCancelled else { return }

        switch outcome {
        case .noFace:
            updateTracking(face: nil, tooFar: false)
        case .tooFar:
            updateTracking(face: nil, tooFar: true)
        case .unusable(let face):
            updateTracking(face: face, tooFar: false)
            resetStreak()
        case .ready(let result):
            updateTracking(face: result.face, tooFar: false)
            consider(result, pose: pose)
        }
    }

    private func updateTracking(face: DetectedFace?, tooFar: Bool) {
        faceDetected = face != nil || tooFar
        isTooFar = tooFar
        guard let face, let yaw = face.yaw, let pitch = face.pitch, let pose = currentPose else {
            excessiveTurn = nil
            headTurn = nil
            resetStreak()
            return
        }
        excessiveTurn = EnrollmentPoseRules.excessiveTurn(yaw: yaw, pitch: pitch)
        headTurn = excessiveTurn == nil ? EnrollmentPoseRules.headTurn(yaw: yaw, pitch: pitch, pose: pose) : nil
    }

    private func resetStreak() {
        matchStreak = 0
        poseHoldStartedAt = nil
    }

    private func consider(_ result: FaceRecognitionResult, pose: EnrollmentPose) {
        guard let yaw = result.face.yaw, let pitch = result.face.pitch, excessiveTurn == nil,
              ContinuousClock.now >= captureReadyAt,
              result.face.quality.map({ $0 >= qualityFloor }) ?? true,
              EnrollmentPoseRules.poseMatches(yaw: yaw, pitch: pitch, pose: pose,
                                              widened: ContinuousClock.now - poseStartedAt > stallTimeout)
        else {
            resetStreak()
            return
        }

        let holdStart = poseHoldStartedAt ?? .now
        poseHoldStartedAt = holdStart
        guard ContinuousClock.now - holdStart >= poseHoldDuration else { return }

        matchStreak += 1
        guard matchStreak >= requiredMatchStreak else { return }
        matchStreak = 0

        samples.append(FaceSample(embedding: result.embedding, pose: pose.storageName,
                                  capturedAt: Date(), quality: result.face.quality))
        capturedForCurrentPose += 1
        guard capturedForCurrentPose >= samplesPerPose else { return }

        if pose == .center { centerPulseTick += 1 } else { capturedPoses.insert(pose) }
        currentPoseIndex += 1
        capturedForCurrentPose = 0
        poseStartedAt = .now
        poseHoldStartedAt = nil
        Self.logger.notice("Enrolment pose captured: \(pose.storageName, privacy: .public)")

        if currentPoseIndex >= EnrollmentPose.allCases.count {
            frameSource.stop()
            pipeline = nil
            headTurn = nil
            step = .naming
            Self.logger.notice("Enrolment capture complete: \(self.samples.count, privacy: .public) samples")
        }
    }
}

/// A camera enrolment can use: frames, plus the permission it may ask for.
@MainActor
protocol EnrollmentFrameSource: FaceFrameSource {
    var permission: CameraPermission { get }
}

extension FaceCamera: EnrollmentFrameSource {}

/// Align and embed an already-detected face. `FaceRecognitionPipeline` is
/// the real one; it holds the model.
nonisolated protocol EnrollmentFaceRecognizing: Sendable {
    func recognize(_ face: DetectedFace, in frame: CGImage) throws -> FaceRecognitionResult?
}

extension FaceRecognitionPipeline: EnrollmentFaceRecognizing {}
