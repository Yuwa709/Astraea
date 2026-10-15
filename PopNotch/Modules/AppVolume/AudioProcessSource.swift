import CoreAudio
import Foundation
import os

/// One Core Audio process object, as last read.
struct AudioProcessSnapshot: Equatable {
    /// Unique for the life of the process object, unlike a PID, which the
    /// system reuses; the resolver's cache is keyed by it.
    var objectID: AudioObjectID
    var pid: pid_t
    /// `kAudioProcessPropertyBundleID`, the process's own.
    var bundleID: String?
    /// `kAudioProcessPropertyIsRunningOutput`: actually playing. The rows
    /// come from this, never from the list of running apps.
    var isRunningOutput: Bool
    /// UIDs of the output devices this process is using
    /// (`kAudioProcessPropertyDevices`, output scope). The tap engine keys
    /// its aggregates by these; UIDs, not object IDs, because a dock
    /// reconnect renumbers every device's object ID (measured in the spike).
    var outputDeviceUIDs: [String] = []
}

/// The audio-producing processes on the system, and a callback whenever that
/// changes. A protocol so `AppVolumeService` is tested with a stub, never
/// against real Core Audio.
@MainActor
protocol AudioProcessSource: AnyObject {
    var processes: [AudioProcessSnapshot] { get }
    var onChange: (([AudioProcessSnapshot]) -> Void)? { get set }
    func start()
    func stop()
}

/// The Core Audio implementation. Property reads and listeners only: it
/// creates no tap and starts no device.
///
/// Event-driven, no timer (hard rule 9): one listener on the system's
/// process list, and two per process object, after either of which every
/// process's is-running-output flag is re-read.
///
/// Not a listener on that flag: `kAudioProcessPropertyIsRunningOutput`
/// accepts one and never calls it. Its changes are announced as
/// `kAudioProcessPropertyIsRunning` and as `kAudioProcessPropertyDevices` in
/// output scope, and both are watched because neither alone covers every app:
/// Discord's voice renderer sent only the devices change. The flag already
/// reads its new value when either callback runs (all measured 2026-09-18).
@MainActor
final class CoreAudioProcessSource: AudioProcessSource {

    private static let logger = Logger(subsystem: "com.techie.PopNotch", category: "AudioProcesses")

    /// Where a process's playing changes are announced; see the type comment.
    private static let processAddresses: [(name: String, address: AudioObjectPropertyAddress)] = [
        ("is-running", address(kAudioProcessPropertyIsRunning)),
        ("output devices", address(kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput)),
    ]

    private(set) var processes: [AudioProcessSnapshot] = []
    var onChange: (([AudioProcessSnapshot]) -> Void)?

    private var listListener: AudioObjectPropertyListenerBlock?

    /// Removing a listener needs the very block and address it was added
    /// with, so only the addresses whose add succeeded are kept.
    private struct ProcessListener {
        let block: AudioObjectPropertyListenerBlock
        let addresses: [AudioObjectPropertyAddress]
    }
    private var processListeners: [AudioObjectID: ProcessListener] = [:]

    func start() {
        guard listListener == nil else { return }
        var address = Self.address(kAudioHardwarePropertyProcessObjectList)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.processListChanged() }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        guard status == noErr else {
            Self.logger.error("Could not watch the process list (\(status, privacy: .public))")
            return
        }
        listListener = block
        Self.logger.notice("Watching audio processes")
        processListChanged()
    }

    func stop() {
        if let listListener {
            var address = Self.address(kAudioHardwarePropertyProcessObjectList)
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, .main, listListener)
        }
        listListener = nil
        for object in Array(processListeners.keys) { removeProcessListener(object) }
        processes = []
        Self.logger.notice("Stopped watching audio processes")
    }

    /// Both this and `publish` can arrive as callbacks queued on main before
    /// `stop()` removed their listeners; once stopped, they do nothing, or
    /// they would re-add listeners and re-publish rows `stop()` cleared.
    private func processListChanged() {
        guard listListener != nil else { return }
        let objects = Set(Self.processObjects())
        for object in Array(processListeners.keys) where !objects.contains(object) {
            removeProcessListener(object)
        }
        for object in objects where processListeners[object] == nil {
            addProcessListener(object)
        }
        publish()
    }

    private func publish() {
        guard listListener != nil else { return }
        processes = Self.processObjects().map(Self.snapshot)
        onChange?(processes)
    }

    /// A failed add is logged, never silent. One that fails for both
    /// addresses leaves the object unwatched and is tried again on the next
    /// process-list change; usually the process exited in between.
    private func addProcessListener(_ object: AudioObjectID) {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.publish() }
        }
        var added: [AudioObjectPropertyAddress] = []
        for (name, address) in Self.processAddresses {
            var address = address
            let status = AudioObjectAddPropertyListenerBlock(object, &address, .main, block)
            guard status == noErr else {
                Self.logger.error("Could not watch process object \(object, privacy: .public) for \(name, privacy: .public) changes (\(status, privacy: .public))")
                continue
            }
            added.append(address)
        }
        guard !added.isEmpty else { return }
        processListeners[object] = ProcessListener(block: block, addresses: added)
    }

    /// The object may already be gone, in which case the removal fails
    /// harmlessly; the entry is dropped either way.
    private func removeProcessListener(_ object: AudioObjectID) {
        guard let listener = processListeners.removeValue(forKey: object) else { return }
        for address in listener.addresses {
            var address = address
            AudioObjectRemovePropertyListenerBlock(object, &address, .main, listener.block)
        }
    }

    // MARK: - Property reads

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: scope,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func processObjects() -> [AudioObjectID] {
        var address = address(kAudioHardwarePropertyProcessObjectList)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0
        else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr
        else { return [] }
        return Array(objects.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private static func snapshot(_ object: AudioObjectID) -> AudioProcessSnapshot {
        let deviceIDs = objectArray(object, kAudioProcessPropertyDevices,
                                    scope: kAudioObjectPropertyScopeOutput)
        return AudioProcessSnapshot(objectID: object,
                                    pid: scalar(object, kAudioProcessPropertyPID, as: pid_t.self) ?? -1,
                                    bundleID: string(object, kAudioProcessPropertyBundleID),
                                    isRunningOutput: (scalar(object, kAudioProcessPropertyIsRunningOutput,
                                                             as: UInt32.self) ?? 0) != 0,
                                    outputDeviceUIDs: deviceIDs.compactMap {
                                        string($0, kAudioDevicePropertyDeviceUID)
                                    }.sorted())
    }

    private static func objectArray(_ object: AudioObjectID,
                                    _ selector: AudioObjectPropertySelector,
                                    scope: AudioObjectPropertyScope) -> [AudioObjectID] {
        var address = address(selector, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0
        else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }

    private static func scalar<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                  as type: T.Type) -> T? {
        var address = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer) == noErr
        else { return nil }
        return pointer.pointee
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        let string = value.takeRetainedValue() as String
        return string.isEmpty ? nil : string
    }
}
