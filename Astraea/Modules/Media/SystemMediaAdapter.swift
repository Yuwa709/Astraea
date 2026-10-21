import Foundation
import os

/// Reads the system-wide now-playing session — whatever app currently owns it.
///
/// Unlike `SpotifyAdapter` and `MusicAdapter`, which each speak one app's
/// scripting dictionary, this source reports the same session Control Center
/// shows: Spotify, Music, a browser playing video, anything that registers
/// with MediaRemote.
///
/// **Why a subprocess and not `MediaRemoteClient`.** MediaRemote's read API is
/// gated to entitled callers, which is why `MediaRemoteClient` sits unused in
/// this folder (see the note in `MediaSource.swift`). The gate applies to the
/// calling binary, so a separate tool that satisfies it can read the session
/// and hand the result over as plain JSON on stdout.
///
/// Lifecycle mirrors `SpotifyAdapter`: push-first, no timers. The tool is
/// launched once by `startObserving()` and streams a line per change for as
/// long as it runs, so this satisfies hard rule 9 without a suspend path —
/// there is nothing polling to suspend. `stopObserving()` terminates it.
///
/// What this source cannot do: the adapter exposes no queue and no
/// favourite, so `upNext` and `favorite` keep the protocol defaults (nil and
/// `.unsupported`). It is not an oversight and must not be faked by peeking
/// at another player.
@MainActor
final class SystemMediaAdapter: MediaSource {

    private nonisolated static let logger = Logger(subsystem: "com.techie.Astraea", category: "SystemMedia")

    // MARK: - The vendored adapter

    /// Absolute paths to everything one adapter invocation needs.
    ///
    /// Resolved once from `Bundle.main`, never hardcoded. The single
    /// exception is the interpreter, which cannot come from the bundle —
    /// see `perlPath`.
    nonisolated struct AdapterTool: Equatable, Sendable {
        let perlPath: String
        let scriptPath: String
        let frameworkPath: String
        /// Only `adapter_test` reads this. Passed through when present so the
        /// health probe stays available; its absence is not a failure and
        /// must not make the source unavailable.
        let testClientPath: String?
    }

    /// The system Perl interpreter. Not configurable, and deliberately the
    /// one absolute path left in this file.
    ///
    /// `mediaremote-adapter.pl` dlopens `MediaRemoteAdapter.framework` **into
    /// the interpreter process**, not into Astraea. MediaRemote answers it
    /// only because `/usr/bin/perl` is Apple-signed with the identifier
    /// `com.apple.perl`; that identity is the entire mechanism. A Homebrew
    /// perl or an interpreter we shipped ourselves would be refused exactly
    /// the way Astraea itself is (`PROJECT-CONTEXT.md`, "MediaRemote:
    /// resolved, not open"), so substituting one is not a fallback.
    ///
    /// Apple has listed the bundled scripting runtimes as slated for removal
    /// since macOS 12. If a future release drops perl, `resolveTool()`
    /// returns nil and this source goes quietly unavailable; the two
    /// AppleScript adapters are unaffected.
    private nonisolated static let perlPath = "/usr/bin/perl"

    /// What the resolve concluded — the tool, or the reason there isn't one.
    ///
    /// Holding the reason rather than collapsing to nil is the point: the
    /// resolve runs once per process, and `startObserving()` needs to say
    /// *why* it is giving up long after that moment has passed.
    nonisolated enum Resolution: Equatable, Sendable {
        case resolved(AdapterTool)
        case unavailable(Capability)
    }

    /// Resolved once, on first use — permanently, for the life of the
    /// process, because neither the bundle nor `/usr/bin/perl` changes
    /// underneath a running app.
    ///
    /// Caching matters: `startObserving()` runs at every enable, wake and
    /// stream restart, and an uncached check would stat the filesystem each
    /// time.
    private nonisolated static let resolution: Resolution = resolveTool()

    /// The resolved tool, or nil. Unchanged in meaning for the call sites
    /// that only need to know whether they can spawn anything.
    private nonisolated static var tool: AdapterTool? {
        if case .resolved(let tool) = resolution { return tool }
        return nil
    }

    /// Maps filesystem facts to a resolution. Pure and silent, so the mapping
    /// is a test rather than a bundle layout — the same split as
    /// `arguments(verb:tool:)` and `SystemMediaParsing`.
    ///
    /// `perlExists` and `perlExecutable` are separate because the old single
    /// `isExecutableFile` check could not distinguish a macOS that dropped
    /// the bundled runtime from one where the file is there but the bit is
    /// off, and the fix for those is not the same.
    nonisolated static func resolve(
        perlPath: String,
        perlExists: Bool,
        perlExecutable: Bool,
        scriptPath: String?,
        frameworkPath: String?,
        testClientPath: String?
    ) -> Resolution {
        guard perlExists else {
            return .unavailable(.perlUnavailable("\(perlPath) does not exist"))
        }
        guard perlExecutable else {
            return .unavailable(.perlUnavailable("\(perlPath) exists but is not executable"))
        }
        guard let scriptPath else {
            return .unavailable(.bundleComponentMissing("mediaremote-adapter.pl"))
        }
        guard let frameworkPath else {
            return .unavailable(.bundleComponentMissing("MediaRemoteAdapter.framework"))
        }
        return .resolved(AdapterTool(
            perlPath: perlPath,
            scriptPath: scriptPath,
            frameworkPath: frameworkPath,
            // Optional by design: only the `test` verb uses it, and this
            // source does not call `test`. Missing it costs the health probe,
            // not the stream, so it must not gate availability.
            testClientPath: testClientPath
        ))
    }

