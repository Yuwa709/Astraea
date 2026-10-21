import AppKit
import QuickLookThumbnailing
import Observation
import os

/// One file parked on the shelf.
///
/// The bookmark is the identity, not a path: it survives the file being
/// moved or renamed underneath us. `name` is cached alongside so a row can
/// render without resolving anything.
nonisolated struct FileShelfEntry: Identifiable, Equatable {
    let id: UUID
    let bookmark: Data
    let name: String

    init(id: UUID = UUID(), bookmark: Data, name: String) {
        self.id = id
        self.bookmark = bookmark
        self.name = name
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.bookmark == rhs.bookmark }
}

/// Files parked in the notch: references only, in memory only.
///
/// **Nothing is copied, moved, or deleted.** The shelf holds bookmarks to
/// files that stay exactly where the user put them; removing an entry
/// forgets a reference and never touches the file. Nothing is written to
/// disk either, so the shelf empties on quit — persisting a list of the
/// user's file references is a separate decision nobody has made.
///
/// **Security-scoped access is held for as long as the entry is.** Verified
/// 2026-08-30 that `.withSecurityScope` bookmarks resolve and
/// `startAccessingSecurityScopedResource()` returns true even though this
/// app is not sandboxed, where the scope is technically unnecessary. It is
/// kept because a drag-out or a share reads the file *after* the call that
/// started it has returned, so scope has to outlive the gesture — and
/// because it is what makes this correct if the sandbox is ever enabled.
@MainActor
@Observable
final class FileShelfService {

    @ObservationIgnored
    private static let logger = Logger(subsystem: "com.techie.Astraea", category: "FileShelf")

    private(set) var entries: [FileShelfEntry] = []

    /// True while a file drag is over the notch panel. The expanded view
    /// switches on it: at rest it shows the shelf, mid-drag it shows the
    /// Add-to-Shelf / AirDrop chooser. Fed by the coordinator (the only
    /// thing that hears the panel's drag events) via AppDelegate wiring —
    /// the module never touches the panel itself.
    private(set) var dragHovering = false

    func setDragHovering(_ hovering: Bool) {
        guard hovering != dragHovering else { return }
        dragHovering = hovering
        Self.logger.notice("Drag chooser \(hovering ? "shown" : "dismissed", privacy: .public)")
    }

    /// Resolved URLs whose security scope is currently held open, keyed by
    /// entry. Balanced in `release(_:)`, which every removal path goes
    /// through so a scope cannot leak.
    @ObservationIgnored private var accessed: [UUID: URL] = [:]
    /// Observed: thumbnails arrive after the tile first draws, and the tile
    /// has to redraw when one lands.
    private var thumbnails: [UUID: NSImage] = [:]

    /// Entries whose file could not be found the last time it was needed
    /// (deleted, or on a volume no longer mounted). The tile dims; the entry
    /// stays, because the file may come back, and is cleared as soon as the
    /// bookmark resolves again.
    private(set) var missing: Set<UUID> = []

    /// Called with true when a drag out of the shelf begins and false when it
    /// ends. AppDelegate wires it to the panel, which suppresses collapse for
    /// the duration; the module never touches the panel itself.
    @ObservationIgnored var onDragOutChange: ((Bool) -> Void)?

    deinit {
        // Nonisolated: stop each scope directly. Leaving them open outlives
        // any use the process had for them.
        for url in accessed.values { url.stopAccessingSecurityScopedResource() }
    }

    // MARK: - Adding

    @discardableResult
    func add(_ url: URL) -> Bool {
        guard let bookmark = try? url.bookmarkData(options: [.withSecurityScope],
                                                   includingResourceValuesForKeys: nil,
                                                   relativeTo: nil) else {
            Self.logger.error("Could not bookmark \(url.lastPathComponent, privacy: .public)")
            return false
        }
        let entry = FileShelfEntry(bookmark: bookmark, name: url.lastPathComponent)
        guard !entries.contains(entry) else {
            Self.logger.notice("Already shelved: \(entry.name, privacy: .public)")
            return false
        }
        // Open the scope now and hold it: a drag-out reads the file after the
        // gesture that started it has returned.
        if let resolved = Self.resolve(bookmark), resolved.startAccessingSecurityScopedResource() {
            accessed[entry.id] = resolved
        }
        entries.insert(entry, at: 0)
        Self.logger.notice("Shelved \(entry.name, privacy: .public) (\(self.entries.count, privacy: .public) held)")
        Task { await loadThumbnail(for: entry) }
        return true
    }

    // MARK: - Removing

