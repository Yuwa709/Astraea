import XCTest
@testable import PopNotch

/// Why the system now-playing source is or is not working.
///
/// Every one of these failures used to be a single log line and nothing
/// else: the reason was known at the moment it happened and gone by the next
/// statement. These pin that it is now retained, and that the distinctions
/// which were previously impossible to make — missing perl versus a perl
/// that is not executable, a crash versus an ordinary non-zero exit — come
/// out the other side intact.
///
/// Cases and relationships are asserted, never the wording: the strings are
/// diagnostics for a human reading the log, and pinning them here would make
/// improving them a test failure.
@MainActor
final class SystemMediaCapabilityTests: XCTestCase {

    private let perl = "/usr/bin/perl"

    private func resolved(perlExists: Bool = true,
                          perlExecutable: Bool = true,
                          script: String? = "/x/mediaremote-adapter.pl",
                          framework: String? = "/x/MediaRemoteAdapter.framework",
                          testClient: String? = "/x/MediaRemoteAdapterTestClient")
    -> SystemMediaAdapter.Resolution {
        SystemMediaAdapter.resolve(
            perlPath: perl,
            perlExists: perlExists,
            perlExecutable: perlExecutable,
            scriptPath: script,
            frameworkPath: framework,
            testClientPath: testClient)
    }

    // MARK: - Starting state

    func testCapabilityIsUnknownBeforeStart() {
        XCTAssertEqual(SystemMediaAdapter().capability, .unknown)
    }

    /// `permissionDenied` is a different axis and must not move with this
    /// one. A dead adapter is not a denied one, and conflating them would
    /// raise the in-notch Automation banner for a problem no permission can
    /// fix.
    func testCapabilityDoesNotDisturbPermissionDenied() {
        let adapter = SystemMediaAdapter()
        adapter.recordStreamExit(status: 1, crashed: false, stderr: nil)
        XCTAssertFalse(adapter.permissionDenied)
    }

    // MARK: - Resolve failures

    func testMissingPerlResolvesToPerlUnavailable() {
        guard case .unavailable(let reason) = resolved(perlExists: false) else {
            return XCTFail("a missing interpreter must not resolve")
        }
        guard case .perlUnavailable(let detail) = reason else {
            return XCTFail("expected .perlUnavailable, got \(reason)")
        }
        XCTAssertNotEqual(reason, .unknown, "the reason must be recorded, not left unknown")
        XCTAssertTrue(detail.contains(perl), "the detail names the path it looked at")
    }

    /// The distinction the old single `isExecutableFile` check could not
    /// make. Both are `.perlUnavailable`, and they must not be equal — a
    /// macOS that dropped the runtime and a file with the bit off need
    /// different fixes.
    func testNonExecutablePerlIsDistinctFromMissingPerl() {
        guard case .unavailable(let missing) = resolved(perlExists: false),
              case .unavailable(let notExecutable) = resolved(perlExecutable: false)
        else { return XCTFail("neither case may resolve") }

        if case .perlUnavailable = notExecutable {} else {
            return XCTFail("expected .perlUnavailable, got \(notExecutable)")
        }
        XCTAssertNotEqual(missing, notExecutable)
    }

    func testMissingScriptResolvesToBundleComponentMissing() {
        guard case .unavailable(let reason) = resolved(script: nil) else {
            return XCTFail("a missing script must not resolve")
        }
        guard case .bundleComponentMissing = reason else {
            return XCTFail("expected .bundleComponentMissing, got \(reason)")
        }
        XCTAssertNotEqual(reason, .unknown)
    }

    func testMissingFrameworkResolvesToBundleComponentMissing() {
        guard case .unavailable(let reason) = resolved(framework: nil) else {
            return XCTFail("a missing framework must not resolve")
        }
        guard case .bundleComponentMissing = reason else {
            return XCTFail("expected .bundleComponentMissing, got \(reason)")
        }
    }

    /// Two missing components are both `.bundleComponentMissing` but must
    /// name different things, or the log cannot say which to reinstall.
    func testTheTwoBundleComponentsAreDistinguishable() {
        guard case .unavailable(let noScript) = resolved(script: nil),
              case .unavailable(let noFramework) = resolved(framework: nil)
        else { return XCTFail("neither case may resolve") }
        XCTAssertNotEqual(noScript, noFramework)
    }

