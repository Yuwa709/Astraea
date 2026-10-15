import XCTest
import os
@testable import PopNotch

/// The owner resolver, against fixtures taken from the spike's measurements
/// (docs/FUTURE-audio-mixer.md, *A* and *Mapping an audio process to its
/// owning app*; 2026-09-16 and 2026-09-17). Paths, PIDs, team IDs and bundle
/// IDs are the measured ones. Two cases are labelled synthetic: variations
/// built from Discord's measured identity, for situations the spike did not
/// happen to catch. No test here touches real Core Audio or a real process.
@MainActor
final class AudioOwnerResolverTests: XCTestCase {

    private let popNotchPID: pid_t = 855

    /// Services built here log nowhere. The test host is a copy of PopNotch
    /// writing to the same subsystem and category as the real app, so
    /// fixture rows would otherwise land in the log the real rows are
    /// verified from.
    private static let silent = Logger(OSLog.disabled)

    // MARK: - Fixtures

    private static let spotifyTeam = CodeIdentity(teamID: "2FNC3A47ZF", isPlatform: false)
    private static let chromeTeam = CodeIdentity(teamID: "EQHXZ8M8AV", isPlatform: false)
    private static let discordTeam = CodeIdentity(teamID: "53Q6R32WPB", isPlatform: false)
    private static let claudeTeam = CodeIdentity(teamID: "Q6L2SF6YDW", isPlatform: false)
    private static let firefoxTeam = CodeIdentity(teamID: "43AQ936H96", isPlatform: false)
    private static let popNotchTeam = CodeIdentity(teamID: "4KUMGQ48T9", isPlatform: false)
    private static let apple = CodeIdentity(teamID: nil, isPlatform: true)

    private static let chrome = RunningAppFacts(pid: 9361, bundleID: "com.google.Chrome",
                                                name: "Google Chrome", identity: chromeTeam, isRegular: true)
    private static let discord = RunningAppFacts(pid: 2923, bundleID: "com.hnc.Discord",
                                                 name: "Discord", identity: discordTeam, isRegular: true)

    /// Plays from its own process (A).
    private static let spotify = ProcessFacts(
        pid: 852, bundleID: "com.spotify.client",
        executablePath: "/Applications/Spotify.app/Contents/MacOS/Spotify",
        identity: spotifyTeam, containerBundleID: "com.spotify.client",
        ownApp: RunningAppFacts(pid: 852, bundleID: "com.spotify.client", name: "Spotify",
                                identity: spotifyTeam, isRegular: true),
        parentApp: nil, containingApp: nil)

    /// Its only Core Audio process object is the main app.
    private static let firefox = ProcessFacts(
        pid: 1435, bundleID: "org.mozilla.firefox",
        executablePath: "/Applications/Firefox.app/Contents/MacOS/firefox",
        identity: firefoxTeam, containerBundleID: "org.mozilla.firefox",
        ownApp: RunningAppFacts(pid: 1435, bundleID: "org.mozilla.firefox", name: "Firefox",
                                identity: firefoxTeam, isRegular: true),
        parentApp: nil, containingApp: nil)

    /// The `audio.mojom.AudioService` helper that emitted Chrome's audio (A).
    private static let chromeAudioHelper = ProcessFacts(
        pid: 9400, bundleID: "com.google.Chrome.helper",
        executablePath: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/152.0.7977.83/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper",
        identity: chromeTeam, containerBundleID: "com.google.Chrome",
        ownApp: nil, parentApp: chrome, containingApp: chrome)

    /// Discord's call audio runs in its renderer, running input and output.
    private static let discordRenderer = ProcessFacts(
        pid: 2942, bundleID: "com.hnc.Discord.helper.Renderer",
        executablePath: "/Applications/Discord.app/Contents/Frameworks/Discord Helper (Renderer).app/Contents/MacOS/Discord Helper (Renderer)",
        identity: discordTeam, containerBundleID: "com.hnc.Discord",
        ownApp: nil, parentApp: discord, containingApp: discord)

    private static let claudeHelper = ProcessFacts(
        pid: 1495, bundleID: "com.anthropic.claudefordesktop.helper",
        executablePath: "/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper",
        identity: claudeTeam, containerBundleID: "com.anthropic.claudefordesktop",
        ownApp: nil,
        parentApp: RunningAppFacts(pid: 1337, bundleID: "com.anthropic.claudefordesktop",
                                   name: "Claude", identity: claudeTeam, isRegular: true),
        containingApp: nil)

