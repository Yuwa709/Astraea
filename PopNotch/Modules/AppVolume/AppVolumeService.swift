import AppKit
import CoreAudio
import Foundation
import Observation
import os

/// One row on the mixer page. Distinct from `AudioAppRow`, which is the
/// playing-now grouping the logs are built from: a mixer row also covers an
/// app that played earlier this session and is still running, and carries
/// the states the page draws — playing or not, and greyed-with-reason for
/// the never-tap set.
struct MixerRow: Equatable {
    var owner: AudioOwner
    /// The live pids currently attributed to this owner; empty once its
    /// audio processes have gone away (a session row kept by the app-running
    /// check).
    var pids: [pid_t]
    var isPlaying: Bool
    /// Non-nil for apps in `NeverTapSet`: the short reason the row shows.
    var neverTapReason: String?
    /// UIDs of the output devices the owner's processes use right now.
    /// Part of equality on purpose: a device move republishes the rows,
    /// which is what pushes fresh desires to the tap engine.
    var deviceUIDs: [String] = []
    /// The tap engine's view of this row (Phase 5).
    var engineState: TapRowState = .notTapped
}

/// What a row's output choice amounts to right now (V2 routing), for its
/// caption and its menu.
enum OutputRoute: Equatable {
    /// No choice saved: the app plays wherever it plays.
    case systemDefault
    /// The chosen device is connected.
    case device(uid: String, name: String)
    /// The chosen device is not connected. The app is on its own output
    /// meanwhile and is routed back when the device returns. `name` is nil
    /// when the device has not been seen since launch: only its UID is
    /// saved.
    case disconnected(uid: String, name: String?)
}

/// Per-app volume's engine service, owned by AppDelegate rather than being a
/// NotchModule (docs/FUTURE-audio-mixer.md, *v1 plan*, decision 4).
/// `AppVolumeModule` is only the Settings toggle and the door; it starts and
/// stops the watching here.
///
/// **Phase 4: read-only.** It watches which processes are playing, resolves
/// each to the app that owns it, and publishes the mixer page's rows: apps
/// playing now, plus apps that played this session and are still running
/// (so a volume can be set before the next join sound, not scrambled for
/// during it). No tap, no audio device. The tap engine is Phase 5.
@MainActor
@Observable
final class AppVolumeService {

    /// The log the rows are verified from. Injected so tests can pass a
    /// disabled one: the test host is a copy of PopNotch, writing to the
    /// same subsystem and category, and its fixture rows were once mistaken
    /// for real ones (2026-09-18).
    nonisolated static let defaultLogger = Logger(subsystem: "com.techie.PopNotch", category: "AppVolume")

    /// What is playing now, one row per owning app, sorted by name. The
    /// Phase 3 verification logs are built from this, so its meaning does
    /// not change: playing now, nothing else.
    private(set) var rows: [AudioAppRow] = []
    /// Playing processes that are never listed or tapped: PopNotch itself,
    /// system daemons, system agents. Kept for the logs.
    private(set) var hiddenCount = 0

    /// What the mixer page lists (v1 plan, *Accepted defaults*): apps
    /// playing now, plus apps that played this session and are still
    /// running. Unattributable audio never appears — the resolver hides it
    /// before rows are built.
    private(set) var mixerRows: [MixerRow] = []

    /// Fires after `mixerRows` changes, so the coordinator can re-measure
    /// an open mixer page whose row count just changed. Distinct from
    /// observation: the panel's frame is applied imperatively, not by a
    /// SwiftUI view watching the service.
    @ObservationIgnored var onRowsChange: (() -> Void)?

    /// Spotify's and Music's own volume (decision 3: AppleScript, never a
    /// tap). Rows whose owner it handles get a working slider now, shared
    /// with the player screen's; every other row stays inert until the tap
    /// engine (Phase 5). Set by AppDelegate once the media module exists;
    /// weak because the coordinator's arbiter already owns that module.
    @ObservationIgnored weak var playerVolumes: ScriptedPlayerVolumes?

