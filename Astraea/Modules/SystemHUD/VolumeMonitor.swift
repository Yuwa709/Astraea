import CoreAudio
import AudioToolbox
import os

/// One reading of the default output device's volume.
struct VolumeReading: Equatable, Sendable {
    /// 0...1, as the system volume slider shows it.
    var level: Double
    var isMuted: Bool

    /// What the bar draws: a muted device reads empty, as the system HUD does.
    var displayLevel: Double { isMuted ? 0 : min(max(level, 0), 1) }

    /// Whether `current` is a change worth showing. Core Audio can re-post
    /// a property with an unchanged value (a device waking, a format change),
    /// and a HUD for nothing reads as a glitch. The tolerance is far below
    /// one system step (1/16), so no real key press is ever swallowed.
    static func isAnnounceable(from previous: VolumeReading?, to current: VolumeReading) -> Bool {
        guard let previous else { return false }
        return previous.isMuted != current.isMuted
            || abs(previous.level - current.level) > 0.001
    }
}

/// Watches the default output device's volume and mute through Core Audio
/// property listeners. Push-driven: no timer exists (hard rule 9).
///
/// A change of default device re-baselines silently — plugging in
/// headphones is not a volume change — and re-registers the per-device
/// listeners on the new device. A device with no volume control (most HDMI
/// sinks) simply never reports; the system shows its own "not adjustable"
/// notice for those.
@MainActor
final class VolumeMonitor {

    private static let logger = Logger(subsystem: "com.techie.Astraea", category: "SystemHUD")

    /// A real change on the current device. Not called for the initial
    /// reading or for a device switch.
    var onChange: ((VolumeReading) -> Void)?

    private(set) var reading: VolumeReading?
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var isRunning = false

    private var defaultDeviceBlock: AudioObjectPropertyListenerBlock?
    private var deviceBlock: AudioObjectPropertyListenerBlock?

    /// Mutable copies for the `inout` Core Audio parameters, so the shared
    /// constants below stay immutable.
    private struct Addresses {
        var defaultDevice = VolumeMonitor.defaultDeviceAddress
        var volume = VolumeMonitor.volumeAddress
        var mute = VolumeMonitor.muteAddress
    }

    private static let defaultDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    private static let volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)
    private static let muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)

    func start() {
        var addr = Addresses()
        guard !isRunning else { return }
        isRunning = true
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.defaultDeviceChanged() }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr.defaultDevice, .main, block)
        if status == noErr {
            defaultDeviceBlock = block
        } else {
            Self.logger.error("Default output device listener failed: \(status, privacy: .public)")
        }
        attach(to: Self.currentDefaultDevice())
        Self.logger.notice("Volume monitor started")
    }

    func stop() {
        var addr = Addresses()
        guard isRunning else { return }
        isRunning = false
        detachDevice()
        if let block = defaultDeviceBlock {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &addr.defaultDevice, .main, block)
            defaultDeviceBlock = nil
        }
        reading = nil
        Self.logger.notice("Volume monitor stopped")
    }

    // MARK: - Device

    private func defaultDeviceChanged() {
        guard isRunning else { return }
        let next = Self.currentDefaultDevice()
        guard next != device else { return }
        attach(to: next)
    }

    private func attach(to newDevice: AudioObjectID) {
        var addr = Addresses()
        detachDevice()
        device = newDevice
        guard newDevice != kAudioObjectUnknown else {
            Self.logger.notice("No default output device")
            return
        }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.deviceValueChanged() }
        }
        var registered = false
        if AudioObjectAddPropertyListenerBlock(newDevice, &addr.volume, .main, block) == noErr {
            registered = true
        }
        if AudioObjectHasProperty(newDevice, &addr.mute),
           AudioObjectAddPropertyListenerBlock(newDevice, &addr.mute, .main, block) == noErr {
            registered = true
        }
        deviceBlock = registered ? block : nil
        // The baseline, read silently: attaching is not a change.
        reading = Self.read(newDevice)
        if let reading {
            Self.logger.notice("Output device \(newDevice, privacy: .public) volume \(reading.level, privacy: .public), muted \(reading.isMuted, privacy: .public)")
        } else {
            Self.logger.notice("Output device \(newDevice, privacy: .public) has no volume control")
        }
    }

    private func detachDevice() {
        var addr = Addresses()
        guard device != kAudioObjectUnknown, let block = deviceBlock else {
            deviceBlock = nil
            return
        }
        AudioObjectRemovePropertyListenerBlock(device, &addr.volume, .main, block)
        AudioObjectRemovePropertyListenerBlock(device, &addr.mute, .main, block)
        deviceBlock = nil
        device = AudioObjectID(kAudioObjectUnknown)
    }

    private func deviceValueChanged() {
        guard isRunning, let current = Self.read(device) else { return }
        let previous = reading
        reading = current
        guard VolumeReading.isAnnounceable(from: previous, to: current) else { return }
        Self.logger.notice("Volume -> \(current.level, privacy: .public), muted \(current.isMuted, privacy: .public)")
        onChange?(current)
    }

    // MARK: - Writes

    /// Whether the current device's volume can be set. False for most HDMI
    /// sinks; the caller then leaves the key to the system, which shows its
    /// own "not adjustable" notice.
    var canSetLevel: Bool {
        var addr = Addresses()
        guard device != kAudioObjectUnknown, AudioObjectHasProperty(device, &addr.volume) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &addr.volume, &settable) == noErr && settable.boolValue
    }

    var hasMute: Bool {
        var addr = Addresses()
        return device != kAudioObjectUnknown && AudioObjectHasProperty(device, &addr.mute)
    }

    /// Sets the level; the property listener then reports the change.
    @discardableResult
    func setLevel(_ level: Double) -> Bool {
        var addr = Addresses()
        var value = Float32(min(max(level, 0), 1))
        let status = AudioObjectSetPropertyData(
            device, &addr.volume, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
        if status != noErr {
            Self.logger.error("Setting volume failed: \(status, privacy: .public)")
        }
        return status == noErr
    }

    @discardableResult
    func setMuted(_ muted: Bool) -> Bool {
        var addr = Addresses()
        guard device != kAudioObjectUnknown, AudioObjectHasProperty(device, &addr.mute) else { return false }
        var value = UInt32(muted ? 1 : 0)
        let status = AudioObjectSetPropertyData(
            device, &addr.mute, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        if status != noErr {
            Self.logger.error("Setting mute failed: \(status, privacy: .public)")
        }
        return status == noErr
    }

    // MARK: - Reads

    private static func currentDefaultDevice() -> AudioObjectID {
        var addr = Addresses()
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr.defaultDevice, 0, nil, &size, &id)
        guard status == noErr else {
            logger.error("Reading default output device failed: \(status, privacy: .public)")
            return AudioObjectID(kAudioObjectUnknown)
        }
        return id
    }

    /// Nil when the device has no readable volume.
    private static func read(_ device: AudioObjectID) -> VolumeReading? {
        var addr = Addresses()
        guard device != kAudioObjectUnknown,
              AudioObjectHasProperty(device, &addr.volume) else { return nil }
        var volume = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &addr.volume, 0, nil, &size, &volume) == noErr
        else { return nil }

        var muted = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectHasProperty(device, &addr.mute),
           AudioObjectGetPropertyData(device, &addr.mute, 0, nil, &size, &muted) != noErr {
            muted = 0
        }
        return VolumeReading(level: Double(volume), isMuted: muted != 0)
    }
}