    /// Safari's audio, from the framework's XPC service, parent launchd (A).
    private static let webKitGPU = ProcessFacts(
        pid: 9377, bundleID: "com.apple.WebKit.GPU",
        executablePath: "/System/Volumes/Preboot/Cryptexes/Incoming/OS/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.GPU.xpc/Contents/MacOS/com.apple.WebKit.GPU",
        identity: apple, containerBundleID: nil,
        ownApp: nil, parentApp: nil, containingApp: nil)

    /// An XPC service inside an Apple app's bundle, parent launchd.
    private static let dockHelper = ProcessFacts(
        pid: 1367, bundleID: nil,
        executablePath: "/System/Library/CoreServices/Dock.app/Contents/XPCServices/DockHelper.xpc/Contents/MacOS/DockHelper",
        identity: apple, containerBundleID: "com.apple.dock",
        ownApp: nil, parentApp: nil,
        containingApp: RunningAppFacts(pid: 640, bundleID: "com.apple.dock", name: "Dock",
                                       identity: apple, isRegular: false))

    private static func daemon(_ pid: pid_t, _ bundleID: String?, _ path: String) -> ProcessFacts {
        ProcessFacts(pid: pid, bundleID: bundleID, executablePath: path, identity: apple,
                     containerBundleID: nil, ownApp: nil, parentApp: nil, containingApp: nil)
    }

    private static func appleApp(_ pid: pid_t, _ bundleID: String, _ name: String,
                                 _ path: String, regular: Bool) -> ProcessFacts {
        let app = RunningAppFacts(pid: pid, bundleID: bundleID, name: name,
                                  identity: apple, isRegular: regular)
        return ProcessFacts(pid: pid, bundleID: bundleID, executablePath: path, identity: apple,
                            containerBundleID: bundleID, ownApp: app, parentApp: nil, containingApp: nil)
    }

    private func resolve(_ facts: ProcessFacts) -> AudioOwnerResult {
        AudioOwnerResolver.resolve(facts, selfPID: popNotchPID)
    }

    private func shown(_ facts: ProcessFacts, file: StaticString = #filePath, line: UInt = #line) -> AudioOwner? {
        guard case .shown(let owner) = resolve(facts) else {
            XCTFail("expected a shown row, got \(resolve(facts))", file: file, line: line)
            return nil
        }
        return owner
    }

    // MARK: - The chain

    func testAnAppPlayingItselfResolvesByBundleID() {
        let owner = shown(Self.spotify)
        XCTAssertEqual(owner?.key, "com.spotify.client")
        XCTAssertEqual(owner?.name, "Spotify")
        XCTAssertEqual(owner?.kind, .app)
        XCTAssertEqual(owner?.resolution, .ownApp)
        XCTAssertEqual(shown(Self.firefox)?.key, "org.mozilla.firefox")
    }

    func testChromesAudioHelperResolvesToChromeThroughItsParent() {
        let owner = shown(Self.chromeAudioHelper)
        XCTAssertEqual(owner?.key, "com.google.Chrome")
        XCTAssertEqual(owner?.name, "Google Chrome")
        XCTAssertEqual(owner?.resolution, .parentApp)
    }

    func testElectronHelpersResolveToTheirApps() {
        XCTAssertEqual(shown(Self.discordRenderer)?.key, "com.hnc.Discord")
        XCTAssertEqual(shown(Self.claudeHelper)?.key, "com.anthropic.claudefordesktop")
    }

    /// Parent launchd, so the parent chain cannot help; its bundle can.
    /// Synthetic: the path shape of an app-bundled XPC service, with
    /// Discord's measured identity.
    func testAnXPCServiceInsideAnAppsBundleResolvesByPath() {
        let service = ProcessFacts(
            pid: 3100, bundleID: "com.hnc.Discord.audio",
            executablePath: "/Applications/Discord.app/Contents/XPCServices/Audio.xpc/Contents/MacOS/Audio",
            identity: Self.discordTeam, containerBundleID: "com.hnc.Discord",
            ownApp: nil, parentApp: nil, containingApp: Self.discord)
        let owner = shown(service)
        XCTAssertEqual(owner?.key, "com.hnc.Discord")
        XCTAssertEqual(owner?.resolution, .containingApp)
    }

    /// Nothing public ties the GPU process to Safari, so it is one row for
    /// every WebKit app, never "Safari".
    func testWebKitIsOneGenericWebContentRow() {
        let owner = shown(Self.webKitGPU)
        XCTAssertEqual(owner?.key, AudioOwnerResolver.webContentKey)
        XCTAssertEqual(owner?.name, "Web content")
        XCTAssertEqual(owner?.kind, .webContent)
    }

    /// Resolves through its bundle to the Dock, which is system UI.
    func testAnAppleXPCServiceOfASystemAgentIsHidden() {
        XCTAssertEqual(resolve(Self.dockHelper), .hidden(.systemAgent, name: "Dock"))
    }