    /// The tap engine (Phase 5). Set by AppDelegate, which owns it; every
    /// mixer-row change pushes fresh desires through `pushDesires()`.
    @ObservationIgnored var tapEngine: TapEngine?
    /// Where saved positions and the taps toggle live (settings v9). Set by
    /// AppDelegate.
    @ObservationIgnored weak var settingsStore: SettingsStore?
    /// Slider positions mid-drag, applied live to the engine and persisted
    /// only on release (carried from the plan).
    ///
    /// **Observed, deliberately**: this is what the slider's knob reads
    /// while the pointer is down, so an `@ObservationIgnored` here stops
    /// the row re-rendering and the knob freezes until release, when the
    /// settings write finally fires observation. That was the bug on the
    /// first build (2026-09-19). `MediaModule.playerVolumes` is observed
    /// for the same reason, which is why the scripted rows always tracked.
    private var livePositions: [String: Int] = [:]
    /// The engine's row states, merged into `mixerRows` as they arrive.
    @ObservationIgnored private var engineStates: [String: TapRowState] = [:]

    /// The devices a row may route to, as the tap engine last published
    /// them (V2). Observed: the menus list these.
    private(set) var outputDevices: [TapHALDevice] = []
    /// Names of every device seen since launch, by UID, so an unplugged
    /// choice can still be named on its row. Session-only: settings keep
    /// the UID alone.
    @ObservationIgnored private var deviceNames: [String: String] = [:]

    @ObservationIgnored private let logger: Logger
    @ObservationIgnored private let source: AudioProcessSource
    @ObservationIgnored private let resolve: (AudioProcessSnapshot) -> AudioOwnerResult?
    /// Whether an app with this bundle ID is still running — the check that
    /// keeps a session row alive after its audio processes exit (Chrome's
    /// audio helper outlives playback by a minute, then quits while Chrome
    /// stays). Injected so tests never depend on what is really running.
    @ObservationIgnored private let isAppRunning: (String) -> Bool
    /// Resolved once per process object: its owner cannot change while it
    /// lives, and gathering facts costs a signature lookup.
    @ObservationIgnored private var resolved: [AudioObjectID: AudioOwnerResult] = [:]
    /// Owners seen playing since watching started, keyed by owner key.
    /// Pruned when the owner is neither connected to Core Audio nor (for
    /// apps) still running.
    @ObservationIgnored private var sessionOwners: [String: AudioOwner] = [:]
    @ObservationIgnored private var lastLogged: String?

    /// Other audio mixers running right now, by display name, sorted.
    /// Empty almost always; when it is not, both the mixer page and the
    /// visualiser's setting say what it means (Phase 6).
    private(set) var conflictingMixers: [String] = []
    @ObservationIgnored private var conflictObservers: [NSObjectProtocol] = []

    /// `resolve` is injectable so tests never touch real processes. The
    /// default gathers public facts and runs the resolver chain; nil means
    /// the process vanished before it could be inspected.
    init(source: AudioProcessSource? = nil,
         resolve: ((AudioProcessSnapshot) -> AudioOwnerResult?)? = nil,
         isAppRunning: ((String) -> Bool)? = nil,
         logger: Logger = AppVolumeService.defaultLogger) {
        self.source = source ?? CoreAudioProcessSource()
        self.logger = logger
        self.isAppRunning = isAppRunning ?? { bundleID in
            !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
        }
        let selfPID = getpid()
        self.resolve = resolve ?? { snapshot in
            ProcessFactsGatherer.facts(pid: snapshot.pid, bundleID: snapshot.bundleID)
                .map { AudioOwnerResolver.resolve($0, selfPID: selfPID) }
        }
    }

