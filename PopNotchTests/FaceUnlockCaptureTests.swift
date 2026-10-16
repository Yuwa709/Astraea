import AVFoundation
import CoreML
import CoreVideo
import XCTest
@testable import PopNotch

/// Face Unlock's capture side: which camera the lock screen may use, the
/// frame hand-over (retries, one in flight, cadence), enrolment's cancel
/// guard, the pixel-buffer render and the pinned model digest. No camera is
/// opened and nothing is captured.
@MainActor
final class FaceUnlockCaptureTests: XCTestCase {

    private var directory: URL?

    override func tearDown() async throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        try await super.tearDown()
    }

    // MARK: - Camera choice

    func testLockScreenSourceIsBuiltInOnlyAndEnrolmentMayUseAnyCamera() {
        XCTAssertEqual(FaceUnlockEnvironment.makeLockScreenFrameSource().policy, .builtInOnly)
        XCTAssertEqual(FaceCamera().policy, .anyCamera)
        XCTAssertEqual(FaceCameraPolicy.builtInDeviceTypes, [.builtInWideAngleCamera])
    }

    func testBuiltInOnlyNeverPicksAnExternalDeviceAndNeverAsksForTheSystemDefault() {
        let usb = FakeCameraDevice(deviceType: .external, position: .unspecified)
        let iPhone = FakeCameraDevice(deviceType: .continuityCamera, position: .back, isContinuityCamera: true)
        // A Continuity Camera that reports itself as wide-angle is still refused.
        let disguised = FakeCameraDevice(deviceType: .builtInWideAngleCamera, position: .front, isContinuityCamera: true)
        var askedForDefault = false

        let pick = FaceCameraPolicy.builtInOnly.choose(builtIn: [usb, iPhone, disguised]) {
            askedForDefault = true
            return usb
        }

        XCTAssertNil(pick, "lid closed: no built-in camera, so nothing")
        XCTAssertFalse(askedForDefault)
    }

    func testBuiltInOnlyPrefersTheFrontBuiltInCamera() {
        let usb = FakeCameraDevice(deviceType: .external, position: .front)
        let side = FakeCameraDevice(deviceType: .builtInWideAngleCamera, position: .unspecified)
        let front = FakeCameraDevice(deviceType: .builtInWideAngleCamera, position: .front)

        XCTAssertEqual(FaceCameraPolicy.builtInOnly.choose(builtIn: [usb, side, front]) { usb }, front)
        XCTAssertEqual(FaceCameraPolicy.builtInOnly.choose(builtIn: [usb, side]) { usb }, side)
    }

    func testAnyCameraFallsBackToTheSystemDefault() {
        let usb = FakeCameraDevice(deviceType: .external, position: .unspecified)
        let builtIn = FakeCameraDevice(deviceType: .builtInWideAngleCamera, position: .front)

        XCTAssertEqual(FaceCameraPolicy.anyCamera.choose(builtIn: []) { usb }, usb)
        XCTAssertEqual(FaceCameraPolicy.anyCamera.choose(builtIn: [builtIn]) { usb }, builtIn)
    }

    func testFourCharacterTransportCodes() {
        XCTAssertEqual(FaceCameraDeviceFinder.fourCC(0x626C_746E), "bltn")
        XCTAssertEqual(FaceCameraDeviceFinder.fourCC(0x7573_6220), "usb ")
        XCTAssertEqual(FaceCameraDeviceFinder.fourCC(7), "7")
    }

    // MARK: - Frame hand-over

    /// Pipeline #5: the slow phase asks for one frame; that frame failing
    /// to convert must not leave the request unanswered.
    func testARequestedFrameThatFailsToConvertIsReplacedByTheNextOne() {
        let converter = FakeConverter(failing: [0])
        let harness = PublisherHarness(converter: converter)
        harness.demand.setConvertsEveryFrame(false)
        harness.demand.request()

        harness.capture(at: 0)
        XCTAssertEqual(harness.delivered, 0, "the dropped frame")
        harness.capture(at: 0.033)
        XCTAssertEqual(harness.delivered, 1, "the next captured frame answers the request")
        harness.capture(at: 0.066)
        XCTAssertEqual(harness.delivered, 1, "one frame per request")
        XCTAssertEqual(converter.calls, 2)
    }

    func testConversionRetriesAreBounded() {
        let converter = FakeConverter(failing: Set(0..<100))
        let harness = PublisherHarness(converter: converter)
        harness.demand.setConvertsEveryFrame(false)
        harness.demand.request()

        for frame in 0..<20 { harness.capture(at: Double(frame) / 30) }

        XCTAssertEqual(converter.calls, 1 + FrameDemand.maxConversionRetries)
        XCTAssertEqual(harness.delivered, 0)
    }

    func testAModeChangeDoesNotReArmARequest() {
        let converter = FakeConverter(failing: [0])
        let harness = PublisherHarness(converter: converter)
        harness.demand.setConvertsEveryFrame(false)
        harness.demand.request()
        harness.capture(at: 0) // fails, re-armed
        harness.demand.setConvertsEveryFrame(false) // the coordinator's pace() drops a pending request

        harness.capture(at: 0.033)

        XCTAssertEqual(harness.delivered, 0)
        XCTAssertEqual(converter.calls, 1)
    }

    /// Pipeline #12: while one frame is on its way to the main actor, the
    /// next is dropped before any downscale, and a pending request waits.
    func testOneFrameInFlightAndNoConversionWhileItIs() {
        let converter = FakeConverter()
        let harness = PublisherHarness(converter: converter, finishesHandoff: false)

        harness.capture(at: 0)
        harness.capture(at: 1)
        XCTAssertEqual(harness.delivered, 1)
        XCTAssertEqual(converter.calls, 1, "the second frame cost nothing")

        harness.demand.setConvertsEveryFrame(false)
        harness.demand.request()
        harness.capture(at: 2)
        XCTAssertEqual(converter.calls, 1, "still in flight; the request is kept")
        harness.demand.handoffFinished()
        harness.capture(at: 3)
        XCTAssertEqual(harness.delivered, 2)
        XCTAssertEqual(harness.frameIDs, [1, 2])
    }

    /// A 30 fps camera gives every-frame consumers 15 a second, with or
    /// without a few milliseconds of timestamp jitter: about twice the fast
    /// phase's ~8 checks a second.
    func testEveryFrameModeConvertsEveryOtherFrameOfAThirtyFPSCamera() {
        let steady = PublisherHarness(converter: FakeConverter())
        for frame in 0..<30 { steady.capture(at: Double(frame) / 30) }
        XCTAssertEqual(steady.delivered, 15)

        let jittery = PublisherHarness(converter: FakeConverter())
        for frame in 0..<30 { jittery.capture(at: Double(frame) / 30 + (frame.isMultiple(of: 3) ? 0.006 : -0.006)) }
        XCTAssertEqual(jittery.delivered, 15)
    }

    func testTheExistingTakeFrameRuleIsUnpaced() {
        let demand = FrameDemand()
        XCTAssertTrue(demand.takeFrame())
        XCTAssertTrue(demand.takeFrame())
    }

    // MARK: - Enrolment cancel (pipeline #4)

    func testCancellingDuringTheModelLoadNeverStartsTheCamera() async throws {
        let gate = TestGate()
        let camera = GatedEnrollmentCamera()
        let session = FaceEnrollmentSession(store: try makeStore(), frameSource: camera) {
            gate.wait()
            return NoFaceRecognizer()
        }

        let start = Task { await session.start() }
        await waitUntil { gate.waiting == 1 }
        session.cancel()
        gate.open()
        await start.value

        XCTAssertTrue(session.isCancelled)
        XCTAssertEqual(camera.startCount, 0)
        XCTAssertFalse(camera.isRunning)
        XCTAssertNotEqual(session.step, .capturing)
    }

    func testCancellingWhileTheCameraStartsStopsItOnceItHasStarted() async throws {
        let camera = GatedEnrollmentCamera()
        camera.holdsStart = true
        let session = FaceEnrollmentSession(store: try makeStore(), frameSource: camera) { NoFaceRecognizer() }

        let start = Task { await session.start() }
        await waitUntil { camera.isHoldingStart }
        session.cancel()
        camera.releaseStart() // the start finishes after the cancel, as AVCaptureSession's can
        await start.value

        XCTAssertFalse(camera.isRunning, "the light is off")
        XCTAssertEqual(camera.stopCount, 2, "cancel() stopped it, then start() stopped the late start")
        XCTAssertNotEqual(session.step, .capturing)
    }

    func testAStartAfterCancelDoesNothing() async throws {
        let camera = GatedEnrollmentCamera()
        let session = FaceEnrollmentSession(store: try makeStore(), frameSource: camera) { NoFaceRecognizer() }
        session.cancel()

        await session.start()

        XCTAssertEqual(camera.startCount, 0)
    }

    func testAnUncancelledStartCapturesAndCancelStopsTheCamera() async throws {
        let camera = GatedEnrollmentCamera()
        let session = FaceEnrollmentSession(store: try makeStore(), frameSource: camera) { NoFaceRecognizer() }

        await session.start()
        XCTAssertEqual(session.step, .capturing)
        XCTAssertTrue(camera.isRunning)
        XCTAssertNil(session.camera, "a fake has no preview session")

        session.cancel()
        XCTAssertFalse(camera.isRunning)
    }

    func testDeniedPermissionStopsAtPermissionNeeded() async throws {
        let camera = GatedEnrollmentCamera()
        camera.permission = .denied
        camera.failsToStart = true
        let session = FaceEnrollmentSession(store: try makeStore(), frameSource: camera) { NoFaceRecognizer() }

        await session.start()

        XCTAssertEqual(session.step, .permissionNeeded)
    }

    // MARK: - Render (pipeline #6)

    func testRenderFillsALockedBuffer() throws {
        let size = FaceAligner.outputSize
        var created: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, size, size, kCVPixelFormatType_32BGRA, nil, &created), kCVReturnSuccess)
        let buffer = try XCTUnwrap(created)
        let context = try XCTUnwrap(CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let image = try XCTUnwrap(context.makeImage())

        try FaceEmbedder.render(image, into: buffer)

        XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, .readOnly), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        XCTAssertEqual([bytes[0], bytes[1], bytes[2], bytes[3]], [0, 0, 255, 255], "BGRA red")
    }

    // MARK: - Model integrity (security L5)

    func testDigestUsesTheShasumFormat() throws {
        let root = try makeDirectory()
        try FileManager.default.createDirectory(at: root.appending(path: "b"), withIntermediateDirectories: true)
        try Data("hello\n".utf8).write(to: root.appending(path: "a.txt"))
        try Data("world\n".utf8).write(to: root.appending(path: "b/c.txt"))
        let files = try FaceModelIntegrity.regularFiles(in: root)
        XCTAssertEqual(Set(files.keys), ["./a.txt", "./b/c.txt"])

        // `shasum -a 256 ./a.txt ./b/c.txt | shasum -a 256` over the same files.
        let digest = try FaceModelIntegrity.digest(of: ["./a.txt", "./b/c.txt"].compactMap { path in
            files[path].map { (path, $0) }
        })
        XCTAssertEqual(digest, "8e396978a805c0b0b73fee91d03ad6f3a0d0841ba297c0b89afadf854e63402e")
    }

    func testBundledModelMatchesThePinnedDigest() throws {
        let url = try bundledModel()
        let files = try FaceModelIntegrity.regularFiles(in: url)
        let found = try FaceModelIntegrity.digest(of: FaceModelIntegrity.hashedFiles.compactMap { path in
            files[path].map { (path, $0) }
        })
        XCTAssertEqual(Set(files.keys), FaceModelIntegrity.expectedFiles)
        XCTAssertEqual(found, FaceModelIntegrity.expectedDigest,
                       "The compiled model changed. If that was intended, pin \(found) in FaceModelIntegrity.expectedDigest.")
        XCTAssertNoThrow(try FaceModelIntegrity.verify(modelAt: url))
        XCTAssertNotNil(try? FaceModelIntegrity.verifiedBundledModel.get())
    }

    func testATamperedOrPaddedModelIsRefused() throws {
        let copy = try makeDirectory().appending(path: "FaceReidentification.mlmodelc")
        try FileManager.default.copyItem(at: try bundledModel(), to: copy)
        XCTAssertNoThrow(try FaceModelIntegrity.verify(modelAt: copy), "an untouched copy passes")

        let extra = copy.appending(path: "model2.mil")
        try Data("program".utf8).write(to: extra)
        assertRefused(copy, "an extra file")
        try FileManager.default.removeItem(at: extra)

        let weights = copy.appending(path: "weights/weight.bin")
        var bytes = try Data(contentsOf: weights)
        bytes[bytes.count / 2] ^= 0x01
        try bytes.write(to: weights)
        assertRefused(copy, "one flipped bit in the weights")
    }

    func testTheLoadedModelHasTheExpectedDescription() throws {
        let model = try MLModel(contentsOf: try bundledModel())
        XCTAssertNil(FaceModelIntegrity.checkDescription(model.modelDescription, inputName: FaceEmbedder.inputName,
                                                         outputName: FaceEmbedder.outputName))
        XCTAssertNotNil(FaceModelIntegrity.checkDescription(model.modelDescription, inputName: "other",
                                                            outputName: FaceEmbedder.outputName))
        XCTAssertNoThrow(try FaceEmbedder())
    }

    // MARK: - Helpers

    private func assertRefused(_ url: URL, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try FaceModelIntegrity.verify(modelAt: url), message, file: file, line: line) { error in
            guard case .modelIntegrityFailed = error as? FaceEmbedderError else {
                return XCTFail("\(message): \(error)", file: file, line: line)
            }
        }
    }

    private func bundledModel() throws -> URL {
        try XCTUnwrap(Bundle.main.url(forResource: FaceEmbedder.resourceName, withExtension: "mlmodelc"),
                      "the test host is PopNotch.app, which bundles the model")
    }

    private func makeDirectory() throws -> URL {
        if let directory { return directory }
        let url = FileManager.default.temporaryDirectory.appending(path: "PopNotchFaceCaptureTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        directory = url
        return url
    }

    private func makeStore() throws -> FaceEnrollmentStore {
        let session = FaceUnlockSession(vault: MemoryKeyVault(), authenticator: FakeOwnerAuthenticator(),
                                        directory: try makeDirectory().appending(path: "store"))
        return FaceEnrollmentStore(session: session)
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<400 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("timed out", file: file, line: line)
    }
}

