import Foundation

// Per-app volume, Phase 3: which user-facing app owns an audio-producing
// process. Pure: everything the resolver needs arrives as `ProcessFacts`,
// gathered by `ProcessFactsGatherer`, so the chain is tested with fixtures
// from the spike's measurements rather than against real processes.
// See docs/FUTURE-audio-mixer.md, *Mapping an audio process to its owning
// app*, and *v1 plan*.

/// Who signed a binary, as far as matching goes. A team ID when there is one;
/// Apple's own platform binaries have none, so they match each other as
/// "platform". Unsigned or ad-hoc code has no identity and matches nothing.
struct CodeIdentity: Equatable {
    var teamID: String?
    var isPlatform: Bool

    static let unknown = CodeIdentity(teamID: nil, isPlatform: false)

    var matchKey: String? {
        teamID ?? (isPlatform ? "platform" : nil)
    }

    func matches(_ other: CodeIdentity) -> Bool {
        guard let mine = matchKey, let theirs = other.matchKey else { return false }
        return mine == theirs
    }
}

/// A running app, in the sense the resolver can name: an `NSRunningApplication`
/// whose own bundle is the outermost `.app` around its executable. Helper
/// bundles nested inside an app are therefore never one of these.
struct RunningAppFacts: Equatable {
    var pid: pid_t
    var bundleID: String
    var name: String
    var identity: CodeIdentity
    /// `.regular` activation policy: a Dock app. Only matters for Apple's
    /// platform apps, where it separates Messages from Control Center.
    var isRegular: Bool
}

/// Everything public that is known about one audio-producing process.
struct ProcessFacts: Equatable {
    var pid: pid_t
    /// `kAudioProcessPropertyBundleID`: always the process's own bundle,
    /// never its app's.
    var bundleID: String?
    var executablePath: String
    var identity: CodeIdentity
    /// The bundle ID of the outermost `.app` around `executablePath`, if any.
    /// Path containment is judged by this rather than by comparing path
    /// prefixes, which symlinks defeat (Safari lives in a cryptex).
    var containerBundleID: String?
    /// This process is itself an app.
    var ownApp: RunningAppFacts?
    /// The nearest ancestor, up the parent-PID chain, that is an app.
    var parentApp: RunningAppFacts?
    /// The running app whose bundle is the outermost `.app` around this
    /// executable, however it was launched (an XPC service's parent is launchd).
    var containingApp: RunningAppFacts?
}

/// How a process was resolved, for the logs.
enum AudioOwnerResolution: String, Equatable {
    case ownApp = "the app itself"
    case parentApp = "helper under its parent app"
    case containingApp = "helper inside its app's bundle"
    case webKit = "WebKit"
    case executableName = "executable name"
}

enum AudioOwnerKind: String, Equatable {
    case app
    case webContent = "web content"
    case process
}

struct AudioOwner: Equatable {
    /// What volume state is keyed by: the owning app's bundle ID,
    /// `AudioOwnerResolver.webContentKey`, or `path:` plus the executable.
    var key: String
    var name: String
    var kind: AudioOwnerKind
    var resolution: AudioOwnerResolution
}

enum AudioHiddenReason: String, Equatable {
    case selfProcess = "PopNotch itself"
    case platformDaemon = "system daemon"
    case systemAgent = "system agent"
}

enum AudioOwnerResult: Equatable {
    /// A row the user can see, and later adjust.
    case shown(AudioOwner)
    /// Never listed and never tapped.
    case hidden(AudioHiddenReason, name: String)
}

enum AudioOwnerResolver {

    nonisolated static let webContentKey = "webkit"
    nonisolated static let webContentName = "Web content"

