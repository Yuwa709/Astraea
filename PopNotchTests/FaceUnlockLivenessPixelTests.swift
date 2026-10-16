import XCTest
import CoreGraphics
@testable import PopNotch

/// Light liveness's pixel and geometry maths on synthetic input: the glare
/// count over CGImages drawn here, the crop round the face, and the device
/// rectangle's overlap. These assert counting, not how anything looks.
final class FaceUnlockLivenessPixelTests: XCTestCase {

    private typealias RGB = (r: CGFloat, g: CGFloat, b: CGFloat)
    private let skinTone: RGB = (224, 172, 140)
    private let nearWhite: RGB = (250, 250, 250)

    /// A `width` x `height` image filled with `fill`, then each patch.
    private func image(_ width: Int, _ height: Int, fill: RGB, patches: [(CGRect, RGB)] = []) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        func paint(_ rect: CGRect, _ color: RGB) {
            context.setFillColor(red: color.r / 255, green: color.g / 255, blue: color.b / 255, alpha: 1)
            context.fill(rect)
        }
        paint(CGRect(x: 0, y: 0, width: width, height: height), fill)
        for (rect, color) in patches { paint(rect, color) }
        return try XCTUnwrap(context.makeImage())
    }

    private func glare(_ image: CGImage) throws -> GlareSample {
        try XCTUnwrap(GlareCueExtractor.extract(faceCrop: image))
    }

    // MARK: - Glare counting

    func testAUniformFaceColouredCropHasNoGlare() throws {
        let sample = try glare(image(200, 240, fill: skinTone))
        XCTAssertEqual(sample.cropPixelWidth, 200)
        XCTAssertEqual(sample.specularFraction, 0)
        XCTAssertEqual(sample.specularClusterRatio, 0)
        XCTAssertEqual(LivenessCues.glossGlare(sample).level, 0)
    }

    func testANearWhitePatchIsGlare() throws {
        let sample = try glare(image(200, 200, fill: skinTone,
                                     patches: [(CGRect(x: 20, y: 20, width: 60, height: 60), nearWhite)]))
        XCTAssertEqual(sample.specularFraction, 3_600 / 40_000, accuracy: 0.0001)
        let reading = LivenessCues.glossGlare(sample)
        XCTAssertEqual(reading.confidence, 1)
        XCTAssertGreaterThanOrEqual(reading.level, LivenessTuning.default.glossLevel)
    }

    func testABrightColouredPatchIsNotSpecular() throws {
        // Bright enough, but far from grey.
        let sample = try glare(image(200, 200, fill: skinTone,
                                     patches: [(CGRect(x: 20, y: 20, width: 60, height: 60), (200, 255, 255))]))
        XCTAssertEqual(sample.specularFraction, 0)
    }

    /// The same amount of highlight fires as one blob and not as scattered
    /// points: what tells glass from a shiny forehead.
    func testConcentratedGlareFiresWhereTheSameAmountScatteredDoesNot() throws {
        // 320 px: each cell of the 8x8 grid is 40 px.
        let blob = try glare(image(320, 320, fill: skinTone,
                                   patches: [(CGRect(x: 0, y: 0, width: 40, height: 40), nearWhite)]))
        let dots = (0..<8).flatMap { column in
            (0..<8).map { row in (CGRect(x: column * 40 + 17, y: row * 40 + 17, width: 5, height: 5), nearWhite) }
        }
        let scattered = try glare(image(320, 320, fill: skinTone, patches: dots))

        XCTAssertEqual(blob.specularFraction, scattered.specularFraction, accuracy: 0.0001, "1,600 px each")
        XCTAssertEqual(blob.specularClusterRatio, 1, accuracy: 0.0001, "all in one cell")
        XCTAssertEqual(scattered.specularClusterRatio, 1.0 / 64, accuracy: 0.0001, "one 64th in each")
        let tuning = LivenessTuning.default
        XCTAssertGreaterThanOrEqual(LivenessCues.glossGlare(blob).level, tuning.glossLevel)
        XCTAssertLessThan(LivenessCues.glossGlare(scattered).level, tuning.glossLevel)
    }

    // MARK: - The crop round the face

    func testCropGrowsTheFaceBoxByFifteenPercentPerSide() {
        let crop = GlareCueExtractor.cropRect(around: CGRect(x: 200, y: 100, width: 100, height: 120),
                                              imageSize: CGSize(width: 640, height: 360))
        XCTAssertEqual(crop, CGRect(x: 185, y: 82, width: 130, height: 156))
    }

    func testCropIsClampedToTheImage() {
        let crop = GlareCueExtractor.cropRect(around: CGRect(x: -20, y: 300, width: 100, height: 100),
                                              imageSize: CGSize(width: 640, height: 360))
        XCTAssertEqual(crop, CGRect(x: 0, y: 285, width: 95, height: 75))
    }

    /// The live sampler crops the working frame round the face box (top-left
    /// pixel space) and counts glare inside the crop only. A decoy sits at
    /// the inside highlight's vertically mirrored position, so a crop taken
    /// upside down would count the decoy instead.
    func testTheSamplerCountsGlareInsideTheCropRoundTheFace() throws {
        // Face box rows 100...250 from the top; the crop is rows 77...272
        // (x 232...387). The real highlight is rows 78...85, just inside the
        // crop's top edge; its mirror, rows 274...281, is just below the
        // crop and twice as wide. CoreGraphics draws from the bottom, so
        // rows 78...85 from the top are y 274...281 here, and vice versa.
        let frameImage = try image(640, 360, fill: skinTone, patches: [
            (CGRect(x: 300, y: 274, width: 20, height: 8), nearWhite),
            (CGRect(x: 300, y: 78, width: 40, height: 8), nearWhite),
        ])
        let sample = VisionLivenessSampler().sample(CameraFrame(id: 1, image: frameImage),
                                                    faceBox: CGRect(x: 250, y: 100, width: 120, height: 150))
        let glare = try XCTUnwrap(sample.glare)
        XCTAssertEqual(glare.cropPixelWidth, 156)
        XCTAssertEqual(glare.specularFraction, 160 / Float(156 * 196), accuracy: 0.00001,
                       "the 160 px highlight inside, not the 320 px decoy outside")
    }

    func testAFaceBoxOutsideTheImageHasNoCrop() {
        XCTAssertNil(GlareCueExtractor.cropRect(around: CGRect(x: 700, y: 10, width: 50, height: 50),
                                                imageSize: CGSize(width: 640, height: 360)))
    }

    // MARK: - Device rectangle overlap

    private let face = CGRect(x: 100, y: 100, width: 100, height: 100)

    func testNoRectangleOrNoFaceAbstains() {
        XCTAssertNil(LivenessCues.deviceSample(faceBox: face, rectangles: []))
        XCTAssertNil(LivenessCues.deviceSample(faceBox: .zero, rectangles: [face]))
    }

    func testAPhoneRoundTheFaceCoversAllOfIt() throws {
        let sample = try XCTUnwrap(LivenessCues.deviceSample(faceBox: face, rectangles: [CGRect(x: 80, y: 60, width: 140, height: 200)]))
        XCTAssertEqual(sample.faceOverlap, 1, accuracy: 0.0001)
        XCTAssertEqual(sample.areaRatio, 2.8, accuracy: 0.0001)
    }

    func testPartialAndNoOverlap() throws {
        let half = try XCTUnwrap(LivenessCues.deviceSample(faceBox: face, rectangles: [CGRect(x: 150, y: 0, width: 200, height: 300)]))
        XCTAssertEqual(half.faceOverlap, 0.5, accuracy: 0.0001)
        let apart = try XCTUnwrap(LivenessCues.deviceSample(faceBox: face, rectangles: [CGRect(x: 400, y: 0, width: 100, height: 100)]))
        XCTAssertEqual(apart.faceOverlap, 0)
    }

    /// Not Glance's largest-rectangle rule: a big rectangle that misses the
    /// face (a door behind the user) cannot hide a phone held over it.
    func testTheRectangleCoveringMostOfTheFaceIsMeasured() throws {
        let sample = try XCTUnwrap(LivenessCues.deviceSample(faceBox: face, rectangles: [
            CGRect(x: 300, y: 0, width: 300, height: 300),
            CGRect(x: 90, y: 90, width: 120, height: 120),
        ]))
        XCTAssertEqual(sample.faceOverlap, 1, accuracy: 0.0001)
        XCTAssertEqual(sample.areaRatio, 1.44, accuracy: 0.0001, "the ratio of the rectangle that gave the overlap")
    }

    /// A phone and a monitor behind it both cover the face: the smaller,
    /// more phone-like one is reported, so the logged ratio is the phone's.
    func testOnATieTheSmallerRectangleIsMeasured() throws {
        let sample = try XCTUnwrap(LivenessCues.deviceSample(faceBox: face, rectangles: [
            CGRect(x: 0, y: 0, width: 500, height: 400),
            CGRect(x: 80, y: 60, width: 140, height: 200),
        ]))
        XCTAssertEqual(sample.faceOverlap, 1, accuracy: 0.0001)
        XCTAssertEqual(sample.areaRatio, 2.8, accuracy: 0.0001)
    }

    /// The hardware false trip: a glasses lens, 0.2x to 0.4x the face and
    /// inside it, overlapped it by 0.41. Too small to frame a face, so it
    /// is not a device, and the cue abstains.
    func testALensSizedRectangleInsideTheFaceDoesNotCount() {
        let lenses = [CGRect(x: 110, y: 120, width: 60, height: 70), CGRect(x: 150, y: 130, width: 40, height: 30)]
        XCTAssertNil(LivenessCues.deviceSample(faceBox: face, rectangles: lenses))
    }

    func testAPhoneSizedRectangleRoundTheFaceCountsBesideALens() throws {
        let sample = try XCTUnwrap(LivenessCues.deviceSample(faceBox: face, rectangles: [
            CGRect(x: 110, y: 120, width: 60, height: 70),
            CGRect(x: 80, y: 60, width: 140, height: 200),
        ]))
        XCTAssertEqual(sample.faceOverlap, 1, accuracy: 0.0001)
        XCTAssertEqual(sample.areaRatio, 2.8, accuracy: 0.0001, "the phone's, not the lens's")
    }

    func testARectangleTheFacesOwnSizeCounts() throws {
        let sample = try XCTUnwrap(LivenessCues.deviceSample(faceBox: face, rectangles: [face]))
        XCTAssertEqual(sample.faceOverlap, 1, accuracy: 0.0001)
        XCTAssertEqual(sample.areaRatio, 1, accuracy: 0.0001)
    }

    /// A doorway behind the user, far larger and over half the face, does
    /// not hide the phone held over all of it.
    func testAHugeDoorRectangleDoesNotHideAPhoneSizedOne() throws {
        let sample = try XCTUnwrap(LivenessCues.deviceSample(faceBox: face, rectangles: [
            CGRect(x: 150, y: -200, width: 600, height: 900),
            CGRect(x: 80, y: 60, width: 140, height: 200),
        ]))
        XCTAssertEqual(sample.faceOverlap, 1, accuracy: 0.0001)
        XCTAssertEqual(sample.areaRatio, 2.8, accuracy: 0.0001)
    }
}