// MARK: - Fakes (this suite only)

private struct FakeCameraDevice: CameraDeviceDescribing, Equatable {
    let deviceType: AVCaptureDevice.DeviceType
    let position: AVCaptureDevice.Position
    var isContinuityCamera = false
}

/// Converts by handing back a 1x1 image, except on the listed calls.
private final class FakeConverter {
    private let failing: Set<Int>
    private(set) var calls = 0
    private let image: CGImage = {
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }()

    init(failing: Set<Int> = []) { self.failing = failing }

    func convert(_ buffer: CVPixelBuffer) -> CGImage? {
        defer { calls += 1 }
        return failing.contains(calls) ? nil : image
    }
}

/// A publisher fed by hand on the test's thread, as the capture queue would.
private final class PublisherHarness {
    let demand = FrameDemand()
    private(set) var frameIDs: [UInt64] = []
    var delivered: Int { frameIDs.count }
    private var publisher: CameraFramePublisher?
    private let buffer: CVPixelBuffer = {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 4, 4, kCVPixelFormatType_32BGRA, nil, &buffer)
        return buffer!
    }()

    init(converter: FakeConverter, finishesHandoff: Bool = true) {
        let demand = demand
        publisher = CameraFramePublisher(demand: demand, convert: converter.convert) { [weak self] frame in
            self?.frameIDs.append(frame.id)
            if finishesHandoff { demand.handoffFinished() }
        }
    }

    func capture(at time: TimeInterval) {
        publisher?.handle(buffer, at: time)
    }
}

@MainActor
private final class GatedEnrollmentCamera: EnrollmentFrameSource {
    var permission: CameraPermission = .granted
    private(set) var isRunning = false
    private(set) var startCount = 0
    private(set) var stopCount = 0
    var currentFrame: CameraFrame? { nil }
    var errorMessage: String?
    var failsToStart = false
    /// start() waits for `releaseStart()`, then reports running: a start
    /// that finishes after a stop.
    var holdsStart = false
    private var held: CheckedContinuation<Void, Never>?
    var isHoldingStart: Bool { held != nil }

    func start() async {
        startCount += 1
        if holdsStart { await withCheckedContinuation { held = $0 } }
        isRunning = !failsToStart
    }

    func releaseStart() {
        held?.resume()
        held = nil
    }

    func stop() {
        stopCount += 1
        isRunning = false
    }

    func setConvertsEveryFrame(_ value: Bool) {}
    func requestFrame() {}
}

private struct NoFaceRecognizer: EnrollmentFaceRecognizing {
    func recognize(_ face: DetectedFace, in frame: CGImage) throws -> FaceRecognitionResult? { nil }
}
