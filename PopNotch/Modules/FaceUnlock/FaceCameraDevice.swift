@preconcurrency import AVFoundation
import os

/// Which cameras a `FaceCamera` may open.
///
/// The lock screen trusts what the camera sees, so it takes only the Mac's
/// own camera: a USB webcam, a Continuity Camera iPhone or an HDMI capture
/// dongle can feed it a recorded video, and injected frames carry none of
/// the glare or bezel the liveness cues look for. With the lid closed there
/// is no built-in camera, and the scan fails rather than fall back.
/// Enrolment happens in Settings with the owner present, and may use any
/// camera.
nonisolated enum FaceCameraPolicy: String, Sendable {
    /// Built-in wide-angle cameras only; nothing when there is none.
    case builtInOnly
    /// The built-in camera when there is one, else the system default.
    case anyCamera

    /// The device types the discovery session asks for. External, desk view
    /// and Continuity cameras are never listed here.
    static let builtInDeviceTypes: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]

    /// Picks from the discovered built-in cameras, and for `.anyCamera` the
    /// system default. `builtIn` is filtered again, so a device that slipped
    /// into the list is still refused: only a wide-angle camera that is not
    /// a Continuity Camera counts as built in. Front-facing first.
    func choose<Device: CameraDeviceDescribing>(builtIn: [Device], systemDefault: () -> Device?) -> Device? {
        let usable = builtIn.filter(Self.isBuiltIn)
        if let pick = usable.first(where: { $0.position == .front }) ?? usable.first {
            return pick
        }
        switch self {
        case .builtInOnly: return nil
        case .anyCamera: return systemDefault()
        }
    }

    static func isBuiltIn(_ device: some CameraDeviceDescribing) -> Bool {
        device.deviceType == .builtInWideAngleCamera && !device.isContinuityCamera
    }

    /// What the user reads when no camera this policy allows is present.
    var noCameraMessage: String {
        switch self {
        case .builtInOnly: "The built-in camera was not found (is the lid closed?). Face Unlock uses only the built-in camera at the lock screen."
        case .anyCamera: "No camera was found."
        }
    }
}

/// The parts of a capture device the policy decides on, so a test can offer
/// it devices that do not exist.
nonisolated protocol CameraDeviceDescribing {
    var deviceType: AVCaptureDevice.DeviceType { get }
    var position: AVCaptureDevice.Position { get }
    var isContinuityCamera: Bool { get }
}

extension AVCaptureDevice: nonisolated CameraDeviceDescribing {}

/// Finds the device for a policy and describes it for the log. Runs on the
/// camera's session queue.
nonisolated enum FaceCameraDeviceFinder {

    private static let logger = Logger(subsystem: "com.techie.PopNotch", category: "FaceUnlock")

    static func device(for policy: FaceCameraPolicy) -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: FaceCameraPolicy.builtInDeviceTypes, mediaType: .video, position: .unspecified)
        return policy.choose(builtIn: discovery.devices) { AVCaptureDevice.default(for: .video) }
    }

    /// Model, type, transport and the system video effects that reframe or
    /// replace the picture (Center Stage, Portrait, Studio Light, background
    /// replacement), which can crop a phone's bezel out or blur it. No
    /// unique ID or name: those can carry a serial or the owner's name.
    static func logChosen(_ device: AVCaptureDevice, policy: FaceCameraPolicy) {
        let builtIn = FaceCameraPolicy.isBuiltIn(device) ? "built-in" : "not built-in"
        logger.notice("Camera chosen (\(policy.rawValue, privacy: .public)): model \(device.modelID, privacy: .public), \(device.deviceType.rawValue, privacy: .public), \(builtIn, privacy: .public), transport \(fourCC(device.transportType), privacy: .public)")
    }

    /// Only meaningful once the session runs.
    static func logEffects(_ device: AVCaptureDevice) {
        var background = "n/a"
        if #available(macOS 15.0, *) { background = onOff(device.isBackgroundReplacementActive) }
        logger.notice("Camera effects: Center Stage \(onOff(device.isCenterStageActive), privacy: .public) (enabled \(onOff(AVCaptureDevice.isCenterStageEnabled), privacy: .public)), Portrait \(onOff(device.isPortraitEffectActive), privacy: .public) (enabled \(onOff(AVCaptureDevice.isPortraitEffectEnabled), privacy: .public)), Studio Light \(onOff(device.isStudioLightActive), privacy: .public), background replacement \(background, privacy: .public)")
    }

    private static func onOff(_ value: Bool) -> String { value ? "on" : "off" }

    /// Core Audio style four-character code, e.g. "bltn" or "usb ".
    static func fourCC(_ value: Int32) -> String {
        let bytes = withUnsafeBytes(of: UInt32(bitPattern: value).bigEndian) { Array($0) }
        guard bytes.allSatisfy({ (0x20...0x7E).contains($0) }) else { return String(value) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
