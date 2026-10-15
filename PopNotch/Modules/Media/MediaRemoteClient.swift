import Foundation
import os

/// Transport commands. Raw values are the MRCommand enum from MediaRemote.
enum MediaCommand: Int {
    case play = 0
    case pause = 1
    case togglePlayPause = 2
    case nextTrack = 4
    case previousTrack = 5
}

/// Bridge to the private MediaRemote framework.
///
/// MediaRemote is the system-wide "now playing" service — the same source the
/// Control Center media tile reads. One client covers every app that reports
/// to it (Spotify, Apple Music, browsers playing video), so PopNotch needs no
/// per-app adapters.
///
/// It is a **private** framework, loaded by `dlopen`/`dlsym` rather than
/// linked. Every symbol lookup is guarded; if any fails — a future macOS
/// removing or further restricting the API — `isAvailable` is false and the
/// media module hides itself rather than crashing. Verified reachable from
/// within the signed, hardened-runtime app bundle on macOS 26.5, not only
/// from a command-line tool. See REFERENCES.md.
@MainActor
final class MediaRemoteClient {

    private static let logger = Logger(subsystem: "com.techie.PopNotch", category: "MediaRemote")

    // C function signatures, as reverse-engineered by the community and
    // confirmed by the Phase 4 probe.
    private typealias GetInfoFn = @convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void
    private typealias GetIsPlayingFn = @convention(c) (DispatchQueue, @escaping (Bool) -> Void) -> Void
    private typealias RegisterFn = @convention(c) (DispatchQueue) -> Void
    private typealias UnregisterFn = @convention(c) () -> Void
    private typealias SendCommandFn = @convention(c) (Int, CFDictionary?) -> Bool

    private let getInfo: GetInfoFn
    private let getIsPlaying: GetIsPlayingFn
    private let register: RegisterFn
    private let unregister: UnregisterFn
    private let sendCommandFn: SendCommandFn
    private let infoDidChangeName: Notification.Name
    private let isPlayingDidChangeName: Notification.Name

    /// False when the framework or any required symbol could not be resolved.
    /// The module checks this and hides itself when unavailable.
    let isAvailable: Bool

    /// Called on the main actor whenever the system reports a change. The
    /// module reacts by re-fetching; MediaRemote does not push the payload.
    var onChange: (() -> Void)?

    private var isListening = false
    private var observers: [NSObjectProtocol] = []

    init?() {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW
        ) else {
            Self.logger.error("dlopen(MediaRemote) failed; media unavailable")
            return nil
        }

        func fn<T>(_ name: String, as type: T.Type) -> T? {
            guard let sym = dlsym(handle, name) else {
                Self.logger.error("dlsym \(name, privacy: .public) failed")
                return nil
            }
            return unsafeBitCast(sym, to: T.self)
        }
        func constName(_ name: String) -> Notification.Name? {
            guard let addr = dlsym(handle, name) else { return nil }
            let string = addr.load(as: Unmanaged<CFString>.self).takeUnretainedValue() as String
            return Notification.Name(string)
        }

        guard let getInfo = fn("MRMediaRemoteGetNowPlayingInfo", as: GetInfoFn.self),
              let getIsPlaying = fn("MRMediaRemoteGetNowPlayingApplicationIsPlaying", as: GetIsPlayingFn.self),
              let register = fn("MRMediaRemoteRegisterForNowPlayingNotifications", as: RegisterFn.self),
              let unregister = fn("MRMediaRemoteUnregisterForNowPlayingNotifications", as: UnregisterFn.self),
              let sendCommand = fn("MRMediaRemoteSendCommand", as: SendCommandFn.self),
              let infoName = constName("kMRMediaRemoteNowPlayingInfoDidChangeNotification"),
              let playingName = constName("kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification")
        else {
            return nil
        }

        self.getInfo = getInfo
        self.getIsPlaying = getIsPlaying
        self.register = register
        self.unregister = unregister
        self.sendCommandFn = sendCommand
        self.infoDidChangeName = infoName
        self.isPlayingDidChangeName = playingName
        self.isAvailable = true
    }

    // MARK: - Reading

    /// Fetches metadata and play state, merges them, and returns a snapshot.
    /// Both MediaRemote calls are asynchronous, so this nests them and hops to
    /// the main actor before calling back.
    func fetchNowPlaying(_ completion: @escaping (NowPlaying) -> Void) {
        getInfo(DispatchQueue.global()) { [weak self] info in
            guard let self else { return }
            var snapshot = Self.decode(info)
            self.getIsPlaying(DispatchQueue.global()) { playing in
                snapshot.isPlaying = playing
                Task { @MainActor in completion(snapshot) }
            }
        }
    }

    private static func decode(_ info: [String: Any]) -> NowPlaying {
        func string(_ key: String) -> String? { info["kMRMediaRemoteNowPlayingInfo\(key)"] as? String }
        func number(_ key: String) -> Double? { (info["kMRMediaRemoteNowPlayingInfo\(key)"] as? NSNumber)?.doubleValue }

        return NowPlaying(
            title: string("Title"),
            artist: string("Artist"),
            album: string("Album"),
            artworkData: info["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data,
            artworkIdentifier: string("ArtworkIdentifier"),
            duration: number("Duration"),
            elapsed: number("ElapsedTime")
        )
    }

    // MARK: - Notifications

    /// Registers with MediaRemote and observes its change notifications.
    /// Idempotent. Hard rule 9: the module calls this only while visible.
    func startListening() {
        guard isAvailable, !isListening else { return }
        register(DispatchQueue.main)

        let center = NotificationCenter.default
        for name in [infoDidChangeName, isPlayingDidChangeName] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onChange?() }
            })
        }
        isListening = true
        Self.logger.notice("Listening for now-playing changes")
    }

    func stopListening() {
        guard isListening else { return }
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        unregister()
        isListening = false
        Self.logger.notice("Stopped listening")
    }

    // MARK: - Commands

    /// Sends a transport command. Returns whether MediaRemote accepted it;
    /// a false return (or no audible effect) means the current player does
    /// not honour that command.
    @discardableResult
    func send(_ command: MediaCommand) -> Bool {
        guard isAvailable else { return false }
        let accepted = sendCommandFn(command.rawValue, nil)
        Self.logger.notice("Command \(command.rawValue, privacy: .public) -> \(accepted, privacy: .public)")
        return accepted
    }
}