    /// Gathers the real filesystem facts and hands them to `resolve`.
    ///
    /// Being a lazily-initialised `static let`'s initialiser, this body runs
    /// at most once per process.
    private nonisolated static func resolveTool() -> Resolution {
        // Unit tests run against the real app as their host, so registering
        // this source would have every `xcodebuild test` spawn a live adapter
        // — and xctest kills the host rather than quitting it, so each run
        // orphaned seven `perl ... stream` processes onto launchd. Measured
        // 2026-09-02, before this guard existed.
        //
        // The guard lives here rather than in `AppDelegate` because this is
        // the only thing in the app that forks a child: a test must never
        // depend on a subprocess it did not ask for, and the argument vector
        // is covered by `arguments(verb:tool:)` without launching anything.
        //
        // `.unknown`, not a failure case: nothing is broken, the source was
        // deliberately not started. Calling it a missing component would put
        // a lie in the capability the tests then read back.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            logger.notice("Running under XCTest; system now-playing not started")
            return .unavailable(.unknown)
        }
        let script = Bundle.main.url(forResource: "mediaremote-adapter", withExtension: "pl")
        let framework = Bundle.main.privateFrameworksURL?
            .appendingPathComponent("MediaRemoteAdapter.framework")
        let frameworkExists = framework.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        let testClient = Bundle.main.url(forAuxiliaryExecutable: "MediaRemoteAdapterTestClient")
        if testClient == nil {
            logger.notice("MediaRemoteAdapterTestClient missing from the bundle; health probe unavailable")
        }
        // Not logged here. The capability transition in `startObserving()` is
        // the one line about this, emitted at the moment it matters and
        // guarded against repeating on every restart attempt.
        return resolve(
            perlPath: perlPath,
            perlExists: FileManager.default.fileExists(atPath: perlPath),
            perlExecutable: FileManager.default.isExecutableFile(atPath: perlPath),
            scriptPath: script?.path,
            frameworkPath: frameworkExists ? framework?.path : nil,
            testClientPath: testClient?.path
        )
    }

    /// Builds the argument vector for one invocation.
    ///
    /// Order is fixed by `mediaremote-adapter.pl`: framework path first, an
    /// optional test-client path second, then the verb. The script decides
    /// whether the second argument is a path by testing it for a `/`, which
    /// is why the test client is either an absolute path or omitted entirely
    /// — never an empty string.
    ///
    /// Internal rather than private so the vector can be asserted in tests,
    /// the way `ingest` and `LineAssembler` are.
    nonisolated static func arguments(verb: [String], tool: AdapterTool) -> [String] {
        var arguments = [tool.scriptPath, tool.frameworkPath]
        if let testClientPath = tool.testClientPath { arguments.append(testClientPath) }
        arguments.append(contentsOf: verb)
        return arguments
    }

    /// Whether this source is wired up at all.
    ///
    /// **True since the adapter was vendored.** The helper now ships inside
    /// the bundle — framework in `Contents/Frameworks`, script in
    /// `Contents/Resources`, all resolved through `Bundle.main` — so the
    /// source no longer depends on a Homebrew install that most users do not
    /// have.
    ///
    /// This is the single switch, not a comment: `AppDelegate` consults it
    /// when building the sources array, and the Settings tab consults it
    /// when deciding whether to offer "Prefer music over video" — a
    /// preference that means nothing while no source reads it. It restores
    /// the source and its setting together, which is why it exists rather
    /// than the two places each carrying their own guard and drifting apart.
    ///
    /// Registered is not the same as functional: a bundle missing the helper,
    /// or a macOS with no `/usr/bin/perl`, leaves `tool` nil and the source
    /// silently inert. That is a runtime capability question, deliberately
    /// separate from this compile-time wiring one.
    static let isRegistered = true

    let sourceID = "system"
    var onUpdate: ((NowPlaying?) -> Void)?

    /// Always false. This source sends no Apple Events, so the Automation
    /// permission that gates the other two adapters does not apply. A missing
    /// or unlaunchable tool is a *capability* problem, not a permission one,
    /// and must not raise the in-notch "allow Automation" banner.
    ///
    /// `capability` is the separate axis that records the capability problem.
    /// The two never interact: a dead adapter is still not a denied one.
    private(set) var permissionDenied = false

    // MARK: - Capability

    /// Why this source is or is not working.
    ///
    /// Every failure below used to be a single log line and nothing else —
    /// the reason was known at the moment it happened and discarded in the
    /// same function. This retains it, the way `SpotifyAdapter` retains
    /// `permissionDenied`, so the answer to "why is there no track" survives
    /// past the instant it was available.
    ///
    /// Deliberately carries no UI meaning. Nothing renders from it yet.
    nonisolated enum Capability: Equatable, Sendable {
        /// Not resolved yet. Also what a deliberate `stopObserving()` leaves
        /// behind: the stream is not broken, it is simply not running.
        case unknown
        /// A payload parsed. The stream is alive and the tool works.
        case ok
        /// `/usr/bin/perl` is missing, or present but not executable. The
        /// string says which — the two are different problems and the old
        /// `isExecutableFile` check could not tell them apart.
        case perlUnavailable(String)
        /// Something the app ships is not in the bundle. The string names it.
        case bundleComponentMissing(String)
        /// `Process.run()` threw. The string is `localizedDescription`.
        case launchFailed(String)
        /// The stream exited. `crashed` distinguishes a signal from an
        /// ordinary non-zero exit — `terminationReason`, which was available
        /// on the Process all along and never read.
        case exited(status: Int32, crashed: Bool, stderr: String?)

        /// One line for the log. Truncated: stderr is retained at 2KB, which
        /// is far more than a log line should carry.
        var logDescription: String {
            switch self {
            case .unknown: return "unknown"
            case .ok: return "ok"
            case .perlUnavailable(let why): return "perl unavailable - \(why)"
            case .bundleComponentMissing(let what): return "bundle component missing - \(what)"
            case .launchFailed(let why): return "launch failed - \(why)"
            case .exited(let status, let crashed, let stderr):
                let how = crashed ? "crashed (signal \(status))" : "exited \(status)"
                guard let stderr, !stderr.isEmpty else { return "\(how), no stderr" }
                let head = stderr.prefix(Self.stderrLogLimit)
                let suffix = stderr.count > Self.stderrLogLimit
                    ? "... (+\(stderr.count - Self.stderrLogLimit) more)" : ""
                return "\(how), stderr: \(head)\(suffix)"
            }
        }

        /// Enough for a perl error and its file/line, short enough that a
        /// looping tool cannot swamp the log.
        static let stderrLogLimit = 200

        /// Whether this state is something going wrong, so the transition
        /// log can carry the right level. Both `.notice` and `.error`
        /// persist to disk; only `.error` is filterable as a fault.
        var isFailure: Bool {
            switch self {
            case .unknown, .ok: return false
            case .perlUnavailable, .bundleComponentMissing, .launchFailed, .exited: return true
            }
        }
    }

    /// Why this source is or is not working. Instance state, not static: the
    /// resolve is cached per process but the stream can die at any time.
    private(set) var capability: Capability = .unknown

    /// Records a capability, logging only when it actually changes.
    ///
    /// The change guard is what keeps this quiet: `refresh()`, wake and the
    /// restart backoff all re-enter `startObserving()`, so an unguarded log
    /// would repeat the same line on each. `.notice`
    /// rather than `.info` because this is exactly the forensic evidence
    /// CLAUDE.md keeps out of the memory-only levels.
    private func setCapability(_ new: Capability) {
        guard capability != new else { return }
        capability = new
        if new.isFailure {
            Self.logger.error("Capability: \(new.logDescription, privacy: .public)")
        } else {
            Self.logger.notice("Capability: \(new.logDescription, privacy: .public)")
        }
    }

    /// Gates `logCommandFailureOnce`. Not reset by `stopObserving`: it is
    /// about this process's log, not about one stream's lifetime.
    private var commandFailureLogged = false

    private var process: Process?
    /// When the current stream was launched, so an exit can tell a tool
    /// that died on launch from one that ran for hours.
    private var streamStartedAt: TimeInterval?
    /// Bounds automatic restarts after the stream dies; see `scheduleRestart`.
    private var restartBackoff = StreamRestartBackoff()
    /// The one pending restart, if any. One-shot, never a poll.
    private var restartTask: Task<Void, Never>?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    /// Retained so the termination handler can read what the child said on
    /// its way out, and so teardown can drop the handler with the pipe.
    private var stderrCollector: StderrCollector?

    /// The merged payload, retained across lines. A `diff` line carries only
    /// the fields that changed, so this is merged into rather than replaced —
    /// replacing it is what would drop artist and artwork on a position-only
    /// update.
    private var state = SystemMediaPayload()

    /// When `elapsed` was last actually measured. Kept separately because
    /// `NowPlaying.capturedAt` defaults to construction time, and this snapshot
    /// is rebuilt on every line: stamping "now" onto an unchanged `elapsed`
    /// would drag the projected playhead backwards on each metadata-only diff.
    private var elapsedAnchor = Date()

    /// Decoded artwork, keyed by the base64 it came from, so a position update
    /// does not re-decode 40-odd KB. Carrying the same `String` instance
    /// forward through a merge makes the common comparison a pointer check.
    private var artworkCache: (encoded: String, data: Data)?

    /// Bundle ids that already have a dedicated adapter. Reading their
    /// sessions here would put the same track on two sources and leave
    /// `MediaModule` arbitrating between an adapter that can seek, favourite
    /// and read a queue and one that cannot. Referenced, never re-spelled:
    /// a literal here would silently stop matching if either constant moved.
    private static let dedicatedBundleIDs: Set<String> = [
        SpotifyAdapter.bundleID, MusicAdapter.bundleID
    ]

    /// The last artwork decoded, and the track it belonged to.
    ///
    /// A full (non-diff) line for a track in progress can arrive with no
    /// artwork at all, with the diff carrying it landing ~13ms later —
    /// measured on hardware 2026-09-01. Rendered as it arrives that is album
    /// art blinking off and back on at every track change, so the previous
    /// image stands in while the identifier is unchanged.
    private var retainedArtwork: (identifier: String, data: Data)?

    /// Pending "nothing is playing", held briefly. One app releases the
    /// session before the next claims it — measured at 2ms between
    /// `nothing` and the replacement — and publishing that gap empties the
    /// notch for a frame. A real payload cancels this before it fires.
    private var emptyTask: Task<Void, Never>?
    private static let emptyDebounceMS = 150

    /// Prefer a session that has an album over one that does not. Mirrors
    /// `AppSettings.preferMusicOverVideo`; AppDelegate pushes it in, the same
    /// way the visualiser's enabled flag is applied.
    var prefersMusicOverVideo = true

    /// The last music-tier snapshot and the app it came from, kept so a video
    /// from that same app can be ignored rather than replacing it.
    ///
    /// Released on an empty payload or a change of app — never held open
    /// ended, or a track that stopped long ago would pin the notch.
    private var retainedMusic: (bundleID: String, snapshot: NowPlaying)?

    private var lastSnapshot: NowPlaying?
    /// So the first successful diff merge leaves a durable `.notice` behind
    /// instead of only memory-only `.debug` chatter.
    private let firstDiffGate = OnceGate()
    /// The missing-tool line is logged once per adapter, not once per call:
    /// `startObserving()` and `refresh()` both reach it.

    /// There is no single player to ask about. True when the stream is up and
    /// some app owns the session; `MediaModule` uses this for handoff, so it
    /// must mean "this source has something", not "a process exists".
    var isPlayerRunning: Bool {
        process?.isRunning == true && state.bundleIdentifier != nil
    }

    // MARK: - Observing

    func startObserving() {
        guard process == nil else { return }
        // Was a bare `return`: the reason had been logged once at resolve
        // time and then existed nowhere. Now the cached reason is adopted,
        // so a source that never starts can say why it never started.
        guard case .resolved(let tool) = Self.resolution else {
            if case .unavailable(let reason) = Self.resolution { setCapability(reason) }
            return
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: tool.perlPath)
        task.arguments = Self.arguments(verb: ["stream"], tool: tool)
        let pipe = Pipe()
        task.standardOutput = pipe

        // Was `FileHandle.nullDevice`, which threw away the tool's own
        // account of its death before anything could read it. A pipe nobody
        // drains fills its buffer and blocks the child, so the handler below
        // always reads; the collector caps what it *keeps* separately.
        let errorPipe = Pipe()
        task.standardError = errorPipe
        let collector = StderrCollector()
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            collector.append(chunk)
        }

        // Line assembly and JSON decoding run on the pipe's own queue; only
        // finished envelopes cross to the main actor. A line carrying artwork
        // is ~45KB, and parsing that on the main thread is exactly the kind of
        // work the performance budget is about.
        let assembler = LineAssembler()
        let malformed = OnceGate()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return } // EOF; terminationHandler follows
            var envelopes: [SystemMediaEnvelope] = []
            for line in assembler.lines(from: chunk) {
                guard let envelope = SystemMediaParsing.decode(line: line) else {
                    // Skipped, never fatal: one unreadable line must not take
                    // the stream down, and a tool that starts emitting garbage
                    // must not fill the log either — hence once per stream.
                    //
                    // `.debug` is deliberate and is the exception to the
                    // house rule, not a violation of it: this is chatter, and
                    // `.debug` is memory-only, so reading it back needs
                    // `log stream --level debug` rather than plain `log show`.
                    if malformed.firstTime() {
                        Self.logger.debug(
                            "Skipping unparseable stdout line (\(line.count) bytes); stream continues"
                        )
                    }
                    continue
                }
                envelopes.append(envelope)
            }
            guard !envelopes.isEmpty else { return }
            Task { @MainActor [weak self] in
                self?.ingest(envelopes)
            }
        }

        // No immediate restart here: a tool that dies on launch would be
        // relaunched forever, which is a poll wearing a disguise. The exit
        // goes to `handleStreamExit`, which restarts on a bounded backoff
        // (`StreamRestartBackoff`) and then gives up until the next wake or
        // enable.
        task.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            // Available on this object all along and never read. Without it
            // a segfaulting adapter and one exiting 1 are the same line.
            let crashed = finished.terminationReason == .uncaughtSignal
            // Best effort: the last stderr bytes may still be in flight on
            // the pipe's queue when this fires. Whatever arrived is far more
            // than the nothing that was kept before.
            let stderr = collector.text
            Task { @MainActor [weak self] in
                self?.handleStreamExit(status: status, crashed: crashed, stderr: stderr)
            }
        }

        do {
            try task.run()
        } catch {
            setCapability(.launchFailed(error.localizedDescription))
            pipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            return
        }

        process = task
        streamStartedAt = ProcessInfo.processInfo.systemUptime
        // A restart that was still waiting is now moot.
        restartTask?.cancel()
        restartTask = nil
        stdoutPipe = pipe
        stderrPipe = errorPipe
        stderrCollector = collector
        Self.logger.notice(
            """
            Observing system now-playing: \(tool.perlPath, privacy: .public)             \(tool.scriptPath, privacy: .public)             framework=\(tool.frameworkPath, privacy: .public)
            """
        )
    }

    func stopObserving() {
        // A deliberate stop owns the lifecycle: no restart may follow it,
        // and the next start (enable) begins with a fresh budget.
        restartTask?.cancel()
        restartTask = nil
        restartBackoff.reset()
        streamStartedAt = nil
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        if let process, process.isRunning {
            // Cleared first: this is an expected exit and must not be logged
            // as the stream dying.
            process.terminationHandler = nil
            process.terminate()
        }
        process = nil
        stdoutPipe = nil
        stderrPipe = nil
        stderrCollector = nil
        // Back to `.unknown`, not a failure: nothing broke, the stream was
        // asked to stop. Leaving `.ok` behind would claim a live stream that
        // is not there.
        setCapability(.unknown)
        emptyTask?.cancel()
        emptyTask = nil
        state = SystemMediaPayload()
        artworkCache = nil
        retainedArtwork = nil
        retainedMusic = nil
        lastSnapshot = nil
        Self.logger.notice("System now-playing stream stopped")
    }

    deinit {
        // The observer the other adapters drop is cheap to leak; a child
        // process is not. terminate() is safe to call from any thread.
        if let process, process.isRunning {
            process.terminationHandler = nil
            process.terminate()
        }
    }

    /// Records what an exit means, independent of whether a stream is up.
    ///
    /// Internal and split out for the same reason `ingest` and
    /// `arguments(verb:tool:)` are: the mapping is the part worth asserting,
    /// and driving it through a real subprocess would make the test depend
    /// on spawning one — which `resolveTool`'s XCTest guard exists to
    /// prevent in the first place.
    func recordStreamExit(status: Int32, crashed: Bool, stderr: String?) {
        setCapability(.exited(status: status, crashed: crashed, stderr: stderr))
    }

    private func handleStreamExit(status: Int32, crashed: Bool, stderr: String?) {
        guard process != nil else { return } // already torn down by stopObserving
        // Replaces the old status-only `.error`. The transition line carries
        // strictly more — the signal/exit distinction and the tool's own
        // stderr — and is the single line about this event.
        recordStreamExit(status: status, crashed: crashed, stderr: stderr)
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        let lived = streamStartedAt.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0
        process = nil
        streamStartedAt = nil
        stdoutPipe = nil
        stderrPipe = nil
        stderrCollector = nil
        publish()
        scheduleRestart(afterLifetime: lived)
    }

    /// Relaunches a stream that died, after a growing delay, a bounded
    /// number of times. Before this nothing restarted it at all: the comment
    /// said `refresh()` runs on hover, and it no longer does, so one perl
    /// crash cost the system source until relaunch.
    private func scheduleRestart(afterLifetime lived: TimeInterval) {
        guard let delay = restartBackoff.nextDelay(afterLifetime: lived) else {
            Self.logger.error(
                "System now-playing stream keeps exiting; no more restarts until the next wake or enable")
            return
        }
        Self.logger.notice(
            "System now-playing stream exited after \(Int(lived), privacy: .public)s; restart \(self.restartBackoff.attempts, privacy: .public) of \(StreamRestartBackoff.delays.count, privacy: .public) in \(Int(delay), privacy: .public)s")
        restartTask?.cancel()
        restartTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.restartTask = nil
            self.startObserving()
        }
    }

    /// The display woke: a stream that died, including one whose restart
    /// budget ran out, gets a fresh budget and one immediate attempt.
    /// `MediaModule` calls this only while media is enabled.
    func recoverStream() {
        restartBackoff.reset()
        guard process == nil else { return }
        restartTask?.cancel()
        restartTask = nil
        startObserving()
    }

    // MARK: - Pull

    /// Restarts a dead stream and re-publishes what is retained.
    ///
    /// Deliberately not a synchronous `get`, which is what the other two
    /// adapters do with their Apple Events: blocking the main actor on a
    /// subprocess launch would stutter the panel. The stream already
    /// delivers current state on connect, so restarting is the pull. Runs
    /// when media is switched on; a stream that dies later is restarted by
    /// `scheduleRestart` and `recoverStream`, not from here.
    func refresh() {
        if process == nil { startObserving() }
        publish()
    }

    // MARK: - Ingest

    /// Internal rather than private so the tier and merge behaviour can be
    /// driven directly in tests, the way `LineAssembler` is: everything above
    /// this point is a subprocess and a pipe.
    func ingest(_ envelopes: [SystemMediaEnvelope]) {
        // Reaching here means a line came off the pipe and decoded, which is
        // the only proof that perl, the script and the framework all work.
        // Guarded by `setCapability`, so this logs once and not per line.
        setCapability(.ok)
        for envelope in envelopes { apply(envelope) }
        publish()
    }

    private func apply(_ envelope: SystemMediaEnvelope) {
        // Only "data" carries session state. A future line type must not be
        // read as an empty payload and clear the current track.
        guard envelope.type == "data" else { return }
        let incoming = envelope.payload ?? SystemMediaPayload()

        // A diff carries only what changed, so it merges over the retained
        // state. A non-diff payload is a complete snapshot and replaces it —
        // including the empty one the stream opens with, which is how "nothing
        // is playing" arrives rather than as a null payload.
        let isDiff = envelope.diff == true

        // Re-anchor only on a fresh position measurement, or when the
        // transport flips without one. A metadata-only diff keeps the old
        // anchor so the projected playhead stays continuous.
        let playingChanged = incoming.playing != nil && incoming.playing != state.playing
        if incoming.elapsedTime != nil || playingChanged || !isDiff {
            elapsedAnchor = Date()
        }

        state = isDiff ? incoming.merged(over: state) : incoming
        if isDiff { logDiff(carried: incoming, merged: state) }
    }

    /// Evidence for the one thing about this source that a finished snapshot
    /// cannot show: that a partial line merged instead of replacing.
    ///
    /// The first is a `.notice` so it survives to disk; the rest are `.debug`,
    /// because a position tick a second is chatter and this adapter is meant
    /// to run for days.
    private func logDiff(carried: SystemMediaPayload, merged: SystemMediaPayload) {
        let fields = carried.presentFieldNames.joined(separator: ",")
        let art = merged.artworkData?.count ?? 0
        let retained = "title=\(merged.title != nil) artist=\(merged.artist != nil) artwork=\(art)ch elapsed=\(merged.elapsedTime ?? -1)"
        if firstDiffGate.firstTime() {
            Self.logger.notice(
                "First diff merged: carried=[\(fields, privacy: .public)] retained \(retained, privacy: .public)"
            )
        } else {
            Self.logger.debug(
                "diff carried=[\(fields, privacy: .public)] retained \(retained, privacy: .public)"
            )
        }
    }

    private func publish() {
        // A session owned by a player with its own adapter is not ours to
        // report. Emitting nil rather than skipping matters: if Spotify takes
        // the session while this source holds the notch, saying nothing would
        // leave the old track frozen on screen.
        guard !isDedicatedSession else {
            scheduleEmpty()
            return
        }
        guard let snapshot = SystemMediaParsing.snapshot(
            from: state, artwork: resolvedArtwork(), capturedAt: elapsedAnchor
        ) else {
            // Nothing at all: whatever music this was holding has genuinely
            // stopped, so stop holding it.
            retainedMusic = nil
            scheduleEmpty()
            return
        }

        if let retained = retainedMusic, Self.releasesHold(retained, against: snapshot) {
            retainedMusic = nil
        }

        switch SystemMediaParsing.tier(of: state) {
        case .music:
            if let bundle = snapshot.sourceBundleID {
                retainedMusic = (bundle, snapshot)
            }
        case .video:
            // What survives `releasesHold` is narrow by design: the same app,
            // the same item, still playing. In practice that is a track whose
            // album momentarily goes missing from a payload — a report that
            // would otherwise reclassify what is playing as video and swap the
            // notch out from under it. A genuinely different item is a
            // different session and was already released above.
            if prefersMusicOverVideo, let retained = retainedMusic,
               retained.bundleID == snapshot.sourceBundleID {
                return
            }
        }

        // A real payload arrived, so any pending gap was only a gap.
        emptyTask?.cancel()
        emptyTask = nil

        // NowPlaying's == ignores capturedAt, so this drops the repeats the
        // stream emits without a user-visible change.
        guard snapshot != lastSnapshot else { return }
        logTransition(to: snapshot, from: lastSnapshot)
        lastSnapshot = snapshot
        onUpdate?(snapshot)
    }

    /// Whether a retained music track has stopped being a reason to decline a
    /// video.
    ///
    /// Any one of these means the retained snapshot is no longer the session,
    /// and holding it would pin a track the user is not listening to.
    nonisolated static func releasesHold(
        _ retained: (bundleID: String, snapshot: NowPlaying), against incoming: NowPlaying
    ) -> Bool {
        // A different app owns the session; the retained track is not coming
        // back to it.
        if retained.bundleID != incoming.sourceBundleID { return true }

        // macOS reports one session at a time, so a different item *is* a
        // different session. Whatever was retained is not what is playing, and
        // a browser switching from a track to a video is exactly this case.
        if retained.snapshot.artworkIdentifier != incoming.artworkIdentifier { return true }

        // Suppression is for an *active* track outranking a video, never a
        // paused one. This is also what keeps the scrub bar and the lyrics
        // honest: both project forward from `elapsed` for as long as
        // `isPlaying` is true, so a held paused track would keep advancing and
        // scrolling against audio that stopped — observed on hardware
        // 2026-09-01, together with transport buttons acting on the video.
        if !retained.snapshot.isPlaying { return true }

        return false
    }

    private var isDedicatedSession: Bool {
        guard let bundle = state.bundleIdentifier else { return false }
        return Self.dedicatedBundleIDs.contains(bundle)
    }

    /// Holds the empty state briefly rather than publishing it on arrival.
    /// Already-empty stays empty with no timer, and a pending wait is never
    /// restarted — the debounce measures from the first empty line, not the
    /// last.
    private func scheduleEmpty() {
        guard lastSnapshot != nil, emptyTask == nil else { return }
        emptyTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.emptyDebounceMS))
            guard !Task.isCancelled, let self else { return }
            self.emptyTask = nil
            guard self.lastSnapshot != nil else { return }
            self.lastSnapshot = nil
            Self.logger.notice("System now playing: nothing")
            self.onUpdate?(nil)
        }
    }

    /// Artwork for the current state, falling back to what this same track
    /// had a moment ago. Requires a real identifier: with none there is no
    /// evidence the art still belongs to what is playing.
    private func resolvedArtwork() -> Data? {
        if let decoded = decodedArtwork(for: state.artworkData) {
            if let id = state.contentItemIdentifier, !id.isEmpty {
                retainedArtwork = (id, decoded)
            }
            return decoded
        }
        guard let id = state.contentItemIdentifier, !id.isEmpty,
              let retained = retainedArtwork, retained.identifier == id
        else { return nil }
        return retained.data
    }

    private func decodedArtwork(for encoded: String?) -> Data? {
        guard let encoded, !encoded.isEmpty else { return nil }
        if let artworkCache, artworkCache.encoded == encoded { return artworkCache.data }
        // ignoreUnknownCharacters: the payload is machine-generated, but a
        // stray wrap would otherwise turn all artwork into nil silently.
        guard let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters),
              !data.isEmpty
        else {
            Self.logger.error("Artwork base64 did not decode (\(encoded.count, privacy: .public) chars)")
            return nil
        }
        artworkCache = (encoded, data)
        return data
    }

    /// Verification lives here, since none of this is visible on screen.
    /// Titles and artists are user content and stay redacted; everything
    /// logged public is either an app identifier or a measurement.
    private func logTransition(to snapshot: NowPlaying, from previous: NowPlaying?) {
        if snapshot.artworkIdentifier != previous?.artworkIdentifier {
            Self.logger.notice(
                """
                System track: source=\(snapshot.sourceBundleID ?? "?", privacy: .public) \
                playing=\(snapshot.isPlaying, privacy: .public) \
                title=\(snapshot.title?.count ?? 0, privacy: .public)ch \
                artist=\(snapshot.artist?.count ?? 0, privacy: .public)ch \
                duration=\(snapshot.duration ?? -1, format: .fixed(precision: 1), privacy: .public)s \
                artwork=\(snapshot.artworkData?.count ?? 0, privacy: .public)B
                """
            )
        } else if snapshot.isPlaying != previous?.isPlaying {
            Self.logger.notice(
                "System transport: playing=\(snapshot.isPlaying, privacy: .public) at \(snapshot.elapsed ?? -1, format: .fixed(precision: 1), privacy: .public)s"
            )
        }
    }

    // MARK: - Commands

    /// The adapter's argument form for a transport command.
    ///
    /// `mediaremote-adapter.pl` accepts eight function names — stream, get,
    /// send, seek, shuffle, repeat, speed, test — and a transport command is
    /// `send` plus a numeric **MRCommand id**. It is emphatically not a verb
    /// name: `play` and `next-track` are vocabulary of `bin/media-control`,
    /// the CLI wrapper this app deliberately does not bundle, and passing one
    /// here gets `Invalid function name` and exit 1.
    ///
    /// `MediaCommand`'s raw values *are* those ids — both sides derive from
    /// the same MRCommand constants — so the mapping is the raw value and
    /// nothing else. Pinned by test rather than trusted: shipping the wrong
    /// vocabulary here is precisely the 1.0.4 regression.
    ///
    /// Internal so the mapping can be asserted without launching anything.
    nonisolated static func commandVerb(for command: MediaCommand) -> [String] {
        ["send", String(command.rawValue)]
    }

    /// Sends one transport command. Fire and forget.
    ///
    /// Returns whether the subprocess was **launched**, not whether the
    /// player obeyed. Nothing here waits on it, reads its output, or retries:
    /// this runs on the main actor in response to a button press, and the
    /// resulting state change arrives on the stream like any other.
    @discardableResult
    func sendCommand(_ command: MediaCommand) -> Bool {
        runTool(Self.commandVerb(for: command))
    }

    func send(_ command: MediaCommand) {
        sendCommand(command)
    }

    func seek(to seconds: TimeInterval) {
        // Non-localized on purpose: String(format:) with no locale renders a
        // dot, and the tool parses a dot. The AppleScript adapters have the
        // mirror image of this problem on the way in.
        runTool(["seek", String(format: "%.2f", max(0, seconds))])
    }

    /// Spawns one short-lived adapter invocation.
    ///
    /// A second process is not a choice. The stream subprocess is blocked
    /// inside `adapter_stream` for its whole life and has no control channel:
    /// the script reads `@ARGV` and environment variables once, before
    /// installing the XSUB, and never reads stdin. This is what the upstream
    /// CLI does for the same reason.
    ///
    /// **No environment is set, deliberately.** The framework is located by
    /// the absolute path in `@ARGV` and opened with `dl_load_file`, so no
    /// `DYLD_FRAMEWORK_PATH` is involved — and one would not survive anyway:
    /// dyld strips `DYLD_*` when exec'ing an Apple platform binary, which
    /// `/usr/bin/perl` is. Verified 2026-09-02: perl sees `<STRIPPED>` where
    /// a locally built binary sees the value. Matching the stream process
    /// therefore means setting nothing, which is what both do.
    @discardableResult
    private func runTool(_ verb: [String]) -> Bool {
        let label = verb.first ?? "?"
        guard let tool = Self.tool else {
            logCommandFailureOnce("\(label): no adapter (perl or a bundled component is missing)")
            return false
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: tool.perlPath)
        task.arguments = Self.arguments(verb: verb, tool: tool)
        task.standardOutput = FileHandle.nullDevice

        // stdout stays on nullDevice; stderr no longer does. `Invalid
        // function name` — the 1.0.4 regression — was written here and
        // discarded, leaving only an exit code to infer it from. Drained by
        // the handler so the child cannot block on a full pipe.
        let errorPipe = Pipe()
        task.standardError = errorPipe
        let collector = StderrCollector()
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            collector.append(chunk)
        }

        // This exists because its absence is what hid the 1.0.4 bug for a
        // whole release: perl launched cleanly, rejected the argument, and
        // exited 1 with nobody looking. A rejected command is now visible in
        // the log instead of being a button that silently does nothing.
        //
        // Deliberately does NOT touch `capability`. That axis describes the
        // stream; one refused command says nothing about whether the stream
        // is alive, and conflating them would report a dead source because a
        // button press failed.
        task.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            let crashed = finished.terminationReason == .uncaughtSignal
            let stderr = collector.text
            errorPipe.fileHandleForReading.readabilityHandler = nil
            guard status != 0 else { return }
            Task { @MainActor [weak self] in
                let how = crashed ? "crashed (signal \(status))" : "adapter exited \(status)"
                let detail = stderr.map { ": \($0.prefix(Capability.stderrLogLimit))" } ?? ""
                self?.logCommandFailureOnce("\(label): \(how)\(detail)")
            }
        }

        do {
            try task.run()
        } catch {
            errorPipe.fileHandleForReading.readabilityHandler = nil
            logCommandFailureOnce("\(label): \(error.localizedDescription)")
            return false
        }
        return true
    }

    /// One line per process, not per press.
    ///
    /// A dead adapter means every button is dead, and the user will press
    /// them more than once. Logging each attempt would bury the first and
    /// only useful line under the noise of the rest.
    private func logCommandFailureOnce(_ detail: String) {
        guard !commandFailureLogged else { return }
        commandFailureLogged = true
        Self.logger.error("Adapter command failed - \(detail, privacy: .public)")
    }
}