    func remove(_ entry: FileShelfEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries.remove(at: index)
        release(entry.id)
        thumbnails[entry.id] = nil
        missing.remove(entry.id)
        // Worth being explicit in the log: this is a reference being dropped,
        // not a file being touched.
        Self.logger.notice("Unshelved \(entry.name, privacy: .public); file untouched on disk")
    }

    func clear() {
        let count = entries.count
        for entry in entries { release(entry.id) }
        entries.removeAll()
        thumbnails.removeAll()
        missing.removeAll()
        Self.logger.notice("Shelf cleared (\(count, privacy: .public) references dropped; no files touched)")
    }

    private func release(_ id: UUID) {
        accessed[id]?.stopAccessingSecurityScopedResource()
        accessed[id] = nil
    }

    // MARK: - Using

    /// The file's location *now*, with its security scope open.
    ///
    /// Re-resolves the bookmark on every call, which is the point of holding
    /// a bookmark: a file renamed or moved since it was shelved goes out from
    /// where it is, not from where it was. Called when a drag starts and
    /// when a thumbnail loads, never from a view's `body` — resolution
    /// touches the file system.
    ///
    /// When the path has changed, the scope held on the old path is stopped
    /// and one opened on the new path. When the file cannot be found, the
    /// scope is released, the entry is marked `missing`, and nil is
    /// returned so nothing is dragged; the entry stays on the shelf and
    /// recovers by itself if the file comes back.
    func url(for entry: FileShelfEntry) -> URL? {
        let isShelved = entries.contains { $0.id == entry.id }
        guard let resolved = Self.resolve(entry.bookmark),
              FileManager.default.fileExists(atPath: resolved.path) else {
            guard isShelved else { return nil }
            release(entry.id)
            if missing.insert(entry.id).inserted {
                Self.logger.notice("Shelved file missing: \(entry.name, privacy: .public)")
            }
            return nil
        }
        // An entry no longer on the shelf has no scope to hold, and opening
        // one here would leak it: nothing would ever release it.
        guard isShelved else { return resolved }
        if missing.remove(entry.id) != nil {
            Self.logger.notice("Shelved file found again: \(entry.name, privacy: .public)")
        }
        if let current = accessed[entry.id], current.path == resolved.path { return current }
        let moved = accessed[entry.id] != nil
        release(entry.id)
        if resolved.startAccessingSecurityScopedResource() {
            accessed[entry.id] = resolved
        }
        if moved {
            Self.logger.notice("Shelved file moved: \(entry.name, privacy: .public) is now \(resolved.lastPathComponent, privacy: .public)")
        }
        return resolved
    }

    func isMissing(_ entry: FileShelfEntry) -> Bool { missing.contains(entry.id) }

    /// Every caller is on the main thread mid-gesture (a drop, a drag start,
    /// a thumbnail load), so resolution must never block. Without
    /// `.withoutMounting` a bookmark to a share or drive that has gone away
    /// tries to remount it, and without `.withoutUI` that can mean an auth
    /// dialog — the main thread freezes at drag start. With both, such a file
    /// fails to resolve and takes the `missing` path (dimmed, no drag) until
    /// the user remounts the volume. Not mounting costs nothing elsewhere:
    /// `add` resolves a file that was just dropped, so its volume is mounted,
    /// and the shelf is never restored from disk.
    nonisolated static let resolutionOptions: URL.BookmarkResolutionOptions =
        [.withSecurityScope, .withoutUI, .withoutMounting]

