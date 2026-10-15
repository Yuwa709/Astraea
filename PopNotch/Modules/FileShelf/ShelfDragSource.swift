import AppKit
import SwiftUI
import os

/// An AppKit drag source for one shelf item.
///
/// **Why this exists instead of SwiftUI's `.onDrag`.** Measured 2026-08-30: a
/// drag started by `.onDrag` and dropped on a SwiftUI `.onDrop` *in the same
/// process* hands the drop zone an `NSItemProvider` with **zero** registered
/// type identifiers. `loadObject(ofClass: URL.self)` then fails with
/// `NSItemProviderErrorDomain -1200 "Could not coerce an item to class NSURL"`,
/// the `guard let url else { return }` in the drop handler swallows it, and
/// nothing downstream ever runs — no error, no log, no share sheet.
///
/// The dragging pasteboard itself was fine throughout: `carriesFiles` read
/// true and `draggingEntered` returned `.copy` for exactly those drags. Only
/// the provider handed across SwiftUI's own intra-app bridge was empty. A drag
/// arriving from another app has no such bridge — it comes through the
/// pasteboard, arrives as `public.file-url`, and has always worked.
///
/// So the fix is to make our drag look like that one: an AppKit session
/// writing the URL to the pasteboard directly, which the drop zone then reads
/// the same way it reads an external drag.
struct ShelfDragSource: NSViewRepresentable {

    /// Called when a drag starts, so the file goes out from where it is now
    /// rather than where it was when the view was built.
    let resolveURL: () -> URL?
    let thumbnail: NSImage?
    /// True while the hover controls (AirDrop and remove) are showing, so the
    /// corners they occupy stop swallowing clicks. See `DragSourceView.hitTest`.
    let excludesHoverControls: Bool
    let onDragBegan: () -> Void
    let onDragEnded: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = DragSourceView()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? DragSourceView else { return }
        apply(to: view)
    }

    private func apply(to view: DragSourceView) {
        view.resolveURL = resolveURL
        view.thumbnail = thumbnail
        view.excludesHoverControls = excludesHoverControls
        view.onDragBegan = onDragBegan
        view.onDragEnded = onDragEnded
    }
}

/// The real drag source. Kept file-private to the module so nothing outside
/// the shelf can start one of these.
final class DragSourceView: NSView, NSDraggingSource {

    private static let logger = Logger(subsystem: "com.techie.PopNotch", category: "FileShelf")

    var resolveURL: (() -> URL?)?
    var thumbnail: NSImage?
    var excludesHoverControls = false
    var onDragBegan: (() -> Void)?
    var onDragEnded: (() -> Void)?

    /// True from a session's start to its end, so the end callback fires
    /// exactly once per begin. Collapse suppression is cleared through the
    /// callback rather than through this view's window: by the end the view
    /// may no longer be in one, and the flag still has to be cleared or the
    /// panel never collapses again.
    private var sessionActive = false

    /// One resolution per press. `mouseDragged` repeats for every movement
    /// until a session starts, and a missing file would otherwise be looked
    /// up on disk at every one.
    private var pressResolved = false

    /// The panel never becomes key and the app never activates (hard rules 3
    /// and 4), so without this the first press on a shelf item would be
    /// swallowed as an activation click and no drag would start.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Consumed so `mouseDragged` is delivered. A press that never moves does
    /// nothing at all.
    override func mouseDown(with event: NSEvent) {
        pressResolved = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !pressResolved else { return }
        pressResolved = true
        // Resolved now, as the drag starts, so a file moved or renamed since
        // it was shelved goes out from where it is.
        guard let url = resolveURL?() else { return }
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        // The thumbnail the row already shows, so the drag looks unchanged.
        // Falling back to the file's Finder icon rather than nothing, which
        // would drag an invisible item.
        let image = thumbnail ?? NSWorkspace.shared.icon(forFile: url.path)
        item.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    /// The remove button is a SwiftUI view drawn above this one, but a real
    /// `NSView` hit-tests ahead of the host's own drawing, so without this it
    /// would be unclickable where it overlaps the thumbnail. Only excluded
    /// while the button is actually showing.
    override func hitTest(_ point: NSPoint) -> NSView? {
        if excludesHoverControls {
            // `point` arrives in the superview's coordinates; the corner is
            // in this view's own.
            let local = convert(point, from: superview)
            let corner = NSRect(x: bounds.maxX - 20, y: bounds.maxY - 20, width: 20, height: 20)
            if corner.contains(local) { return nil }
        }
        return super.hitTest(point)
    }

    // MARK: - NSDraggingSource

    /// `.copy` for **both** contexts. `.withinApplication` is this app's own
    /// AirDrop bar and shelf; `.outsideApplication` is Finder, the Dock, Mail.
    /// Returning `[]` for the former is the classic way an app ends up
    /// refusing its own drags, so both are spelled out rather than defaulted.
    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        switch context {
        case .withinApplication: return .copy
        case .outsideApplication: return .copy
        @unknown default: return .copy
        }
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        // Suppress collapse for the duration: the drag leaves the panel by
        // design, and the normal exit rules would tear down the very view
        // that started it. The service forwards this to the panel through
        // AppDelegate; this view never touches the panel.
        sessionActive = true
        onDragBegan?()
    }

    /// The single place suppression is cleared, and therefore the single place
    /// collapse is re-armed.
    ///
    /// This matters more than it looks. `NotchHoverView.endDrag` is the only
    /// thing that schedules a collapse once a drag finishes, and it fires
    /// *during* the drag, while suppression is on — so its `beginExit()` is
    /// dropped. Clearing the flag here re-runs that evaluation against the
    /// real cursor position. Without it the panel would stay open after every
    /// single drag-out until the pointer happened to wander in and out again.
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        Self.logger.notice("Drag out ended (operation \(operation.rawValue, privacy: .public))")
        guard sessionActive else { return }
        sessionActive = false
        onDragEnded?()
    }
}
