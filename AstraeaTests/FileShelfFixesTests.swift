import XCTest
import AppKit
@testable import Astraea

/// The shelf hands out where a file is now, not where it was when shelved.
@MainActor
final class FileShelfResolutionTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("popnotch-shelf-fixes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private func makeFile(_ name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try "contents".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testURLAfterARenameIsTheNewPath() throws {
        let service = FileShelfService()
        XCTAssertTrue(service.add(try makeFile("before.txt")))
        let entry = try XCTUnwrap(service.entries.first)
        XCTAssertEqual(service.url(for: entry)?.lastPathComponent, "before.txt")

        try FileManager.default.moveItem(at: directory.appendingPathComponent("before.txt"),
                                         to: directory.appendingPathComponent("after.txt"))

        XCTAssertEqual(service.url(for: entry)?.lastPathComponent, "after.txt",
                       "the add-time path would now be dangling")
        XCTAssertFalse(service.isMissing(entry))
    }

    func testURLAfterAMoveToAnotherFolderFollowsIt() throws {
        let service = FileShelfService()
        service.add(try makeFile("travels.txt"))
        let entry = try XCTUnwrap(service.entries.first)
        let sub = directory.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: directory.appendingPathComponent("travels.txt"),
                                         to: sub.appendingPathComponent("travels.txt"))

        let url = try XCTUnwrap(service.url(for: entry))
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "sub")
    }

    func testADeletedFileIsMarkedMissingAndStaysShelved() throws {
        let url = try makeFile("gone.txt")
        let service = FileShelfService()
        service.add(url)
        let entry = try XCTUnwrap(service.entries.first)
        try FileManager.default.removeItem(at: url)

        XCTAssertNil(service.url(for: entry), "nothing to drag")
        XCTAssertTrue(service.isMissing(entry))
        XCTAssertEqual(service.entries.count, 1, "kept: the file may come back")

        service.remove(entry)
        XCTAssertFalse(service.isMissing(entry), "removal forgets the missing mark too")
    }

    func testResolutionNeverMountsOrShowsUI() {
        // Resolution runs on the main thread at drag start; a bookmark to an
        // unmounted share must fail fast to `missing`, not remount or prompt.
        let options = FileShelfService.resolutionOptions
        XCTAssertTrue(options.contains(.withoutMounting))
        XCTAssertTrue(options.contains(.withoutUI))
        XCTAssertTrue(options.contains(.withSecurityScope), "scope still opened")
    }

    func testAThumbnailForARemovedEntryIsNotKept() async throws {
        let service = FileShelfService()
        service.add(try makeFile("quick.txt"))
        let entry = try XCTUnwrap(service.entries.first)
        service.remove(entry)
        // Long enough for the Quick Look render started by `add` to land.
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertNil(service.thumbnail(for: entry))
    }
}

/// Drag-out reaches the panel only through the service's callback.
@MainActor
final class FileShelfDragOutTests: XCTestCase {

    func testDragOutBeginAndEndAreForwarded() {
        let service = FileShelfService()
        var reported: [Bool] = []
        service.onDragOutChange = { reported.append($0) }
        let entry = FileShelfEntry(bookmark: Data([0x1]), name: "x.txt")
        service.dragOutBegan(entry)
        service.dragOutEnded()
        XCTAssertEqual(reported, [true, false])
    }

    func testRemoveButtonCornerIsExcludedInTheViewsOwnCoordinates() {
        // The view sits away from the superview's origin, which is exactly
        // where comparing a superview-space point to `bounds` went wrong.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        let source = DragSourceView(frame: NSRect(x: 100, y: 100, width: 64, height: 64))
        container.addSubview(source)
        source.excludesHoverControls = true

        // Top-right corner of the source, in the superview's coordinates.
        XCTAssertNil(source.hitTest(NSPoint(x: 160, y: 160)), "the remove button's corner")
        XCTAssertTrue(source.hitTest(NSPoint(x: 110, y: 110)) === source, "the rest drags")

        source.excludesHoverControls = false
        XCTAssertTrue(source.hitTest(NSPoint(x: 160, y: 160)) === source,
                      "no exclusion while the controls are hidden")
    }
}