    /// Ordering, not preference: perl is checked before the bundle, so a
    /// machine missing both reports the interpreter. Pinned because the
    /// reverse would send someone reinstalling an app that is intact.
    func testPerlIsReportedBeforeBundleComponents() {
        guard case .unavailable(let reason) = resolved(perlExists: false, script: nil) else {
            return XCTFail("must not resolve")
        }
        guard case .perlUnavailable = reason else {
            return XCTFail("expected the interpreter to be reported first, got \(reason)")
        }
    }

    // MARK: - Resolve success

    func testEverythingPresentResolves() {
        guard case .resolved(let tool) = resolved() else {
            return XCTFail("a complete set must resolve")
        }
        XCTAssertEqual(tool.perlPath, perl)
        XCTAssertNotNil(tool.testClientPath)
    }

    /// The health probe is optional by design and must never gate the
    /// stream.
    func testMissingTestClientStillResolves() {
        guard case .resolved(let tool) = resolved(testClient: nil) else {
            return XCTFail("the optional probe must not gate availability")
        }
        XCTAssertNil(tool.testClientPath)
    }

    // MARK: - Exit

    func testNonZeroExitRecordsTheStatus() {
        let adapter = SystemMediaAdapter()
        adapter.recordStreamExit(status: 1, crashed: false, stderr: nil)

        guard case .exited(let status, let crashed, _) = adapter.capability else {
            return XCTFail("expected .exited, got \(adapter.capability)")
        }
        XCTAssertEqual(status, 1)
        XCTAssertFalse(crashed)
    }

    func testSignalTerminationSetsCrashed() {
        let adapter = SystemMediaAdapter()
        adapter.recordStreamExit(status: 11, crashed: true, stderr: nil)

        guard case .exited(let status, let crashed, _) = adapter.capability else {
            return XCTFail("expected .exited, got \(adapter.capability)")
        }
        XCTAssertEqual(status, 11)
        XCTAssertTrue(crashed)
    }

    /// The whole point of reading `terminationReason`: the same status from a
    /// signal and from an ordinary exit are different events.
    func testCrashAndCleanExitWithTheSameStatusAreNotEqual() {
        let crashed = SystemMediaAdapter()
        crashed.recordStreamExit(status: 9, crashed: true, stderr: nil)
        let exited = SystemMediaAdapter()
        exited.recordStreamExit(status: 9, crashed: false, stderr: nil)
        XCTAssertNotEqual(crashed.capability, exited.capability)
    }

    func testStderrIsCarriedOntoTheExit() {
        let adapter = SystemMediaAdapter()
        adapter.recordStreamExit(status: 2, crashed: false, stderr: "Invalid function name")

        guard case .exited(_, _, let stderr) = adapter.capability else {
            return XCTFail("expected .exited, got \(adapter.capability)")
        }
        XCTAssertEqual(stderr, "Invalid function name")
    }

    /// Absent stderr and captured stderr are different states, so a report
    /// saying "no stderr" means the tool was silent rather than that nobody
    /// looked.
    func testAbsentStderrDiffersFromCapturedStderr() {
        let silent = SystemMediaAdapter()
        silent.recordStreamExit(status: 1, crashed: false, stderr: nil)
        let noisy = SystemMediaAdapter()
        noisy.recordStreamExit(status: 1, crashed: false, stderr: "boom")
        XCTAssertNotEqual(silent.capability, noisy.capability)
    }

    // MARK: - Success and teardown

    private func dataLine() -> SystemMediaEnvelope {
        let json = """
        {"type":"data","diff":false,"payload":{
          "title":"3005","artist":"Childish Gambino","album":"Because the Internet",
          "bundleIdentifier":"org.mozilla.firefox","contentItemIdentifier":"x",
          "playing":true,"elapsedTime":1.0,"duration":100.0}}
        """
        guard let envelope = SystemMediaParsing.decode(line: Data(json.utf8)) else {
            fatalError("test fixture did not decode")
        }
        return envelope
    }

