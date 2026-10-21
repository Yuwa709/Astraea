// Adapted from Glance (github.com/jonnyoo/glance), MIT, (c) 2026 Jonathan Zhou.
// See THIRD-PARTY-LICENSES.md.

@preconcurrency import AVFoundation
import CoreImage
import CoreVideo

/// A downscaled frame for Vision. Frames are never written to disk.
nonisolated struct CameraFrame: @unchecked Sendable {
    let id: UInt64
    let image: CGImage
}

/// Which captured frames get converted. Every one by default (enrolment
/// wants them all); a lock-screen scan past its fast phase switches to one
/// per `request()`, so the frames it never looks at cost no downscale, no
/// image copy and no main-actor hop.
///
/// Set on the main actor, read on the capture queue, hence the lock.
nonisolated final class FrameDemand: @unchecked Sendable {

    /// In every-frame mode, at most one frame per this interval is
    /// converted. The camera delivers about 30 a second, so this keeps every
    /// other one (15 a second; 50 ms sits between one and two frame gaps, so
    /// jitter under about 8 ms does not change that). A scan's fast phase checks
    /// about 8 a second and enrolment about as many (each drops frames that
    /// arrive mid-check), so every check still finds a fresh frame, at half
    /// the downscale work.
    static let everyFrameInterval: TimeInterval = 0.05
    /// A requested frame that fails to convert is replaced by the next
    /// captured one, at most this many times per request, so one bad buffer
    /// does not end a slow-phase scan as "no picture".
    static let maxConversionRetries = 5

    private let lock = NSLock()
    private var everyFrame = true
    private var requested = false
    /// The frame being converted was taken for a request.
    private var takenForRequest = false
    private var retriesLeft = 0
    private var handoffInFlight = false
    private var lastConvertedAt: TimeInterval?

    var convertsEveryFrame: Bool { lock.withLock { everyFrame } }

    /// Either way, a request still pending is dropped.
    func setConvertsEveryFrame(_ value: Bool) {
        lock.withLock {
            everyFrame = value
            requested = false
            takenForRequest = false
        }
    }

    /// The next captured frame is converted.
    func request() {
        lock.withLock {
            requested = true
            takenForRequest = false
            retriesLeft = Self.maxConversionRetries
        }
    }

    /// Asked once per captured frame; a yes uses up the pending request.
    /// No pacing and no hand-over slot: the plain rule, which
    /// `shouldConvert(at:)` builds on.
    func takeFrame() -> Bool {
        lock.withLock {
            if everyFrame { return true }
            guard requested else { return false }
            requested = false
            return true
        }
    }

    /// The capture queue's question for each captured frame, asked before
    /// any conversion work. No while the previous frame is still on its way
    /// to the main actor (one in flight, never a queue), and in every-frame
    /// mode no until `everyFrameInterval` has passed. Neither uses up a
    /// pending request.
    func shouldConvert(at time: TimeInterval) -> Bool {
        lock.withLock {
            guard !handoffInFlight else { return false }
            if everyFrame {
                if let last = lastConvertedAt, time - last < Self.everyFrameInterval { return false }
                lastConvertedAt = time
                return true
            }
            guard requested else { return false }
            requested = false
            takenForRequest = true
            return true
        }
    }

    /// The frame converted: it is on its way, and nothing is taken until
    /// `handoffFinished()`.
    func conversionSucceeded() {
        lock.withLock {
            takenForRequest = false
            handoffInFlight = true
        }
    }

    /// The frame could not be converted. A request it was taken for is
    /// re-armed for the next captured frame, while retries last.
    func conversionFailed() {
        lock.withLock {
            guard takenForRequest else { return }
            takenForRequest = false
            guard retriesLeft > 0 else { return }
            retriesLeft -= 1
            requested = true
        }
    }

    /// The main actor has the frame.
    func handoffFinished() {
        lock.withLock { handoffInFlight = false }
    }
}

/// Sample-buffer callbacks arrive on the camera's output queue. A frame the
/// `FrameDemand` does not want is dropped before any work; the rest are
/// downscaled there and handed over, one at a time, by `deliver`, which
/// must call `demand.handoffFinished()` once the frame has arrived.
nonisolated final class CameraFramePublisher: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {

    typealias Converter = (CVPixelBuffer) -> CGImage?

    let demand: FrameDemand
    private let convert: Converter
    private let deliver: (CameraFrame) -> Void
    /// Touched only on the output queue (or a test's single thread).
    private var nextFrameID: UInt64 = 0

    init(demand: FrameDemand, convert: @escaping Converter = CameraFramePublisher.downscaler(),
         deliver: @escaping (CameraFrame) -> Void) {
        self.demand = demand
        self.convert = convert
        self.deliver = deliver
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        handle(pixelBuffer, at: ProcessInfo.processInfo.systemUptime)
    }

    func handle(_ pixelBuffer: CVPixelBuffer, at time: TimeInterval) {
        guard demand.shouldConvert(at: time) else { return }
        guard let image = convert(pixelBuffer) else {
            demand.conversionFailed()
            return
        }
        demand.conversionSucceeded()
        nextFrameID &+= 1
        deliver(CameraFrame(id: nextFrameID, image: image))
    }

    /// Long edge at most `maxLongEdge`: plenty for Vision.
    static func downscaler(maxLongEdge: CGFloat = 640) -> Converter {
        let context = CIContext()
        return { pixelBuffer in
            var image = CIImage(cvPixelBuffer: pixelBuffer)
            let longEdge = max(image.extent.width, image.extent.height)
            if longEdge > maxLongEdge {
                let scale = maxLongEdge / longEdge
                image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            }
            return context.createCGImage(image, from: image.extent)
        }
    }
}