// MARK: - Line assembly

/// Reassembles newline-delimited JSON from arbitrary chunk boundaries.
///
/// There is no maximum line length: artwork ships as base64 inside the
/// payload, so a single line measured 45,905 bytes against the live tool and a
/// track with larger art will be bigger. The buffer grows until a newline
/// arrives; a chunk may hold a fragment, several whole lines, or both.
///
/// Not `Sendable` and not locked: `FileHandle` serialises `readabilityHandler`
/// invocations for a given handle, and this instance is reachable from nothing
/// else.
///
/// Internal rather than private for the same reason `SpotifyParsing` is: the
/// chunk-boundary behaviour is the part worth exercising directly.
nonisolated final class LineAssembler {

    private var buffer = Data()

    func lines(from chunk: Data) -> [Data] {
        buffer.append(chunk)
        var complete: [Data] = []
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<newline]
            if !line.isEmpty { complete.append(Data(line)) }
            // Rebased copy: slice indices stay anchored to the original range
            // otherwise, and the next firstIndex would walk consumed bytes.
            buffer = Data(buffer[buffer.index(after: newline)...])
        }
        return complete
    }
}

/// Drains a child's stderr, retaining only the first `limit` bytes.
///
/// Draining is not optional. A pipe nobody reads fills its buffer and the
/// child blocks forever on the next write, so the handler always consumes
/// what is available; the cap governs what is *kept*, which is a separate
/// question. A tool failing in a loop can produce unbounded stderr, and this
/// is retained on an adapter that runs for days.
///
/// Locked because the read handler and the termination handler are different
/// queues. Not `private`, so the cap can be asserted directly.
nonisolated final class StderrCollector {

    /// 2KB: several perl errors with file and line, nowhere near enough to
    /// matter against the app's memory budget.
    static let limit = 2048

    private var buffer = Data()
    private let lock = NSLock()

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        let room = Self.limit - buffer.count
        guard room > 0 else { return } // still drained by the caller, just not kept
        buffer.append(chunk.prefix(room))
    }

    /// What was kept, or nil if the child said nothing.
    var text: String? {
        lock.lock()
        defer { lock.unlock() }
        guard !buffer.isEmpty else { return nil }
        let decoded = String(decoding: buffer, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return decoded.isEmpty ? nil : decoded
    }
}

