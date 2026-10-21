import AppKit
import ImageIO
import Observation
import UniformTypeIdentifiers
import os

/// One captured clipboard entry. In memory only — never written to disk.
///
/// `nonisolated`: this target sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`,
/// so an unannotated type here would carry a main-actor-isolated `Equatable`
/// conformance that the pure, nonisolated de-duplication cannot use.
nonisolated struct ClipboardEntry: Identifiable, Equatable {

    /// An image is held only as the bounded PNG made at capture (at most
    /// `ClipboardService.thumbnailMaxPixels` on its long side), never as the
    /// source app's full-size bytes — see `ClipboardService.makeThumbnail`.
    enum Content: Equatable {
        case text(String)
        case image(Data)
    }

    let id = UUID()
    let content: Content
    let capturedAt: Date
    /// The image decoded once, at capture, so the grid never decodes in
    /// `body`. Nil for text. Not part of equality: it is derived from
    /// `content`.
    let thumbnail: CGImage?

    init(content: Content, capturedAt: Date = Date(), thumbnail: CGImage? = nil) {
        self.content = content
        self.capturedAt = capturedAt
        self.thumbnail = thumbnail
    }

    /// What this entry costs to hold, for the history's byte cap.
    var byteCount: Int {
        switch content {
        case .text(let text): return text.utf8.count
        case .image(let data): return data.count
        }
    }

    /// Equality ignores `id` and `capturedAt`: two entries are the same
    /// clipping if they hold the same bytes, which is what de-duplication
    /// needs when the user copies the same thing twice. For an image those
    /// bytes are the bounded thumbnail, so a comparison costs kilobytes,
    /// not the tens of megabytes a full-size TIFF would.
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.content == rhs.content }
}

/// Clipboard history, capped and in memory.
///
/// **Nothing here touches disk.** The roadmap is blunt that this feature
/// stores everything the user copies and is the single thing most likely to
/// make a reviewer distrust a background agent. It is therefore off by
/// default, capped at ten entries, and lost on quit. Persisting it is a
/// separate decision nobody has made.
///
/// **Bounded in bytes, not just entries.** Images are reduced at capture to a
/// small PNG, oversized sources and oversized text are skipped, and the whole
/// history has a byte ceiling — ten entries of full-size 5K TIFFs would
/// otherwise be over half a gigabyte.
///
/// **Concealed items are never read, not merely never stored.** The type
/// check happens before any content is pulled off the pasteboard, so a
/// password manager's clipping is not momentarily held in this process.
///
/// **Hard rule 9, with one documented exception.** The timer stops when the
/// display sleeps and when the module is disabled. It deliberately does NOT
/// stop when the module is off screen: capture only-while-visible would
/// record nothing, since the point is to have a history ready by the time
/// you open the notch. The mitigations are that the poll is a single
/// integer read once a second, that it is off by default, and that both
/// other suspend paths are honoured.
@MainActor
@Observable
final class ClipboardService {

    @ObservationIgnored
    private static let logger = Logger(subsystem: "com.techie.Astraea", category: "Clipboard")

    /// Ten is the roadmap's cap. A bigger history is a bigger pile of the
    /// user's secrets sitting in memory for no proportionate gain.
    @ObservationIgnored static let historyLimit = 10

    /// The whole history's byte ceiling, on top of the ten-entry cap. Ten
    /// thumbnails at their worst stay near it; it exists so no mix of
    /// clippings can make an idle menu bar agent hold tens of megabytes.
    @ObservationIgnored nonisolated static let historyByteLimit = 8 * 1024 * 1024

    /// Text longer than this is not recorded. Skipped rather than truncated:
    /// a truncated entry copied back would silently paste only part of what
    /// the user copied.
    @ObservationIgnored nonisolated static let maxTextBytes = 256 * 1024

    /// An image whose pasteboard data is larger than this is not decoded at
    /// all. Sized to admit a 5K frame as uncompressed TIFF (5120 x 2880 x 4
    /// is about 59 MB) and little more.
    @ObservationIgnored nonisolated static let maxSourceImageBytes = 64 * 1024 * 1024

    /// The long side, in pixels, of the PNG an image is reduced to at
    /// capture. The grid cell is 120x74 pt, so this is ample for display. It
    /// is also what a copy-back writes, since the original is never kept.
    @ObservationIgnored nonisolated static let thumbnailMaxPixels = 512

    /// One second: `changeCount` is a single integer read, and anything
    /// slower feels like the notch missed a copy.
    @ObservationIgnored static let interval: TimeInterval = 1

    /// Lets the system coalesce the wake-up with others. A copy noticed a
    /// fraction of a second later is still noticed.
    @ObservationIgnored static let tolerance: TimeInterval = 0.3