    /// Pure, and static so it is testable without a live service.
    nonisolated static func resolve(_ bookmark: Data) -> URL? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark,
                                 options: resolutionOptions,
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else { return nil }
        return url
    }

    func thumbnail(for entry: FileShelfEntry) -> NSImage? { thumbnails[entry.id] }

    private func loadThumbnail(for entry: FileShelfEntry) async {
        guard let url = url(for: entry) else { return }
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: 48, height: 48), scale: 2,
            representationTypes: .all)
        guard let representation = try? await QLThumbnailGenerator.shared
            .generateBestRepresentation(for: request) else { return }
        // The entry may have been removed while the thumbnail rendered;
        // storing it then would hold an image nothing can ever release.
        guard entries.contains(where: { $0.id == entry.id }) else { return }
        thumbnails[entry.id] = NSImage(cgImage: representation.cgImage,
                                       size: NSSize(width: 48, height: 48))
    }

    // MARK: - Sharing

    /// Held for the life of a share. `NSSharingService.delegate` is weak and
    /// the share outlives the call that starts it, so neither can be a local.
    @ObservationIgnored private var activeShare: NSSharingService?
    @ObservationIgnored private let shareDelegate = ShareDelegate()

    /// Sends files via AirDrop, all in one share.
    ///
    /// **The previous implementation silently did nothing, and the comment
    /// that justified it was false.** It built an `NSSharingServicePicker` and
    /// called `show(relativeTo:of:preferredEdge:)` against a zero-size view
    /// inside the notch panel. A picker is a menu, and a menu will not display
    /// for an app with no key window — `NotchPanel.canBecomeKey` is false by
    /// design (hard rule 3). Probed outside the app on 2026-08-30 under
    /// identical conditions (accessory policy, `.nonactivatingPanel`,
    /// `canBecomeKey == false`), the picker's delegate fired and built an
    /// eleven-service menu, and then **no menu window ever reached the
    /// screen**. There is no error and no return value, so nothing could be
    /// logged: the failure was invisible by construction.
    ///
    /// The old comment claimed macOS exposes no direct AirDrop API. It does:
    /// `NSSharingServiceNameSendViaAirDrop` is public, `API_AVAILABLE(macos(10.8))`,
    /// and present in `MacOSX26.5.sdk/…/NSSharingService.h`. It is not a
    /// private interface and needs no reverse engineering.
    ///
    /// It presents ShareKit's own out-of-process window, which requires no key
    /// window of ours. Measured after the call: the panel kept
    /// `canBecomeKey == false`, `isKeyWindow == false`, `isVisible == true`,
    /// and an unchanged level, styleMask and collectionBehavior, so hard rule 3
    /// is untouched and no `NSApplication.activate` is involved. The system's
    /// share window does take focus while it is up — that is the gesture doing
    /// what the user asked, not the notch stealing focus on hover (hard rule 4).
    ///
    /// **Every dropped file goes in one share.** A drop of several files used
    /// to start one share per file, each replacing `activeShare` and so
    /// releasing the share before it while it was still on screen. The URLs
    /// are the ones the drop delivered, used directly: a bookmark
    /// round-trip added nothing and turned a failure into an empty `Data()`.
    func share(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let names = urls.map(\.lastPathComponent).joined(separator: ", ")
        guard let service = NSSharingService(named: .sendViaAirDrop) else {
            Self.logger.error("AirDrop sharing service unavailable")
            return
        }
        guard service.canPerform(withItems: urls) else {
            Self.logger.error("AirDrop cannot send \(names, privacy: .public)")
            return
        }
        service.delegate = shareDelegate
        activeShare = service
        // Permanent, and deliberately carries the paths: a share that
        // silently sends nothing is the failure mode this whole feature has
        // been bitten by twice — once by a picker that never presented, once
        // by a drop whose payload arrived empty. The outcome itself is logged
        // by ShareDelegate below.
        let paths = urls.map(\.path).joined(separator: ", ")
        Self.logger.notice("AirDrop: sending \(urls.count, privacy: .public) file(s): \(paths, privacy: .public)")
        service.perform(withItems: urls)
    }

    // MARK: - Dragging out

    /// A drag out of the shelf began. Forwarded to whoever suppresses the
    /// panel's collapse (AppDelegate wires it); the module never touches the
    /// panel.
    func dragOutBegan(_ entry: FileShelfEntry) {
        Self.logger.notice("Dragging \(entry.name, privacy: .public) out of the shelf")
        onDragOutChange?(true)
    }

    /// The drag session ended, however it ended. The one place collapse
    /// suppression is cleared — see `DragSourceView`.
    func dragOutEnded() {
        onDragOutChange?(false)
    }
}

/// Reports how a share ended. Exists because the picker's failure mode was
/// silence: an outcome nobody logs is an outcome nobody can debug.
@MainActor
private final class ShareDelegate: NSObject, NSSharingServiceDelegate {

    private static let logger = Logger(subsystem: "com.techie.Astraea", category: "FileShelf")

    func sharingService(_ service: NSSharingService, willShareItems items: [Any]) {
        Self.logger.notice("AirDrop: share UI opening")
    }

    func sharingService(_ service: NSSharingService, didShareItems items: [Any]) {
        Self.logger.notice("AirDrop: share completed")
    }

    func sharingService(_ service: NSSharingService,
                        didFailToShareItems items: [Any],
                        error: Error) {
        let code = (error as NSError).code
        // Cancelling the panel reports as an error; it is a normal outcome and
        // should not read like a fault in the log.
        if code == NSUserCancelledError {
            Self.logger.notice("AirDrop: cancelled by the user")
        } else {
            Self.logger.error("AirDrop failed: \(error.localizedDescription, privacy: .public) (\(code, privacy: .public))")
        }
    }
}
