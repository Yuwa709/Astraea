import SwiftUI
import AVFoundation
import AppKit
import os

/// A muted, gapless, aspect-filling video loop for motion artwork.
///
/// `AVQueuePlayer` + `AVPlayerLooper`: the looper keeps the next copy of the
/// item queued, so the seam is decoded ahead of time instead of seeking back
/// to zero at the end, which drops a frame on every pass.
///
/// **It plays only while `isPlaying` is true** (hard rule 9). The caller owns
/// that decision — panel visible, display awake — and this view only obeys
/// it. A paused `AVPlayer` costs nothing per frame; the decoder idles.
///
/// `onFailure` fires once if the asset cannot be loaded or looped, on the
/// main actor, so the caller can swap in the still cover.
struct NativeLoopingPlayerView: NSViewRepresentable {
    let url: URL
    let isPlaying: Bool
    var onFailure: () -> Void = {}

    func makeNSView(context: Context) -> LoopingPlayerHostView {
        let view = LoopingPlayerHostView(url: url)
        view.onFailure = onFailure
        view.setPlaying(isPlaying)
        return view
    }

    func updateNSView(_ nsView: LoopingPlayerHostView, context: Context) {
        nsView.onFailure = onFailure
        nsView.setPlaying(isPlaying)
        // Also done in `layout()`; repeated here so a SwiftUI-driven resize
        // (the panel opening) lands without a layer animation trailing it.
        nsView.syncLayerBounds()
    }

    static func dismantleNSView(_ nsView: LoopingPlayerHostView, coordinator: ()) {
        nsView.tearDown()
    }
}

final class LoopingPlayerHostView: NSView {
    private static let logger = Logger(subsystem: "com.techie.Astraea", category: "MotionArtwork")

    private let player = AVQueuePlayer()
    private let playerLayer: AVPlayerLayer
    private var looper: AVPlayerLooper?
    private var statusObservation: NSKeyValueObservation?
    private var isPlaying = false
    private var failed = false
    var onFailure: () -> Void = {}

    init(url: URL) {
        playerLayer = AVPlayerLayer(player: player)
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        playerLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(playerLayer)

        player.isMuted = true
        // AVPlayer holds a display-sleep assertion while playing by default.
        // Decorative artwork must never keep the user's screen on.
        player.preventsDisplaySleepDuringVideoPlayback = false

        let looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        statusObservation = looper.observe(\.status, options: [.new]) { [weak self] looper, _ in
            guard looper.status == .failed else { return }
            let reason = looper.error?.localizedDescription ?? "unknown"
            Task { @MainActor [weak self] in self?.fail(reason: reason) }
        }
        self.looper = looper
        Self.logger.notice("Motion artwork loaded: \(url.lastPathComponent, privacy: .public)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        syncLayerBounds()
    }

    /// Bounds and position with implicit actions off, so the layer tracks
    /// the panel's resize exactly instead of easing after it.
    func syncLayerBounds() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.bounds = CGRect(origin: .zero, size: bounds.size)
        playerLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }

    func setPlaying(_ playing: Bool) {
        let shouldPlay = playing && !failed
        guard shouldPlay != isPlaying else { return }
        isPlaying = shouldPlay
        if shouldPlay {
            player.play()
            Self.logger.notice("Motion artwork playing")
        } else {
            player.pause()
            Self.logger.notice("Motion artwork paused")
        }
    }

    private func fail(reason: String) {
        guard !failed else { return }
        failed = true
        setPlaying(false)
        Self.logger.notice("Motion artwork failed, falling back to still: \(reason, privacy: .public)")
        onFailure()
    }

    /// Releases the decoder and the looper's queued items. Called when SwiftUI
    /// removes the view, so nothing outlives the artwork on screen.
    func tearDown() {
        statusObservation?.invalidate()
        statusObservation = nil
        looper?.disableLooping()
        looper = nil
        player.pause()
        player.removeAllItems()
        playerLayer.player = nil
        isPlaying = false
        Self.logger.notice("Motion artwork torn down")
    }

    deinit {
        statusObservation?.invalidate()
    }
}
