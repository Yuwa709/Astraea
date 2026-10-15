import XCTest
@testable import PopNotch

/// The shelf holds references, never copies. These run against real files in
/// a scratch directory so the bookmark round-trip is genuinely exercised.
@MainActor
final class FileShelfServiceTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("popnotch-shelf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    @discardableResult
    private func makeFile(_ name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try "contents".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - The guarantee that matters

    func testRemovingAnEntryNeverTouchesTheFile() throws {
        let url = try makeFile("keep.txt")
        let service = FileShelfService()
        XCTAssertTrue(service.add(url))
        service.remove(service.entries[0])

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "unshelving drops a reference; the file must survive")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "contents",
                       "and must be unmodified")
    }

    func testClearNeverTouchesTheFiles() throws {
        let a = try makeFile("a.txt"), b = try makeFile("b.txt")
        let service = FileShelfService()
        service.add(a); service.add(b)
        service.clear()

        XCTAssertTrue(service.entries.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.path))
    }

    func testAddingDoesNotCopyTheFileAnywhere() throws {
        let url = try makeFile("original.txt")
        let service = FileShelfService()
        service.add(url)
        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(contents, ["original.txt"], "no copy is made beside the original")
    }

    // MARK: - Bookmarks, not paths

    func testEntryStoresABookmarkThatResolvesBack() throws {
        let url = try makeFile("resolve.txt")
        let service = FileShelfService()
        service.add(url)
        let entry = try XCTUnwrap(service.entries.first)

        XCTAssertFalse(entry.bookmark.isEmpty, "a bookmark, not a path string")
        let resolved = try XCTUnwrap(FileShelfService.resolve(entry.bookmark))
        XCTAssertEqual(resolved.lastPathComponent, "resolve.txt")
    }

    func testBookmarkSurvivesARename() throws {
        // The reason for bookmarks over paths: the file can move.
        let url = try makeFile("before.txt")
        let service = FileShelfService()
        service.add(url)
        let entry = try XCTUnwrap(service.entries.first)

        let moved = directory.appendingPathComponent("after.txt")
        try FileManager.default.moveItem(at: url, to: moved)

        let resolved = FileShelfService.resolve(entry.bookmark)
        XCTAssertEqual(resolved?.lastPathComponent, "after.txt",
                       "a stored path would now be dangling")
    }

    func testUnresolvableBookmarkYieldsNil() {
        XCTAssertNil(FileShelfService.resolve(Data([0x00, 0x01, 0x02])))
    }

    // MARK: - Shape

    func testNewestFirst() throws {
        let service = FileShelfService()
        service.add(try makeFile("one.txt"))
        service.add(try makeFile("two.txt"))
        XCTAssertEqual(service.entries.map(\.name), ["two.txt", "one.txt"])
    }

    func testTheSameFileIsNotShelvedTwice() throws {
        let url = try makeFile("dup.txt")
        let service = FileShelfService()
        XCTAssertTrue(service.add(url))
        XCTAssertFalse(service.add(url), "a second add is refused")
        XCTAssertEqual(service.entries.count, 1)
    }

    func testStartsEmpty() {
        XCTAssertTrue(FileShelfService().entries.isEmpty)
    }
}

/// Off by default, and disabling drops every reference.
@MainActor
final class FileShelfModuleTests: XCTestCase {

    func testOffByDefault() {
        XCTAssertFalse(FileShelfModule(service: FileShelfService()).isEnabled,
                       "holding references to a user's files is opt-in")
    }

    func testKeepsOutOfTheCollapsedRow() {
        XCTAssertFalse(FileShelfModule(service: FileShelfService()).wantsCompactDisplay)
    }

    func testDisablingDropsEveryReference() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("popnotch-shelf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("x.txt")
        try "x".write(to: url, atomically: true, encoding: .utf8)

        let service = FileShelfService()
        let module = FileShelfModule(service: service)
        module.isEnabled = true
        service.add(url)
        XCTAssertEqual(service.entries.count, 1)

        module.isEnabled = false
        XCTAssertTrue(service.entries.isEmpty, "and the security scopes close with them")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "file still untouched")
    }

    // MARK: - What the AirDrop zone depends on

    /// The share used to go through `NSSharingServicePicker`, which builds its
    /// menu and then never presents it when the app has no key window — the
    /// notch panel cannot become key by design. The direct AirDrop service is
    /// the replacement, so its availability is now load-bearing. It failing
    /// would put the zone straight back to doing nothing visible, and doing it
    /// silently, so assert it rather than trust it.
    func testAirDropServiceIsAvailableForARealFile() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("popnotch-share-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("share-me.txt")
        try "contents".write(to: url, atomically: true, encoding: .utf8)

        let service = try XCTUnwrap(NSSharingService(named: .sendViaAirDrop),
                                    "NSSharingServiceNameSendViaAirDrop is public API since macOS 10.8")
        XCTAssertTrue(service.canPerform(withItems: [url]),
                      "AirDrop must accept an ordinary local file")
    }
}

/// The drag-hover flag driving the chooser/shelf view swap.
@MainActor
final class FileShelfDragHoverTests: XCTestCase {

    func testStartsAtRest() {
        XCTAssertFalse(FileShelfService().dragHovering)
    }

    func testFlagFlipsWithTheDrag() {
        let service = FileShelfService()
        service.setDragHovering(true)
        XCTAssertTrue(service.dragHovering, "drag over the panel shows the chooser")
        service.setDragHovering(true)
        XCTAssertTrue(service.dragHovering, "redundant set is harmless")
        service.setDragHovering(false)
        XCTAssertFalse(service.dragHovering, "drag leaving restores the shelf")
    }
}