/// One-shot latch, so a repeating condition is reported once per stream
/// rather than once per occurrence.
///
/// Touched only from the pipe's read handler, which `FileHandle` serialises.
private nonisolated final class OnceGate {
    private var fired = false
    func firstTime() -> Bool {
        guard !fired else { return false }
        fired = true
        return true
    }
}

// MARK: - Wire format

/// One `{"type":..., "diff":..., "payload":{...}}` line.
nonisolated struct SystemMediaEnvelope: Decodable, Sendable {
    let type: String?
    let diff: Bool?
    let payload: SystemMediaPayload?
}

/// The payload's fields, all optional because a `diff` line carries only what
/// changed. Absent and explicitly-null are indistinguishable here; the tool
/// emits absent, and both correctly mean "keep what is retained".
///
/// Names match the tool's wire format exactly — `elapsedTime`, not `elapsed`,
/// and `playing`, not `isPlaying` — so this decodes with no CodingKeys.
/// Seconds throughout, unlike Spotify's milliseconds.
nonisolated struct SystemMediaPayload: Decodable, Equatable, Sendable {
    var title: String?
    var artist: String?
    var album: String?
    /// Base64. Decoded in the adapter, which caches it, rather than here.
    var artworkData: String?
    var artworkMimeType: String?
    var duration: TimeInterval?
    var elapsedTime: TimeInterval?
    var playing: Bool?
    var playbackRate: Double?
    var bundleIdentifier: String?
    var contentItemIdentifier: String?

    init() {}

    /// Names of the fields this payload actually carries. Logging only, so a
    /// diff line can be shown to have carried a subset of the whole.
    var presentFieldNames: [String] {
        var names: [String] = []
        if title != nil { names.append("title") }
        if artist != nil { names.append("artist") }
        if album != nil { names.append("album") }
        if artworkData != nil { names.append("artworkData") }
        if artworkMimeType != nil { names.append("artworkMimeType") }
        if duration != nil { names.append("duration") }
        if elapsedTime != nil { names.append("elapsedTime") }
        if playing != nil { names.append("playing") }
        if playbackRate != nil { names.append("playbackRate") }
        if bundleIdentifier != nil { names.append("bundleIdentifier") }
        if contentItemIdentifier != nil { names.append("contentItemIdentifier") }
        return names
    }

    /// This payload's fields laid over `old`, keeping `old` wherever this one
    /// says nothing. The whole point of the diff handling: a position-only
    /// update names `elapsedTime` and nothing else, and artist, album and
    /// artwork have to survive it.
    func merged(over old: SystemMediaPayload) -> SystemMediaPayload {
        var result = old
        if let title { result.title = title }
        if let artist { result.artist = artist }
        if let album { result.album = album }
        if let artworkData { result.artworkData = artworkData }
        if let artworkMimeType { result.artworkMimeType = artworkMimeType }
        if let duration { result.duration = duration }
        if let elapsedTime { result.elapsedTime = elapsedTime }
        if let playing { result.playing = playing }
        if let playbackRate { result.playbackRate = playbackRate }
        if let bundleIdentifier { result.bundleIdentifier = bundleIdentifier }
        if let contentItemIdentifier { result.contentItemIdentifier = contentItemIdentifier }
        return result
    }
}