    /// Watches for another mixer launching or quitting.
    ///
    /// Deliberately **not** tied to `startWatching`: the warning it feeds is
    /// about the visualiser as much as about this page, and the visualiser
    /// runs whether or not App Volume is enabled. Push-only — two NSWorkspace
    /// notifications, no timer and no poll, so hard rule 9 is satisfied by
    /// there being nothing to suspend.
    func startConflictWatch() {
        guard conflictObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            conflictObservers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refreshConflictingMixers() }
                })
        }
        refreshConflictingMixers()
    }

    private func refreshConflictingMixers() {
        applyRunningBundleIDs(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    /// Split out so a test can drive it without launching anything.
    func applyRunningBundleIDs(_ bundleIDs: [String]) {
        let names = Set(bundleIDs.compactMap { NeverTapSet.mixerName(forBundleID: $0) }).sorted()
        guard names != conflictingMixers else { return }
        conflictingMixers = names
        logger.notice("Other audio mixers running: \(names.isEmpty ? "none" : names.joined(separator: ", "), privacy: .public)")
    }

    /// What is wrong, not just that something is running. Nil when nothing
    /// conflicting is.
    nonisolated static func mixerConflictWarning(names: [String]) -> String? {
        guard !names.isEmpty else { return nil }
        let subject = names.count == 1
            ? "\(names[0]) is running"
            : "\(names.dropLast().joined(separator: ", ")) and \(names[names.count - 1]) are running"
        return "\(subject). The spectrum may be inaccurate: it re-renders other apps' audio, and the visualiser counts that copy as well as the original."
    }

    /// The second half, for Settings, where there is room for it.
    nonisolated static let mixerConflictDetail =
        "PopNotch excludes its own re-render from the spectrum; it cannot exclude another app's. App Volume never adjusts these apps."

    func startWatching() {
        source.onChange = { [weak self] processes in self?.update(processes) }
        source.start()
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        for observer in conflictObservers { center.removeObserver(observer) }
    }

    func stopWatching() {
        source.stop()
        source.onChange = nil
        resolved = [:]
        sessionOwners = [:]
        rows = []
        hiddenCount = 0
        publishMixerRows([])
    }

    /// Re-evaluates the session rows from the current process list, without
    /// waiting for the next audio event. Called when the mixer page opens:
    /// an app that quit since the last event would otherwise still show,
    /// because its quitting only fires a Core Audio notification if it still
    /// held audio process objects.
    func refreshRows() {
        update(source.processes)
    }

    /// The mixer page just opened: re-prune the rows, then read the current
    /// volume of each listed scripted player, since Spotify and Music post
    /// nothing when their own slider or a phone changes it. One Apple Event
    /// per such row (~17ms each, at most two), click-driven, never on a
    /// cadence.
    func pageDidOpen() {
        refreshRows()
        guard let playerVolumes else { return }
        for row in mixerRows where playerVolumes.handlesVolume(for: row.owner.key) {
            playerVolumes.refreshVolume(for: row.owner.key)
        }
    }

    private func update(_ processes: [AudioProcessSnapshot]) {
        let live = Set(processes.map(\.objectID))
        resolved = resolved.filter { live.contains($0.key) }

        var results: [(pid: pid_t, result: AudioOwnerResult)] = []
        for process in processes where process.isRunningOutput {
            if let known = resolved[process.objectID] {
                results.append((process.pid, known))
            } else if let result = resolve(process) {
                resolved[process.objectID] = result
                results.append((process.pid, result))
            }
        }
        let built = AudioRowBuilder.rows(from: results)
        rows = built.rows
        hiddenCount = built.hidden.count
        log(built.rows, hidden: built.hidden)
        publishMixerRows(buildMixerRows(processes: processes, playing: built.rows))
    }

    /// The session bookkeeping behind the mixer page. `resolved` only ever
    /// holds objects that have played (resolution happens on first output),
    /// so "connected" below means "has played and its process object is
    /// still registered with Core Audio" — which covers paused apps, whose
    /// objects persist.
    private func buildMixerRows(processes: [AudioProcessSnapshot],
                                playing: [AudioAppRow]) -> [MixerRow] {
        var liveByKey: [String: (owner: AudioOwner, pids: [pid_t], deviceUIDs: Set<String>)] = [:]
        for process in processes {
            guard case .shown(let owner)? = resolved[process.objectID] else { continue }
            liveByKey[owner.key, default: (owner, [], [])].pids.append(process.pid)
            liveByKey[owner.key]?.deviceUIDs.formUnion(process.outputDeviceUIDs)
        }
        for row in playing {
            sessionOwners[row.owner.key] = row.owner
        }
        // Kept while connected, or — for apps — while the app itself still
        // runs. Web content and unbundled tools have no app to check, so
        // their rows go when their processes do.
        sessionOwners = sessionOwners.filter { key, owner in
            liveByKey[key] != nil || (owner.kind == .app && isAppRunning(key))
        }
        let playingKeys = Set(playing.map(\.owner.key))
        return sessionOwners.values
            .map { owner in
                MixerRow(owner: owner,
                         pids: (liveByKey[owner.key]?.pids ?? []).sorted(),
                         isPlaying: playingKeys.contains(owner.key),
                         neverTapReason: NeverTapSet.reason(for: owner.key),
                         deviceUIDs: (liveByKey[owner.key]?.deviceUIDs ?? []).sorted(),
                         engineState: engineStates[owner.key] ?? .notTapped)
            }
            .sorted { ($0.owner.name.localizedLowercase, $0.owner.key)
                    < ($1.owner.name.localizedLowercase, $1.owner.key) }
    }

    private func publishMixerRows(_ newRows: [MixerRow]) {
        guard newRows != mixerRows else { return }
        mixerRows = newRows
        onRowsChange?()
        pushDesires()
    }

    // MARK: - Tap engine glue (Phase 5)

    /// Whether taps are on (settings v9). nil-safe: absent means off.
    var tapsEnabled: Bool {
        settingsStore?.settings.appVolume.tapsEnabled ?? false
    }

    /// The row's position, 0...200: mid-drag value, else saved, else the
    /// app's own volume (100, which the slider shows as 50).
    func tapPosition(for key: String) -> Int {
        if let live = livePositions[key] { return live }
        return settingsStore?.settings.appVolume.volumes?[key] ?? TapReconciler.unityPosition
    }

    /// The Settings toggle. Turning on runs the engine's permission probe
    /// (decision 3: the prompt belongs to this moment, never to launch).
    func setTapsEnabled(_ on: Bool) {
        settingsStore?.update { $0.appVolume.tapsEnabled = on }
        tapEngine?.setTapsEnabled(on, probing: true)
        pushDesires()
    }

    /// Launch restore: apply the stored toggle without a probe, so launch
    /// can never prompt (the TCC-reset residual excepted; recorded).
    func restoreTapsEnabledFromSettings() {
        guard tapsEnabled else { return }
        tapEngine?.setTapsEnabled(true, probing: false)
        pushDesires()
    }

    func setTapPosition(_ position: Int, for key: String) {
        livePositions[key] = TapReconciler.clampPosition(position)
        pushDesires()
    }

    /// Release persists the position — the app's own volume is stored as
    /// absence — and the live overlay ends.
    func endTapVolumeEdit(for key: String) {
        let position = livePositions.removeValue(forKey: key)
        guard let position else { return }
        settingsStore?.update {
            var volumes = $0.appVolume.volumes ?? [:]
            volumes[key] = position == TapReconciler.unityPosition ? nil : position
            $0.appVolume.volumes = volumes.isEmpty ? nil : volumes
        }
        logger.notice("Volume for \(key, privacy: .public) -> \(TapReconciler.sliderValue(atPosition: position), privacy: .public) (gain \(TapReconciler.gain(atPosition: position), privacy: .public))")
        pushDesires()
    }

    // MARK: - Output routing (V2)

    /// The row's saved output, by device UID. nil is System default.
    func output(for key: String) -> String? {
        settingsStore?.settings.appVolume.outputs?[key]
    }

    /// Saves the choice — System default as absence — and hands the engine
    /// fresh desires. A choice is kept while its device is unplugged; only
    /// the user changes it.
    func setOutput(_ uid: String?, for key: String) {
        guard output(for: key) != uid else { return }
        settingsStore?.update {
            var outputs = $0.appVolume.outputs ?? [:]
            outputs[key] = uid
            $0.appVolume.outputs = outputs.isEmpty ? nil : outputs
        }
        logger.notice("Output for \(key, privacy: .public) -> \(uid ?? "System default", privacy: .public)")
        pushDesires()
    }

    // MARK: - Bass boost (V2 Phase 3)

    /// The row's saved boost level: 0 (off), or 1...3 for +6, +12, +18 dB.
    func bass(for key: String) -> Int {
        settingsStore?.settings.appVolume.bass?[key] ?? 0
    }

    /// Saves the level — off as absence — and hands the engine fresh
    /// desires. One click is one write: there is no drag to thin.
    func setBass(_ level: Int, for key: String) {
        let level = BassBoost.levels.contains(level) ? level : 0
        guard bass(for: key) != level else { return }
        settingsStore?.update {
            var levels = $0.appVolume.bass ?? [:]
            levels[key] = level == 0 ? nil : level
            $0.appVolume.bass = levels.isEmpty ? nil : levels
        }
        logger.notice("Bass for \(key, privacy: .public) -> \(level == 0 ? "off" : "+\(Int(BassBoost.gainDB(level: level))) dB", privacy: .public)")
        pushDesires()
    }

    func route(for key: String) -> OutputRoute {
        Self.route(chosenUID: output(for: key), devices: outputDevices, knownNames: deviceNames)
    }

    /// Called by AppDelegate with the engine's device-list updates. The
    /// engine re-resolves routes itself; this only feeds the menus.
    func applyOutputDevices(_ devices: [TapHALDevice]) {
        for device in devices { deviceNames[device.uid] = device.name }
        guard devices != outputDevices else { return }
        outputDevices = devices
    }

    nonisolated static func route(chosenUID: String?, devices: [TapHALDevice],
                                  knownNames: [String: String]) -> OutputRoute {
        guard let chosenUID else { return .systemDefault }
        if let device = devices.first(where: { $0.uid == chosenUID }) {
            return .device(uid: chosenUID, name: device.name)
        }
        return .disconnected(uid: chosenUID, name: knownNames[chosenUID])
    }

    /// Why a device cannot be a route target, in the menu's words, or nil
    /// when it can. The same gates `TapReconciler` applies to a target.
    nonisolated static func routeUnavailableReason(_ device: TapHALDevice) -> String? {
        if device.isAirPlay { return "AirPlay" }
        if device.hasInputStreams { return "has a microphone" }
        if !device.isStereoOut { return "not stereo" }
        return nil
    }

    /// The row's one-line caption. `scripted` means Spotify or Music with
    /// the media module handling their volume: their slider always works,
    /// so taps and engine states only matter to them once they are routed
    /// or boosted. A disconnected choice says so rather than showing the
    /// fallback as if it were chosen; the state comes first so truncation
    /// keeps it.
    nonisolated static func caption(for row: MixerRow, scripted: Bool, tapsEnabled: Bool,
                                    route: OutputRoute, boosted: Bool = false) -> String {
        if let reason = row.neverTapReason { return "Not adjustable — \(reason)" }
        var engineReason: String?
        if case .inert(let reason) = row.engineState { engineReason = reason }
        if !scripted {
            if let engineReason { return "Not adjustable — \(engineReason)" }
            if !tapsEnabled { return "Taps are off" }
        } else if route != .systemDefault {
            if !tapsEnabled { return "Output needs taps on" }
            if let engineReason { return "Can't route — \(engineReason)" }
        } else if boosted {
            if !tapsEnabled { return "Bass boost needs taps on" }
            if let engineReason { return "Can't boost — \(engineReason)" }
        }
        switch route {
        case .systemDefault:
            return row.isPlaying ? "Playing" : "Not playing"
        case .device(_, let name):
            return row.isPlaying ? "Playing on \(name)" : "Not playing · \(name)"
        case .disconnected(_, let name):
            return name.map { "Disconnected · \($0)" } ?? "Saved output disconnected"
        }
    }

    /// Called by AppDelegate with the engine's state updates.
    func applyEngineStates(_ states: [String: TapRowState]) {
        engineStates = states
        var updated = mixerRows
        for index in updated.indices {
            let key = updated[index].owner.key
            updated[index].engineState = states[key] ?? .notTapped
            // A row going inert can swap its live slider out mid-drag, so
            // the release callback never fires; drop the orphaned overlay
            // rather than letting it shadow the saved position.
            if case .inert = updated[index].engineState {
                livePositions[key] = nil
            }
        }
        guard updated != mixerRows else { return }
        mixerRows = updated
        onRowsChange?()
    }

    /// Spotify and Music are adjusted through their own AppleScript volume,
    /// never a tap's gain (decision 3). This is an identity, not a
    /// capability: disabling the Media module makes `handlesVolume` false,
    /// and that must make their sliders inert, not reroute them to the tap
    /// engine. Routing or boosting them (V2) taps them at unity; see
    /// `desires`.
    nonisolated static let scriptedPlayerKeys: Set<String> = [
        SpotifyAdapter.bundleID, MusicAdapter.bundleID,
    ]

    /// Everything the engine needs to decide what exists: one desire per
    /// row the tap path owns (never the never-tap set — the engine must not
    /// even see those). Pure and static so the filter is a test, not a
    /// hardware session.
    ///
    /// Spotify and Music reach the engine only when routed or boosted,
    /// because AppleScript can do neither. They arrive at position 100
    /// whatever is saved: a tap moves or filters their audio at unity, and
    /// their volume stays the app's own `sound volume` (decision 3, kept for
    /// V2 on 2026-09-27; boost added 2026-09-28).
    nonisolated static func desires(from rows: [MixerRow],
                                    position: (String) -> Int,
                                    output: (String) -> String? = { _ in nil },
                                    bass: (String) -> Int = { _ in 0 }) -> [TapDesire] {
        rows.compactMap { row in
            guard row.neverTapReason == nil else { return nil }
            let key = row.owner.key
            let chosen = output(key)
            let level = bass(key)
            if scriptedPlayerKeys.contains(key) {
                guard chosen != nil || level > 0 else { return nil }
                return TapDesire(key: key, position: 100, isPlaying: row.isPlaying,
                                 pids: row.pids, deviceUIDs: row.deviceUIDs,
                                 outputUID: chosen, bass: level)
            }
            return TapDesire(key: key,
                             position: position(key),
                             isPlaying: row.isPlaying,
                             pids: row.pids,
                             deviceUIDs: row.deviceUIDs,
                             outputUID: chosen,
                             bass: level)
        }
    }

    private func pushDesires() {
        guard let tapEngine else { return }
        tapEngine.apply(desires: Self.desires(
            from: mixerRows,
            position: { self.tapPosition(for: $0) },
            output: { self.output(for: $0) },
            bass: { self.bass(for: $0) }))
    }

    /// At `.notice`, and only when something changed, so the log is a record
    /// of what played and how each process was attributed, not a stream.
    private func log(_ rows: [AudioAppRow], hidden: [(name: String, reason: AudioHiddenReason)]) {
        var lines = rows.map { row in
            "\(row.owner.name) [\(row.owner.key)] \(row.owner.kind.rawValue), via \(row.owner.resolution.rawValue), pids \(row.pids.map(String.init).joined(separator: ","))"
        }
        if !hidden.isEmpty {
            lines.append("hidden: " + hidden.map { "\($0.name) (\($0.reason.rawValue))" }.joined(separator: ", "))
        }
        let summary = lines.joined(separator: "; ")
        guard summary != lastLogged else { return }
        lastLogged = summary
        logger.notice("Audio rows (\(rows.count, privacy: .public)): \(summary.isEmpty ? "none playing" : summary, privacy: .public)")
    }
}