    /// Markers the pasteboard community uses to say "do not record this".
    /// `ConcealedType` is what password managers set; the other two mark
    /// clippings written by tooling rather than by a person.
    @ObservationIgnored
    nonisolated static let excludedTypes: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType",
    ]

    private(set) var entries: [ClipboardEntry] = []

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var displayAsleep = false
    @ObservationIgnored private var isEnabled = false
    /// Seeded from the current count so the clipping already sitting on the
    /// pasteboard at enable time is not swept up retroactively.
    @ObservationIgnored private var lastChangeCount: Int
    /// Bumped whenever the history is purged (disable, Clear), so an image
    /// still being reduced off the main actor cannot land in a history the
    /// user has just emptied.
    @ObservationIgnored private var captureGeneration = 0

    /// The pasteboard watched: `.general` in the app; a private, uniquely
    /// named one in tests, so they never read or write the user's clipboard.
    @ObservationIgnored private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        lastChangeCount = pasteboard.changeCount
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(displayDidSleep),
                           name: NSWorkspace.screensDidSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(displayDidWake),
                           name: NSWorkspace.screensDidWakeNotification, object: nil)
    }

    deinit {
        timer?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: - Pure logic (testable without a pasteboard)

    /// Whether a clipping carrying these types may be recorded.
    ///
    /// Called *before* the content is read, which is the whole point.
    nonisolated static func shouldCapture(types: [String]) -> Bool {
        !types.contains { excludedTypes.contains($0) }
    }

    /// What a clipping should be read as, decided from its types alone so
    /// nothing is pulled off the pasteboard — or rendered by the source app
    /// from a promise — that will not be kept.
    nonisolated enum CaptureKind: Equatable {
        case text
        case image(NSPasteboard.PasteboardType)
    }

    /// Text wins whenever it is offered. A spreadsheet cell copy offers text
    /// *and* a rendered picture of the cells, and the text is what the user
    /// copied; asking for the picture would also make the source app render
    /// data it had only promised. A file copy is not recorded as an image
    /// either — Finder offers the file's icon, which is not what was copied.
    /// An image is taken only when it is all there is, PNG ahead of TIFF as
    /// the smaller read.
    nonisolated static func captureKind(types: [String]) -> CaptureKind? {
        let offered = Set(types)
        if offered.contains(NSPasteboard.PasteboardType.string.rawValue) { return .text }
        if offered.contains(NSPasteboard.PasteboardType.fileURL.rawValue) { return nil }
        if offered.contains(NSPasteboard.PasteboardType.png.rawValue) { return .image(.png) }
        if offered.contains(NSPasteboard.PasteboardType.tiff.rawValue) { return .image(.tiff) }
        return nil
    }

    /// Whether a string is worth recording: not blank, and under the cap.
    nonisolated static func shouldRecord(text: String) -> Bool {
        text.utf8.count <= maxTextBytes
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Newest first, de-duplicated, capped by count and by total bytes.
    /// Re-copying something already in the history moves it to the top
    /// rather than adding a duplicate. The byte cap drops the oldest first
    /// and never drops the entry just inserted.
    nonisolated static func inserting(_ entry: ClipboardEntry,
                                      into existing: [ClipboardEntry],
                                      limit: Int,
                                      byteLimit: Int = historyByteLimit) -> [ClipboardEntry] {
        guard limit > 0 else { return [] }
        var result = existing.filter { $0 != entry }
        result.insert(entry, at: 0)
        if result.count > limit { result.removeLast(result.count - limit) }
        var total = result.reduce(0) { $0 + $1.byteCount }
        while total > byteLimit, result.count > 1 {
            total -= result.removeLast().byteCount
        }
        return result
    }

    /// Reduces pasteboard image bytes to a PNG at most `maxPixels` on its
    /// long side. Nil if the source is over `maxSourceBytes`, is not an
    /// image, or will not encode. ImageIO decodes straight to the reduced
    /// size, so the full-resolution bitmap is never materialised.
    ///
    /// Pure and `nonisolated`: it runs off the main actor at capture.
    nonisolated static func makeThumbnail(from data: Data,
                                          maxPixels: Int = thumbnailMaxPixels,
                                          maxSourceBytes: Int = maxSourceImageBytes) -> Data? {
        guard data.count <= maxSourceBytes, maxPixels > 0,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// Decodes an already-bounded thumbnail once, for the grid to draw.
    nonisolated static func decodeThumbnail(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true]
        return CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary)
    }

    /// One-line preview. Collapses whitespace so a copied code block does
    /// not render as a tall ragged block in a notch-sized row.
    nonisolated static func preview(of text: String, limit: Int = 48) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit)) + "…"
    }

    // MARK: - Lifecycle

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        Self.logger.notice("Clipboard history \(enabled ? "enabled" : "disabled", privacy: .public)")
        if !enabled {
            // Disabling is not just "stop looking": what was captured goes
            // too, so turning it off is a way to purge.
            entries.removeAll()
            captureGeneration += 1
        }
        updateTimer()
    }

    /// Whether the poll timer is scheduled. Exposed so the suspend paths are
    /// something a test can assert rather than something a comment claims.
    var isPolling: Bool { timer != nil }

    private func updateTimer() {
        let shouldRun = isEnabled && !displayAsleep
        guard shouldRun != (timer != nil) else { return }
        if shouldRun {
            lastChangeCount = pasteboard.changeCount
            // Weak at both levels. With `[weak self]` only on the inner Task,
            // the outer closure captures `self` strongly to hand it on, so
            // the timer kept the service alive and deinit never ran.
            let timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.poll() }
            }
            timer.tolerance = Self.tolerance
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            Self.logger.notice("Clipboard poll started")
        } else {
            timer?.invalidate()
            timer = nil
            Self.logger.notice("Clipboard poll stopped")
        }
    }

    @objc private func displayDidSleep() {
        displayAsleep = true
        Self.logger.notice("Display asleep; clipboard poll suspended")
        updateTimer()
    }

    @objc private func displayDidWake() {
        displayAsleep = false
        Self.logger.notice("Display awake; clipboard poll resumes if enabled")
        updateTimer()
    }

    // MARK: - Capture

    /// One look at the pasteboard. Internal rather than private so tests can
    /// drive it against a private pasteboard instead of waiting on the timer.
    func poll() {
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount

        let types = (pasteboard.types ?? []).map(\.rawValue)
        guard Self.shouldCapture(types: types) else {
            // Count only. The whole point is that this content never leaves
            // the pasteboard, so it certainly never reaches the log.
            Self.logger.notice("Skipped a concealed or transient clipping")
            return
        }

        switch Self.captureKind(types: types) {
        case .text:
            guard let text = pasteboard.string(forType: .string),
                  stillCurrent(changeCount) else { return }
            guard Self.shouldRecord(text: text) else {
                if text.utf8.count > Self.maxTextBytes {
                    Self.logger.notice("Skipped text over the size cap (\(text.utf8.count, privacy: .public) bytes)")
                }
                return
            }
            record(ClipboardEntry(content: .text(text)))
        case .image(let type):
            guard let data = pasteboard.data(forType: type),
                  stillCurrent(changeCount) else { return }
            guard data.count <= Self.maxSourceImageBytes else {
                Self.logger.notice("Skipped an image over the size cap (\(data.count, privacy: .public) bytes)")
                return
            }
            recordImage(data)
        case nil:
            return
        }
    }

    /// The privacy check read the *types* of one clipping; the content is
    /// read a moment later. If the pasteboard changed in between, that
    /// content may belong to a clipping that was never checked — a password
    /// manager's — so it is discarded. The next poll sees the new count and
    /// checks the new clipping properly.
    private func stillCurrent(_ changeCount: Int) -> Bool {
        guard pasteboard.changeCount == changeCount else {
            Self.logger.notice("Pasteboard changed mid-read; clipping discarded")
            return false
        }
        return true
    }

    /// Reduces the image off the main actor, then records it unless the
    /// history was disabled or cleared in the meantime.
    private func recordImage(_ data: Data) {
        let generation = captureGeneration
        Task.detached(priority: .utility) { [weak self] in
            let png = ClipboardService.makeThumbnail(from: data)
            await self?.finishImage(png, generation: generation)
        }
    }

    private func finishImage(_ png: Data?, generation: Int) {
        guard isEnabled, generation == captureGeneration else { return }
        guard let png, let image = Self.decodeThumbnail(png) else {
            Self.logger.notice("Skipped an image that could not be reduced")
            return
        }
        record(ClipboardEntry(content: .image(png), thumbnail: image))
    }

    private func record(_ entry: ClipboardEntry) {
        entries = Self.inserting(entry, into: entries, limit: Self.historyLimit)
        let bytes = entries.reduce(0) { $0 + $1.byteCount }
        Self.logger.notice("Captured a clipping (\(self.entries.count, privacy: .public) held, \(bytes, privacy: .public) bytes)")
    }

    // MARK: - Actions

    /// Puts an entry back on the pasteboard.
    ///
    /// An image goes back as the bounded thumbnail the history holds — at
    /// most `thumbnailMaxPixels` on its long side — because the original is
    /// never kept. Written as PNG and TIFF, so apps that read only one of
    /// the two still accept it.
    func copyBack(_ entry: ClipboardEntry) {
        pasteboard.clearContents()
        switch entry.content {
        case .text(let text):
            pasteboard.setString(text, forType: .string)
        case .image(let png):
            pasteboard.declareTypes([.png, .tiff], owner: nil)
            pasteboard.setData(png, forType: .png)
            if let image = entry.thumbnail ?? Self.decodeThumbnail(png),
               let tiff = NSBitmapImageRep(cgImage: image).tiffRepresentation {
                pasteboard.setData(tiff, forType: .tiff)
            }
        }
        // Our own write must not read back as a fresh capture.
        lastChangeCount = pasteboard.changeCount
        Self.logger.notice("Copied an entry back to the pasteboard")
    }

    func clear() {
        let count = entries.count
        entries.removeAll()
        captureGeneration += 1
        Self.logger.notice("History cleared (\(count, privacy: .public) discarded)")
    }
}