    func testAppleAppsThatAreNotDockAppsAreHidden() {
        let controlCenter = Self.appleApp(642, "com.apple.controlcenter", "Control Center",
            "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter", regular: false)
        let powerChime = Self.appleApp(2636, "com.apple.PowerChime", "PowerChime",
            "/System/Library/CoreServices/PowerChime.app/Contents/MacOS/PowerChime", regular: false)
        XCTAssertEqual(resolve(controlCenter), .hidden(.systemAgent, name: "Control Center"))
        XCTAssertEqual(resolve(powerChime), .hidden(.systemAgent, name: "PowerChime"))
    }

    func testAnAppleDockAppIsShown() {
        let messages = Self.appleApp(1832, "com.apple.MobileSMS", "Messages",
            "/System/Applications/Messages.app/Contents/MacOS/Messages", regular: true)
        XCTAssertEqual(shown(messages)?.key, "com.apple.MobileSMS")
    }

    /// Calls, system sounds and the like: platform daemons that no public
    /// signal attributes to an app. Hidden, never tapped.
    func testPlatformDaemonsAreHidden() {
        let daemons = [
            Self.daemon(653, "com.apple.TelephonyUtilities",
                        "/System/Library/PrivateFrameworks/TelephonyUtilities.framework/callservicesd"),
            Self.daemon(807, "systemsoundserverd", "/usr/sbin/systemsoundserverd"),
            Self.daemon(794, "com.apple.avconferenced", "/usr/libexec/avconferenced"),
            Self.daemon(618, "com.apple.cloudpaird", "/System/Library/CoreServices/audioaccessoryd"),
        ]
        for daemon in daemons {
            guard case .hidden(.platformDaemon, _) = resolve(daemon) else {
                return XCTFail("\(daemon.executablePath) must be hidden as a daemon")
            }
        }
    }

    /// The probe itself: an unbundled command-line tool, ad-hoc signed.
    func testAnUnbundledProcessIsNamedByItsExecutable() {
        let path = "/private/tmp/claude-501/-Users-thangpham-PopNotch/5d7b9ac1-dd81-4f3b-a8c1-fbcb2d2ddf4f/scratchpad/ownerprobe/ownerprobe"
        let tool = ProcessFacts(pid: 6329, bundleID: nil, executablePath: path,
                                identity: .unknown, containerBundleID: nil,
                                ownApp: nil, parentApp: nil, containingApp: nil)
        let owner = shown(tool)
        XCTAssertEqual(owner?.name, "ownerprobe")
        XCTAssertEqual(owner?.key, "path:\(path)")
        XCTAssertEqual(owner?.kind, .process)
    }

    func testPopNotchItselfIsAlwaysExcluded() {
        let popNotch = ProcessFacts(
            pid: popNotchPID, bundleID: "com.techie.PopNotch",
            executablePath: "/Applications/PopNotch.app/Contents/MacOS/PopNotch",
            identity: Self.popNotchTeam, containerBundleID: "com.techie.PopNotch",
            ownApp: RunningAppFacts(pid: popNotchPID, bundleID: "com.techie.PopNotch", name: "PopNotch",
                                    identity: Self.popNotchTeam, isRegular: false),
            parentApp: nil, containingApp: nil)
        XCTAssertEqual(resolve(popNotch), .hidden(.selfProcess, name: "PopNotch"))
    }

    // MARK: - Signing identity

    /// A helper inside an app's bundle but signed by someone else is not
    /// that app's. Synthetic: Discord's renderer with a foreign team.
    func testAForeignSignedHelperIsNotAttributedToTheApp() {
        var impostor = Self.discordRenderer
        impostor.identity = CodeIdentity(teamID: "ZZZZZZZZZZ", isPlatform: false)
        let owner = shown(impostor)
        XCTAssertEqual(owner?.key, "com.hnc.Discord.helper.Renderer")
        XCTAssertEqual(owner?.resolution, .executableName)
    }

    /// An unreadable signature matches nothing: fail closed, never guess.
    func testAnUnreadableSignatureMatchesNothing() {
        var unknown = Self.chromeAudioHelper
        unknown.identity = .unknown
        XCTAssertEqual(shown(unknown)?.resolution, .executableName)
    }

    func testIdentityMatching() {
        XCTAssertTrue(Self.apple.matches(Self.apple), "Apple platform binaries match each other")
        XCTAssertTrue(Self.chromeTeam.matches(Self.chromeTeam))
        XCTAssertFalse(Self.chromeTeam.matches(Self.discordTeam))
        XCTAssertFalse(Self.apple.matches(Self.chromeTeam))
        XCTAssertFalse(CodeIdentity.unknown.matches(.unknown), "no identity matches nothing")
    }