/// What kind of thing a system session is carrying. Not a ranking of two
/// candidates: macOS reports one session at a time, so this only ever
/// describes the single session on offer.
nonisolated enum SystemSessionTier: Sendable {
    case music
    case video
}

/// Pure parsing, split out for tests — same arrangement as `SpotifyParsing`.
///
/// Split isolation on purpose. The project builds with
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so everything here is
/// main-actor isolated unless it says otherwise: `decode(line:)` is marked
/// `nonisolated` because it runs on the pipe's queue, while `snapshot(...)`
/// keeps the default because `NowPlaying` is main-actor isolated like the rest
/// of the model layer. Dropping the annotation compiles under Swift 5 but
/// hops 45KB of JSON onto the main thread, and is an error in Swift 6.
enum SystemMediaParsing {

    /// Decodes one line. Returns nil for anything unrecognisable rather than
    /// throwing: one malformed line must not take the stream down.
    nonisolated static func decode(line: Data) -> SystemMediaEnvelope? {
        guard let envelope = try? JSONDecoder().decode(SystemMediaEnvelope.self, from: line) else {
            return nil
        }
        // Every field is optional, so unrelated JSON decodes "successfully"
        // into an all-nil envelope — which `apply` would read as a full empty
        // payload and use to wipe the retained track. A line with no `type` is
        // not one of ours; treat it as unparseable.
        guard envelope.type != nil else { return nil }
        return envelope
    }