    func testFirstParsedPayloadReportsOK() {
        let adapter = SystemMediaAdapter()
        XCTAssertEqual(adapter.capability, .unknown)
        adapter.ingest([dataLine()])
        XCTAssertEqual(adapter.capability, .ok)
    }

    /// A payload arriving after a death is the recovery, and must clear the
    /// failure rather than leaving a stale one behind.
    func testAPayloadAfterAnExitClearsTheFailure() {
        let adapter = SystemMediaAdapter()
        adapter.recordStreamExit(status: 1, crashed: false, stderr: "boom")
        adapter.ingest([dataLine()])
        XCTAssertEqual(adapter.capability, .ok)
    }

    /// Stopping is not failing. Leaving `.ok` would claim a live stream that
    /// is not there, and reporting a failure would blame the user for
    /// closing it.
    func testStopObservingReturnsToUnknown() {
        let adapter = SystemMediaAdapter()
        adapter.ingest([dataLine()])
        XCTAssertEqual(adapter.capability, .ok)
        adapter.stopObserving()
        XCTAssertEqual(adapter.capability, .unknown)
    }

    // MARK: - Failure classification

    func testOnlyRealFailuresAreClassifiedAsSuch() {
        XCTAssertFalse(SystemMediaAdapter.Capability.unknown.isFailure)
        XCTAssertFalse(SystemMediaAdapter.Capability.ok.isFailure)
        XCTAssertTrue(SystemMediaAdapter.Capability.perlUnavailable("x").isFailure)
        XCTAssertTrue(SystemMediaAdapter.Capability.bundleComponentMissing("x").isFailure)
        XCTAssertTrue(SystemMediaAdapter.Capability.launchFailed("x").isFailure)
        XCTAssertTrue(
            SystemMediaAdapter.Capability.exited(status: 1, crashed: false, stderr: nil).isFailure)
    }
}

/// The stderr side, which previously did not exist: both spawn sites routed
/// the child's own account of its failure to `/dev/null`.
final class StderrCollectorTests: XCTestCase {

    func testEmptyCollectorReadsAsNothingSaid() {
        XCTAssertNil(StderrCollector().text)
    }

    func testWhitespaceOnlyOutputReadsAsNothingSaid() {
        let collector = StderrCollector()
        collector.append(Data("\n  \n".utf8))
        XCTAssertNil(collector.text, "blank output is silence, not a diagnostic")
    }

    func testKeepsWhatTheChildWrote() {
        let collector = StderrCollector()
        collector.append(Data("Invalid function name".utf8))
        XCTAssertEqual(collector.text, "Invalid function name")
    }

    func testAssemblesAcrossChunkBoundaries() {
        let collector = StderrCollector()
        collector.append(Data("Invalid ".utf8))
        collector.append(Data("function name".utf8))
        XCTAssertEqual(collector.text, "Invalid function name")
    }

    /// The cap is on what is *retained*. A tool failing in a loop can write
    /// without bound, and this lives on an adapter that runs for days.
    func testRetentionIsCapped() {
        let collector = StderrCollector()
        collector.append(Data(String(repeating: "e", count: StderrCollector.limit * 4).utf8))
        XCTAssertEqual(collector.text?.count, StderrCollector.limit)
    }

    /// Writes past the cap are accepted and dropped rather than rejected —
    /// the caller keeps draining the pipe either way, which is what stops the
    /// child blocking on a full buffer.
    func testWritesPastTheCapAreDroppedNotAccumulated() {
        let collector = StderrCollector()
        for _ in 0..<10 {
            collector.append(Data(String(repeating: "e", count: StderrCollector.limit).utf8))
        }
        XCTAssertEqual(collector.text?.count, StderrCollector.limit)
    }

    /// The first bytes are the ones kept: a perl error states itself on line
    /// one and then unwinds.
    func testKeepsTheHeadNotTheTail() {
        let collector = StderrCollector()
        collector.append(Data("FIRST".utf8))
        collector.append(Data(String(repeating: "x", count: StderrCollector.limit * 2).utf8))
        XCTAssertEqual(collector.text?.hasPrefix("FIRST"), true)
    }
}