    // MARK: - Outermost app

    func testOutermostAppPath() {
        XCTAssertEqual(AudioOwnerResolver.outermostAppPath(in: Self.chromeAudioHelper.executablePath),
                       "/Applications/Google Chrome.app")
        XCTAssertEqual(AudioOwnerResolver.outermostAppPath(in: Self.spotify.executablePath),
                       "/Applications/Spotify.app")
        XCTAssertEqual(AudioOwnerResolver.outermostAppPath(in: Self.dockHelper.executablePath),
                       "/System/Library/CoreServices/Dock.app")
        XCTAssertNil(AudioOwnerResolver.outermostAppPath(in: Self.webKitGPU.executablePath))
        XCTAssertNil(AudioOwnerResolver.outermostAppPath(in: "/usr/sbin/systemsoundserverd"))
    }

    // MARK: - Rows

    /// Every WebKit process is one row; hidden processes are counted apart.
    func testRowsGroupByOwnerAndSortByName() {
        var secondWebKit = Self.webKitGPU
        secondWebKit.pid = 9500
        let resolved = [Self.webKitGPU, Self.spotify, secondWebKit, Self.discordRenderer,
                        Self.daemon(653, "com.apple.TelephonyUtilities",
                                    "/System/Library/PrivateFrameworks/TelephonyUtilities.framework/callservicesd")]
            .map { (pid: $0.pid, result: resolve($0)) }
        let built = AudioRowBuilder.rows(from: resolved)
        XCTAssertEqual(built.rows.map(\.owner.name), ["Discord", "Spotify", "Web content"])
        XCTAssertEqual(built.rows.last?.pids, [9377, 9500])
        XCTAssertEqual(built.hidden.map(\.name), ["callservicesd"])
    }

    // MARK: - Service

    func testTheServiceListsOnlyPlayingProcessesAndResolvesEachOnce() {
        let source = StubAudioProcessSource()
        var resolutions = 0
        let byPID: [pid_t: ProcessFacts] = [852: Self.spotify, 9377: Self.webKitGPU, 2942: Self.discordRenderer]
        let service = AppVolumeService(source: source, resolve: { snapshot in
            resolutions += 1
            return byPID[snapshot.pid].map { AudioOwnerResolver.resolve($0, selfPID: self.popNotchPID) }
        }, logger: Self.silent)
        service.startWatching()

        source.publish([.init(objectID: 1, pid: 852, bundleID: "com.spotify.client", isRunningOutput: true),
                        .init(objectID: 2, pid: 9377, bundleID: "com.apple.WebKit.GPU", isRunningOutput: false),
                        .init(objectID: 3, pid: 2942, bundleID: nil, isRunningOutput: true)])
        XCTAssertEqual(service.rows.map(\.owner.name), ["Discord", "Spotify"], "not-playing processes are not rows")

        source.publish([.init(objectID: 1, pid: 852, bundleID: "com.spotify.client", isRunningOutput: false),
                        .init(objectID: 2, pid: 9377, bundleID: "com.apple.WebKit.GPU", isRunningOutput: true),
                        .init(objectID: 3, pid: 2942, bundleID: nil, isRunningOutput: true)])
        XCTAssertEqual(service.rows.map(\.owner.name), ["Discord", "Web content"])
        XCTAssertEqual(resolutions, 3, "each process object resolved once, however often it is seen")
    }

    func testStoppingClearsTheRows() {
        let source = StubAudioProcessSource()
        let service = AppVolumeService(source: source, resolve: { _ in
            .shown(AudioOwner(key: "k", name: "App", kind: .app, resolution: .ownApp))
        }, logger: Self.silent)
        service.startWatching()
        source.publish([.init(objectID: 1, pid: 1, bundleID: nil, isRunningOutput: true)])
        XCTAssertEqual(service.rows.count, 1)
        service.stopWatching()
        XCTAssertTrue(service.rows.isEmpty)
        XCTAssertFalse(source.isRunning)
    }
}

/// Stands in for Core Audio: the test drives the process list directly.
@MainActor
final class StubAudioProcessSource: AudioProcessSource {
    private(set) var processes: [AudioProcessSnapshot] = []
    var onChange: (([AudioProcessSnapshot]) -> Void)?
    private(set) var isRunning = false

    func start() { isRunning = true }
    func stop() { isRunning = false }

    func publish(_ snapshots: [AudioProcessSnapshot]) {
        processes = snapshots
        onChange?(snapshots)
    }

    /// The world changing with no notification — an app quitting once its
    /// audio objects were already gone. What `refreshRows()` exists for.
    func quietly(_ snapshots: [AudioProcessSnapshot]) {
        processes = snapshots
    }
}