    /// Whether a session looks like music or like video.
    ///
    /// `album` is the whole test, and it is the only field that separates the
    /// two. Verified with `media-control get` on 2026-09-01: a YouTube Music
    /// track reports `album: "Camp"`, a YouTube video reports `album: ""`,
    /// and every other field — `bundleIdentifier` and `processIdentifier`
    /// included — is identical. There is no richer signal available.
    nonisolated static func tier(of payload: SystemMediaPayload) -> SystemSessionTier {
        let album = payload.album ?? ""
        return album.isEmpty ? .video : .music
    }

    /// Builds a snapshot from merged state, or nil when there is nothing to
    /// show — the empty payload the tool opens with, and what it sends when
    /// the last session goes away.
    ///
    /// `artwork` is passed in already decoded so this stays pure and the
    /// 40KB base64 is not re-decoded on every position tick.
    static func snapshot(
        from payload: SystemMediaPayload, artwork: Data?, capturedAt: Date
    ) -> NowPlaying? {
        var snapshot = NowPlaying()
        snapshot.isPlaying = payload.playing ?? false
        snapshot.title = payload.title.nonEmpty
        snapshot.artist = payload.artist.nonEmpty
        snapshot.album = payload.album.nonEmpty
        snapshot.artworkData = artwork
        snapshot.artworkIdentifier = payload.contentItemIdentifier.nonEmpty
        snapshot.duration = payload.duration
        snapshot.elapsed = payload.elapsedTime
        snapshot.sourceBundleID = payload.bundleIdentifier.nonEmpty
        snapshot.capturedAt = capturedAt

        guard snapshot.hasContent else { return nil }
        return snapshot
    }
}

