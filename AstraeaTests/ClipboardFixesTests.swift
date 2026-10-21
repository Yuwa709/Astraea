import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import Astraea

/// Which representation a clipping is read as, from its types alone.
final class ClipboardTypePrecedenceTests: XCTestCase {

    private let text = NSPasteboard.PasteboardType.string.rawValue
    private let png = NSPasteboard.PasteboardType.png.rawValue
    private let tiff = NSPasteboard.PasteboardType.tiff.rawValue
    private let fileURL = NSPasteboard.PasteboardType.fileURL.rawValue

    func testSpreadsheetCellCopyIsReadAsText() {
        // Excel and Numbers offer the cells as text *and* as a picture.
        XCTAssertEqual(ClipboardService.captureKind(
            types: [tiff, png, "public.html", text]), .text)
    }

    func testImageOnlyClippingIsReadAsAnImage() {
        XCTAssertEqual(ClipboardService.captureKind(types: [png]), .image(.png))
        XCTAssertEqual(ClipboardService.captureKind(types: [tiff]), .image(.tiff))
    }

    func testPNGIsPreferredOverTIFF() {
        XCTAssertEqual(ClipboardService.captureKind(types: [tiff, png]), .image(.png))
    }

    func testFileCopyIsNotRecordedAsItsIcon() {
        XCTAssertNil(ClipboardService.captureKind(types: [fileURL, tiff]))
    }

    func testNothingUsableIsNil() {
        XCTAssertNil(ClipboardService.captureKind(types: []))
        XCTAssertNil(ClipboardService.captureKind(types: ["com.example.private"]))
    }
}

/// The byte bounds: text cap, history byte cap, image reduction.
final class ClipboardByteBoundTests: XCTestCase {

    func testTextOverTheCapIsNotRecorded() {
        let big = String(repeating: "a", count: ClipboardService.maxTextBytes + 1)
        XCTAssertFalse(ClipboardService.shouldRecord(text: big))
        XCTAssertTrue(ClipboardService.shouldRecord(
            text: String(repeating: "a", count: ClipboardService.maxTextBytes)))
        XCTAssertFalse(ClipboardService.shouldRecord(text: " \n\t "), "blank is still skipped")
    }

    func testHistoryByteCapDropsTheOldest() {
        func image(_ byte: UInt8) -> ClipboardEntry {
            .init(content: .image(Data(repeating: byte, count: 3_000)))
        }
        var history: [ClipboardEntry] = []
        for byte: UInt8 in 1...4 {
            history = ClipboardService.inserting(image(byte), into: history,
                                                 limit: 10, byteLimit: 8_000)
        }
        XCTAssertEqual(history.count, 2, "two 3 kB entries fit under 8 kB, a third does not")
        XCTAssertEqual(history.first, image(4), "newest kept")
        XCTAssertEqual(history.last, image(3))
    }

    func testAnEntryOverTheByteCapStillKeepsItself() {
        let big = ClipboardEntry(content: .text(String(repeating: "x", count: 100)))
        let history = ClipboardService.inserting(big, into: [], limit: 10, byteLimit: 10)
        XCTAssertEqual(history, [big], "the cap trims history, never the clipping just copied")
    }

    func testDefaultByteCapAppliesToTheLiveCall() {
        // Eleven 1 MB clippings: the count cap would keep ten, the byte cap
        // keeps no more than eight megabytes' worth.
        var history: [ClipboardEntry] = []
        for byte: UInt8 in 1...11 {
            history = ClipboardService.inserting(
                .init(content: .image(Data(repeating: byte, count: 1024 * 1024))),
                into: history, limit: ClipboardService.historyLimit)
        }
        let total = history.reduce(0) { $0 + $1.byteCount }
        XCTAssertLessThanOrEqual(total, ClipboardService.historyByteLimit)
        XCTAssertEqual(history.count, 8)
    }

    func testThumbnailIsReturnedNotTheOriginal() throws {
        let tiff = try ClipboardImageFixture.tiff(width: 2000, height: 1000)
        let png = try XCTUnwrap(ClipboardService.makeThumbnail(from: tiff))
        let image = try XCTUnwrap(ClipboardService.decodeThumbnail(png))
        XCTAssertEqual(max(image.width, image.height), ClipboardService.thumbnailMaxPixels)
        XCTAssertEqual(image.width, 512)
        XCTAssertEqual(image.height, 256, "aspect ratio kept")
        XCTAssertLessThan(png.count, tiff.count / 10,
                          "a fraction of the \(tiff.count)-byte source")
    }

    func testOversizedSourceIsNotDecoded() throws {
        let tiff = try ClipboardImageFixture.tiff(width: 64, height: 64)
        XCTAssertNil(ClipboardService.makeThumbnail(from: tiff, maxSourceBytes: tiff.count - 1))
    }

    func testNonImageBytesYieldNoThumbnail() {
        XCTAssertNil(ClipboardService.makeThumbnail(from: Data("not an image".utf8)))
    }

    func testEqualityIgnoresTheDecodedThumbnail() throws {
        let png = try XCTUnwrap(ClipboardService.makeThumbnail(
            from: try ClipboardImageFixture.tiff(width: 32, height: 32)))
        let decoded = ClipboardService.decodeThumbnail(png)
        XCTAssertEqual(ClipboardEntry(content: .image(png), thumbnail: decoded),
                       ClipboardEntry(content: .image(png)))
    }
}