    /// The resolution chain, first match wins. Public information only: the
    /// responsible-process API would name Safari, and is private.
    ///
    /// 1. PopNotch itself: hidden. Its own re-render will be an audio process.
    /// 2. The app itself: its own bundle is the outermost app.
    /// 3. WebKit: every `com.apple.WebKit.*` process is one "Web content" row.
    ///    Nothing public ties the GPU process to Safari rather than Mail.
    /// 4. A helper under its parent: an ancestor is an app, the helper's
    ///    outermost bundle is that app, and they share a signing identity.
    /// 5. A helper by path alone: its outermost bundle is a running app with
    ///    the same signing identity, whatever its parent (XPC services).
    /// 6. Any other Apple platform binary: a daemon, hidden and never tapped.
    /// 7. Anything else: shown by executable name.
    ///
    /// Steps 2, 4 and 5 hide an Apple platform app that is not a Dock app —
    /// Control Center, PowerChime, the Dock — as a system agent: system UI,
    /// not something to turn down.
    nonisolated static func resolve(_ facts: ProcessFacts, selfPID: pid_t) -> AudioOwnerResult {
        let executableName = (facts.executablePath as NSString).lastPathComponent
        if facts.pid == selfPID {
            return .hidden(.selfProcess, name: executableName)
        }
        if let app = facts.ownApp {
            return result(for: app, via: .ownApp)
        }
        if facts.bundleID?.hasPrefix("com.apple.WebKit.") == true {
            return .shown(AudioOwner(key: webContentKey, name: webContentName,
                                     kind: .webContent, resolution: .webKit))
        }
        if let parent = facts.parentApp,
           parent.bundleID == facts.containerBundleID,
           facts.identity.matches(parent.identity) {
            return result(for: parent, via: .parentApp)
        }
        if let container = facts.containingApp,
           container.bundleID == facts.containerBundleID,
           facts.identity.matches(container.identity) {
            return result(for: container, via: .containingApp)
        }
        if facts.identity.isPlatform {
            return .hidden(.platformDaemon, name: executableName)
        }
        return .shown(AudioOwner(key: facts.bundleID ?? "path:\(facts.executablePath)",
                                 name: executableName, kind: .process,
                                 resolution: .executableName))
    }

    nonisolated private static func result(for app: RunningAppFacts,
                                           via resolution: AudioOwnerResolution) -> AudioOwnerResult {
        if app.identity.isPlatform && !app.isRegular {
            return .hidden(.systemAgent, name: app.name)
        }
        return .shown(AudioOwner(key: app.bundleID, name: app.name, kind: .app,
                                 resolution: resolution))
    }

    /// The outermost `.app` bundle around a path, or nil when there is none
    /// (a framework's XPC service, a daemon, a command-line tool).
    nonisolated static func outermostAppPath(in path: String) -> String? {
        var components: [String] = []
        for component in (path as NSString).pathComponents {
            components.append(component)
            if component.hasSuffix(".app") {
                return NSString.path(withComponents: components)
            }
        }
        return nil
    }
}

/// One row: an owner and every process it currently plays through.
struct AudioAppRow: Equatable {
    var owner: AudioOwner
    var pids: [pid_t]
}

enum AudioRowBuilder {

    /// Groups resolved processes into rows by owner key: Chrome's helpers
    /// become one Chrome row, every WebKit process one "Web content" row.
    /// Rows are sorted by name; hidden processes are returned separately so
    /// they can be counted and logged, never shown.
    nonisolated static func rows(from resolved: [(pid: pid_t, result: AudioOwnerResult)])
        -> (rows: [AudioAppRow], hidden: [(name: String, reason: AudioHiddenReason)]) {
        var byKey: [String: AudioAppRow] = [:]
        var hidden: [(name: String, reason: AudioHiddenReason)] = []
        for entry in resolved {
            switch entry.result {
            case .shown(let owner):
                byKey[owner.key, default: AudioAppRow(owner: owner, pids: [])].pids.append(entry.pid)
            case .hidden(let reason, let name):
                hidden.append((name, reason))
            }
        }
        let rows = byKey.values
            .map { AudioAppRow(owner: $0.owner, pids: $0.pids.sorted()) }
            .sorted { ($0.owner.name.localizedLowercase, $0.owner.key) < ($1.owner.name.localizedLowercase, $1.owner.key) }
        return (rows, hidden.sorted { $0.name < $1.name })
    }
}