private extension Optional where Wrapped == String {
    /// Empty strings are how the tool spells "no album", and `hasContent`
    /// counts any non-nil title as presence — so they have to become nil.
    var nonEmpty: String? {
        guard let self, !self.isEmpty else { return nil }
        return self
    }
}

/// How many times, and how soon, a dead system now-playing stream is
/// relaunched.
///
/// Growing delays (2s, 8s, 32s, 128s), then nothing until `reset()` — which
/// the adapter calls on a display wake and on a deliberate stop, so a fresh
/// enable starts over. A stream that ran for at least `healthyLifetime`
/// before dying also earns a fresh budget: that is an occasional crash, not
/// a tool failing on launch, and at most one restart per minute is still
/// nothing like a poll. Pure, for tests.
nonisolated struct StreamRestartBackoff {
    static let delays: [TimeInterval] = [2, 8, 32, 128]
    static let healthyLifetime: TimeInterval = 60

    /// Restarts used from the current budget.
    private(set) var attempts = 0

    /// The wait before the next restart, or nil once the budget is spent.
    mutating func nextDelay(afterLifetime lived: TimeInterval) -> TimeInterval? {
        if lived >= Self.healthyLifetime { attempts = 0 }
        guard attempts < Self.delays.count else { return nil }
        let delay = Self.delays[attempts]
        attempts += 1
        return delay
    }

    mutating func reset() { attempts = 0 }
}