/// End to end against a private pasteboard — never the user's clipboard.
@MainActor
final class ClipboardCaptureTests: XCTestCase {

    private var pasteboard: NSPasteboard!

    override func setUp() async throws {
        try await super.setUp()
        pasteboard = NSPasteboard.withUniqueName()
    }

    override func tearDown() async throws {
        pasteboard.releaseGlobally()
        pasteboard = nil
        try await super.tearDown()
    }

    private func waitFor(_ condition: () -> Bool, seconds: Double = 5) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func testTextAndImageTogetherRecordsTheText() throws {
        let service = ClipboardService(pasteboard: pasteboard)
        service.setEnabled(true)
        pasteboard.clearContents()
        pasteboard.setString("A1\tB1", forType: .string)
        pasteboard.setData(try ClipboardImageFixture.tiff(width: 8, height: 8), forType: .tiff)
        service.poll()
        XCTAssertEqual(service.entries.map(\.content), [.text("A1\tB1")])
    }

    func testImageIsStoredBoundedAndDecodedOnce() async throws {
        let service = ClipboardService(pasteboard: pasteboard)
        service.setEnabled(true)
        let source = try ClipboardImageFixture.tiff(width: 1600, height: 1200)
        pasteboard.clearContents()
        pasteboard.setData(source, forType: .tiff)
        service.poll()
        await waitFor { !service.entries.isEmpty }

        let entry = try XCTUnwrap(service.entries.first)
        guard case .image(let stored) = entry.content else {
            return XCTFail("expected an image entry")
        }
        XCTAssertLessThan(stored.count, source.count / 10, "the bounded PNG, not the TIFF")
        let thumbnail = try XCTUnwrap(entry.thumbnail, "decoded at capture, not in body")
        XCTAssertLessThanOrEqual(max(thumbnail.width, thumbnail.height),
                                 ClipboardService.thumbnailMaxPixels)
    }

    func testDisablingMidReductionLeavesTheHistoryEmpty() async throws {
        let service = ClipboardService(pasteboard: pasteboard)
        service.setEnabled(true)
        pasteboard.clearContents()
        pasteboard.setData(try ClipboardImageFixture.tiff(width: 800, height: 800), forType: .tiff)
        service.poll()
        // Still on the main actor: the reduction cannot have landed yet.
        service.setEnabled(false)
        service.setEnabled(true)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertTrue(service.entries.isEmpty, "a purge is not undone by a late image")
    }

    func testConcealedClippingIsStillRejected() {
        let service = ClipboardService(pasteboard: pasteboard)
        service.setEnabled(true)
        pasteboard.clearContents()
        pasteboard.setString("hunter2", forType: .string)
        pasteboard.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
        service.poll()
        XCTAssertTrue(service.entries.isEmpty)
    }

    func testOversizedTextIsSkipped() {
        let service = ClipboardService(pasteboard: pasteboard)
        service.setEnabled(true)
        pasteboard.clearContents()
        pasteboard.setString(String(repeating: "z", count: ClipboardService.maxTextBytes + 1),
                             forType: .string)
        service.poll()
        XCTAssertTrue(service.entries.isEmpty)
    }

    func testImageCopyBackWritesTheBoundedPNGAndTIFF() async throws {
        let service = ClipboardService(pasteboard: pasteboard)
        service.setEnabled(true)
        pasteboard.clearContents()
        pasteboard.setData(try ClipboardImageFixture.tiff(width: 1024, height: 512), forType: .tiff)
        service.poll()
        await waitFor { !service.entries.isEmpty }
        let entry = try XCTUnwrap(service.entries.first)

        service.copyBack(entry)
        let png = try XCTUnwrap(pasteboard.data(forType: .png))
        XCTAssertEqual(entry.content, .image(png))
        XCTAssertNotNil(pasteboard.data(forType: .tiff), "for apps that read TIFF only")
        service.poll()
        XCTAssertEqual(service.entries.count, 1, "our own write is not re-captured")
    }

    func testPollTimerFollowsEnablement() {
        let service = ClipboardService(pasteboard: pasteboard)
        XCTAssertFalse(service.isPolling)
        service.setEnabled(true)
        XCTAssertTrue(service.isPolling)
        service.setEnabled(false)
        XCTAssertFalse(service.isPolling)
    }

    func testAScheduledTimerDoesNotKeepTheServiceAlive() {
        weak var weakService: ClipboardService?
        do {
            let service = ClipboardService(pasteboard: pasteboard)
            service.setEnabled(true)
            XCTAssertTrue(service.isPolling)
            weakService = service
        }
        XCTAssertNil(weakService, "the timer must capture weakly so deinit can invalidate it")
    }
}

/// Builds real image bytes for the tests above.
enum ClipboardImageFixture {

    struct Failure: Error {}

    /// An uncompressed TIFF with some structure, so PNG cannot reduce it to
    /// nothing and the size comparisons mean something.
    static func tiff(width: Int, height: Int) throws -> Data {
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw Failure() }
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(red: 0.9, green: 0.3, blue: 0.1, alpha: 1)
        context.fillEllipse(in: CGRect(x: width / 4, y: height / 4,
                                       width: width / 2, height: height / 2))
        guard let image = context.makeImage() else { throw Failure() }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData, UTType.tiff.identifier as CFString, 1, nil) else { throw Failure() }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure() }
        return output as Data
    }
}
