// Adapted from Glance (github.com/jonnyoo/glance), MIT, (c) 2026 Jonathan Zhou.
// See THIRD-PARTY-LICENSES.md.

import CoreGraphics

/// One face frame in, its liveness measurements out. Blocking and
/// CPU-bound: called off the main actor, in the same task as recognition.
nonisolated protocol LivenessSampling: Sendable {
    /// `faceBox` is the recognised face, in `frame.image`'s top-left pixel
    /// space.
    func sample(_ frame: CameraFrame, faceBox: CGRect) -> LivenessSample
}

/// Both cues on the frame the recognizer already has: the 640 px working
/// frame, not a native-resolution crop as in Glance, so no pixel buffer is
/// kept. Glance's glare level was calibrated on native crops; check the
/// logged values on hardware before trusting it.
nonisolated struct VisionLivenessSampler: LivenessSampling {
    func sample(_ frame: CameraFrame, faceBox: CGRect) -> LivenessSample {
        let image = frame.image
        let imageSize = CGSize(width: image.width, height: image.height)
        let glare = GlareCueExtractor.cropRect(around: faceBox, imageSize: imageSize)
            .flatMap { image.cropping(to: $0) }
            .flatMap { GlareCueExtractor.extract(faceCrop: $0) }
        return LivenessSample(glare: glare, device: DeviceBezelDetector.detect(in: image, faceBox: faceBox))
    }
}
