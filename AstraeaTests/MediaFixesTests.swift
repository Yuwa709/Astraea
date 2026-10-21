import XCTest
import CoreAudio
@testable import Astraea

/// A source that records its lifecycle, for the enable/disable tests.
@MainActor
private final class LifecycleSource: MediaSource {
    let sourceID: String
    var isPlayerRunning = true
    var permissionDenied = false
    var onUpdate: ((NowPlaying?) -> Void)?
    var bundleID: String?

    private(set) var starts = 0
    private(set) var stops = 0
    private(set) var refreshes = 0
    private(set) var embeddedReads = 0

    init(id: String, bundleID: String? = nil) {
        sourceID = id
        self.bundleID = bundleID
    }

    func startObserving() { starts += 1 }
    func stopObserving() { stops += 1 }
    func refresh() { refreshes += 1 }
    func send(_ command: MediaCommand) {}
    func seek(to seconds: TimeInterval) {}
    func embeddedLyrics() -> String? {
        embeddedReads += 1
        return nil
    }

    func publish(_ snapshot: NowPlaying?) { onUpdate?(snapshot) }
}

@MainActor
final class MediaFixesTests: XCTestCase {

    private func track(_ title: String = "Song", playing: Bool = true,
                       duration: TimeInterval? = 200, bundleID: String? = nil) -> NowPlaying {
        var snapshot = NowPlaying()
        snapshot.title = title
        // No artist: the lyrics lookup short-circuits, so no test here
        // reaches LRCLIB or the disk cache.
        snapshot.duration = duration
        snapshot.elapsed = 0
        snapshot.isPlaying = playing
        snapshot.sourceBundleID = bundleID
        return snapshot
    }

    // MARK: - 1. Disabling Media stops the sources

    func testInitStartsNoSource() {
        let source = LifecycleSource(id: "a")
        _ = MediaModule(sources: [source])
        XCTAssertEqual(source.starts, 0, "a module registered disabled must never start observing")
        XCTAssertEqual(source.refreshes, 0)
    }

    func testEnablingStartsAndPullsDisablingStops() {
        let source = LifecycleSource(id: "a")
        let module = MediaModule(sources: [source])
        module.isEnabled = true
        XCTAssertEqual(source.starts, 1)
        XCTAssertEqual(source.refreshes, 1)
        XCTAssertTrue(module.sourcesObserving)

        module.isEnabled = false
        XCTAssertEqual(source.stops, 1)
        XCTAssertFalse(module.sourcesObserving)
    }

    func testRepeatedAssignmentNeitherRestartsNorReStops() {
        let source = LifecycleSource(id: "a")
        let module = MediaModule(sources: [source])
        module.isEnabled = true
        module.isEnabled = true
        XCTAssertEqual(source.starts, 1, "observation started once")
        module.isEnabled = false
        module.isEnabled = false
        XCTAssertEqual(source.stops, 1, "stopped once")
    }

    func testRegisteringDisabledNeverStartsOrStops() {
        let source = LifecycleSource(id: "a")
        let module = MediaModule(sources: [source])
        module.isEnabled = false
        XCTAssertEqual(source.starts, 0)
        XCTAssertEqual(source.stops, 0, "nothing was running, so nothing to stop")
    }

    func testDisablingClearsWhatWasShowingAndIgnoresLateUpdates() {
        let source = LifecycleSource(id: "a")
        let module = MediaModule(sources: [source])
        module.isEnabled = true
        source.publish(track())
        XCTAssertNotNil(module.nowPlaying)

        module.isEnabled = false
        XCTAssertNil(module.nowPlaying, "disabling clears the notch")
        // A callback already in flight (artwork landing, a re-anchor).
        source.publish(track("Late"))
        XCTAssertNil(module.nowPlaying, "a disabled module ignores updates")

        module.isEnabled = true
        source.publish(track("Back"))
        XCTAssertEqual(module.nowPlaying?.title, "Back")
    }

    // MARK: - 2. AppleScript timeout

    func testEveryScriptIsWrappedInATimeout() {
        let wrapped = AppleScriptRunner.bounded("tell application \"Spotify\" to play")
        XCTAssertTrue(wrapped.hasPrefix("with timeout of \(AppleScriptRunner.timeoutSeconds) seconds\n"))
        XCTAssertTrue(wrapped.hasSuffix("\nend timeout"))
        XCTAssertTrue(wrapped.contains("tell application \"Spotify\" to play"))
    }

    func testTimeoutIsTransientNotADenial() {
        let timeout = AppleScriptRunner.Failure(code: -1712)
        XCTAssertTrue(timeout.isTimeout)
        XCTAssertFalse(timeout.isPermissionDenied)
        let denied = AppleScriptRunner.Failure(code: -1743)
        XCTAssertTrue(denied.isPermissionDenied)
        XCTAssertFalse(denied.isTimeout)
    }

    func testProbeStatusMapping() {
        XCTAssertEqual(AutomationProbe.permission(forStatus: 0), .granted)
        XCTAssertEqual(AutomationProbe.permission(forStatus: -1743), .denied)
        XCTAssertEqual(AutomationProbe.permission(forStatus: -1744), .undetermined,
                       "not yet asked is not a denial")
        XCTAssertEqual(AutomationProbe.permission(forStatus: -1712), .undetermined,
                       "a timeout is not a denial")
        XCTAssertEqual(AutomationProbe.permission(forStatus: -600), .undetermined,
                       "a closed player is not a denial")
    }

    // MARK: - 3. LRCLIB: only real answers are cached

    func testHTTPClassification() {
        let body = Data("[]".utf8)
        XCTAssertEqual(LyricsService.classify(status: 200, data: body), .ok(body))
        XCTAssertEqual(LyricsService.classify(status: 404, data: body), .notFound)
        XCTAssertEqual(LyricsService.classify(status: nil, data: nil), .transient, "network error")
        XCTAssertEqual(LyricsService.classify(status: 429, data: body), .transient, "rate limited")
        XCTAssertEqual(LyricsService.classify(status: 500, data: body), .transient)
        XCTAssertEqual(LyricsService.classify(status: 503, data: body), .transient)
    }

    func testCombineGetAndSearch() {
        let lines = [LyricsLine(time: 1, text: "a")]
        typealias O = LyricsService.Outcome
        XCTAssertEqual(LyricsService.combine(get: .found(lines), search: nil), .found(lines))
        XCTAssertEqual(LyricsService.combine(get: .definitiveMiss, search: .found(lines)), .found(lines))
        XCTAssertEqual(LyricsService.combine(get: .transientFailure, search: .found(lines)), .found(lines))
        XCTAssertEqual(LyricsService.combine(get: .definitiveMiss, search: .definitiveMiss),
                       O.definitiveMiss)
        XCTAssertEqual(LyricsService.combine(get: .transientFailure, search: .definitiveMiss),
                       O.transientFailure, "the exact lookup might have matched")
        XCTAssertEqual(LyricsService.combine(get: .definitiveMiss, search: .transientFailure),
                       O.transientFailure, "the search might have matched")
    }

    func testOnlyHitsAndDefinitiveMissesAreCacheable() {
        XCTAssertTrue(LyricsService.Outcome.found([LyricsLine(time: 0, text: "x")]).isCacheable)
        XCTAssertTrue(LyricsService.Outcome.definitiveMiss.isCacheable)
        XCTAssertFalse(LyricsService.Outcome.transientFailure.isCacheable)
    }

    // MARK: - 11. Bounded lyrics caches

    func testMemoryCacheKeepsMissesDistinctFromAbsent() {
        var cache = LyricsMemoryCache(capacity: 3)
        XCTAssertTrue(cache.lookup("k") == nil, "not cached")
        cache.insert(nil, for: "k")
        guard case .some(let cached) = cache.lookup("k") else {
            return XCTFail("a cached miss is still cached")
        }
        XCTAssertTrue(cached == nil, "and it is a miss")
    }

    func testMemoryCacheEvictsLeastRecentlyUsed() {
        var cache = LyricsMemoryCache(capacity: 2)
        cache.insert([LyricsLine(time: 0, text: "a")], for: "a")
        cache.insert([LyricsLine(time: 0, text: "b")], for: "b")
        _ = cache.lookup("a")                      // a is now most recent
        cache.insert(nil, for: "c")                // evicts b
        XCTAssertEqual(cache.count, 2)
        XCTAssertTrue(cache.lookup("a") != nil)
        XCTAssertTrue(cache.lookup("b") == nil, "least recently used goes first")
        XCTAssertTrue(cache.lookup("c") != nil)
    }

    func testDiskPrunePicksOldestBeyondLimit() {
        let base = Date(timeIntervalSince1970: 0)
        let files = (0..<5).map { i in
            (url: URL(fileURLWithPath: "/tmp/\(i).json"), modified: base.addingTimeInterval(Double(i)))
        }.shuffled()
        let doomed = LyricsDiskCache.filesToPrune(files, keeping: 3)
        XCTAssertEqual(Set(doomed.map(\.lastPathComponent)), ["0.json", "1.json"])
        XCTAssertTrue(LyricsDiskCache.filesToPrune(files, keeping: 5).isEmpty)
    }

    // MARK: - 4. Spectrum stops while the display sleeps

    func testSpectrumConditionIncludesDisplaySleep() {
        let screen = MediaModule.ExpandedScreen.player(track())
        XCTAssertTrue(MediaModule.spectrumShouldCapture(isVisible: true, displayAsleep: false, screen: screen))
        XCTAssertFalse(MediaModule.spectrumShouldCapture(isVisible: true, displayAsleep: true, screen: screen))
        XCTAssertFalse(MediaModule.spectrumShouldCapture(isVisible: false, displayAsleep: false, screen: screen))
    }

    func testDisplaySleepAndWakeDriveTheSpectrum() {
        let visualizer = AudioVisualizerService(makeCapture: { _, _ in FakeAudioCapture() })
        let source = LifecycleSource(id: "a")
        let module = MediaModule(sources: [source], visualizer: visualizer)
        source.publish(track())
        module.didBecomeVisible()
        XCTAssertTrue(visualizer.spectrumVisible)

        module.setDisplayAsleep(true)
        XCTAssertFalse(visualizer.spectrumVisible, "no capture behind a sleeping display")
        XCTAssertFalse(module.isLiveSyncing)

        module.setDisplayAsleep(false)
        XCTAssertTrue(visualizer.spectrumVisible, "wake restores it while still visible")
        module.didResignVisible()
    }

    // MARK: - 5. Artwork opens the playing app

    func testArtworkTargetPrefersTheSourcesOwnApp() {
        XCTAssertEqual(MediaModule.artworkTapTarget(sourceBundleID: "com.apple.Music",
                                                    snapshotBundleID: "com.apple.Music"),
                       "com.apple.Music")
        XCTAssertEqual(MediaModule.artworkTapTarget(sourceBundleID: nil,
                                                    snapshotBundleID: "com.google.Chrome"),
                       "com.google.Chrome", "the system source speaks for the session's app")
        XCTAssertNil(MediaModule.artworkTapTarget(sourceBundleID: nil, snapshotBundleID: nil),
                     "unknown app: the artwork is inert")
    }

    func testMusicTrackDoesNotOpenSpotify() {
        let music = LifecycleSource(id: "music", bundleID: MusicAdapter.bundleID)
        let module = MediaModule(sources: [music])
        music.publish(track(bundleID: MusicAdapter.bundleID))
        XCTAssertEqual(module.artworkTapBundleID, MusicAdapter.bundleID)
    }

    // MARK: - 6. Spotify artwork belongs to the track it was fetched for

    func testArtworkDownloadAttachesOnlyToItsOwnTrack() {
        var current = NowPlaying()
        current.artworkURL = "https://i.scdn.co/image/new"
        XCTAssertTrue(SpotifyAdapter.artworkStillCurrent(
            downloadedFrom: "https://i.scdn.co/image/new", current: current))
        XCTAssertFalse(SpotifyAdapter.artworkStillCurrent(
            downloadedFrom: "https://i.scdn.co/image/old", current: current),
            "a slow download for the previous track must not land on this one")
        current.artworkURL = nil // a notification for a new track, pull pending
        XCTAssertFalse(SpotifyAdapter.artworkStillCurrent(
            downloadedFrom: "https://i.scdn.co/image/old", current: current))
        XCTAssertFalse(SpotifyAdapter.artworkStillCurrent(
            downloadedFrom: "https://i.scdn.co/image/old", current: nil))
    }

    // MARK: - 7. A quitting Music is never Apple-Evented

    func testStoppedPlayerInfoSkipsThePull() {
        XCTAssertFalse(MusicAdapter.shouldPull(afterPlayerState: "Stopped"))
        XCTAssertTrue(MusicAdapter.shouldPull(afterPlayerState: "Playing"))
        XCTAssertTrue(MusicAdapter.shouldPull(afterPlayerState: "Paused"))
        XCTAssertTrue(MusicAdapter.shouldPull(afterPlayerState: nil),
                      "an unrecognised payload still pulls")
    }

    func testStoppedNotificationSendsNoAppleEvent() {
        var scripts = 0
        let adapter = MusicAdapter(
            runScript: { _ in scripts += 1; return .failure(.init(code: 0)) },
            playerRunning: { true })
        var published: [NowPlaying?] = []
        adapter.onUpdate = { published.append($0) }

        adapter.handlePlayerInfo(playerState: "Stopped")
        XCTAssertEqual(scripts, 0, "no tell application to a quitting Music")
        XCTAssertEqual(published.count, 1)
        XCTAssertNil(published.first ?? NowPlaying(), "the notch clears")

        adapter.handlePlayerInfo(playerState: "Playing")
        XCTAssertEqual(scripts, 1, "a live state still pulls")
    }

    // MARK: - 8. Recovery paths

    func testDeniedRetryBacksOffAndResets() {
        var backoff = PullRetryBackoff()
        XCTAssertTrue(backoff.allows(at: 0), "never denied: no wait")
        backoff.recordFailure(at: 100)
        XCTAssertFalse(backoff.allows(at: 129))
        XCTAssertTrue(backoff.allows(at: 130), "first wait is the base")
        backoff.recordFailure(at: 130)
        XCTAssertFalse(backoff.allows(at: 189))
        XCTAssertTrue(backoff.allows(at: 190), "then doubles")
        for _ in 0..<10 { backoff.recordFailure(at: 1000) }
        XCTAssertEqual(backoff.currentDelay, PullRetryBackoff.cap, "capped")
        backoff.reset()
        XCTAssertTrue(backoff.allows(at: 0))
    }

    func testStreamRestartIsBounded() {
        var backoff = StreamRestartBackoff()
        var delays: [TimeInterval] = []
        while let delay = backoff.nextDelay(afterLifetime: 0.5) { delays.append(delay) }
        XCTAssertEqual(delays, StreamRestartBackoff.delays, "growing, then gives up")
        XCTAssertNil(backoff.nextDelay(afterLifetime: 0.5), "no tight loop")

        backoff.reset() // wake or re-enable
        XCTAssertEqual(backoff.nextDelay(afterLifetime: 0.5), StreamRestartBackoff.delays.first)
    }

    func testAHealthyStreamEarnsAFreshBudget() {
        var backoff = StreamRestartBackoff()
        while backoff.nextDelay(afterLifetime: 0) != nil {}
        XCTAssertEqual(backoff.nextDelay(afterLifetime: StreamRestartBackoff.healthyLifetime),
                       StreamRestartBackoff.delays.first,
                       "an occasional crash after a long run is not a launch failure")
    }

    // MARK: - 13. Spotify modes script

    func testModesScriptUsesTheAppleScriptEscape() {
        let source = SpotifyAdapter.modesScriptSource
        XCTAssertTrue(source.contains("& \"\\n\" &"),
                      "the separator is AppleScript's \\n escape, like every other script")
        XCTAssertFalse(source.contains("& \"\n\" &"), "never a raw linefeed inside the literal")
    }

    func testParseModesStillParses() {
        let parsed = SpotifyAdapter.parseModes("true\nfalse")
        XCTAssertEqual(parsed?.shuffling, true)
        XCTAssertEqual(parsed?.repeating, false)
        XCTAssertNil(SpotifyAdapter.parseModes("true"))
        XCTAssertNil(SpotifyAdapter.parseModes("yes\nno"))
    }

    // MARK: - 14. Visualiser mixdown and mailbox

    private func withBufferList(_ buffers: [(channels: UInt32, samples: [Float])],
                                _ body: (UnsafeMutableAudioBufferListPointer) -> Void) {
        let list = AudioBufferList.allocate(maximumBuffers: buffers.count)
        var storage: [UnsafeMutablePointer<Float>] = []
        for (index, buffer) in buffers.enumerated() {
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: buffer.samples.count)
            pointer.initialize(from: buffer.samples, count: buffer.samples.count)
            storage.append(pointer)
            list[index] = AudioBuffer(
                mNumberChannels: buffer.channels,
                mDataByteSize: UInt32(buffer.samples.count * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(pointer))
        }
        body(list)
        storage.forEach { $0.deallocate() }
        free(list.unsafeMutablePointer)
    }

    func testInterleavedStereoMixesToMonoFrames() {
        // L R L R L R: three frames, not six samples.
        withBufferList([(2, [1, 3, -1, 1, 0.5, 0.5])]) { list in
            var out = [Float](repeating: 99, count: 8)
            let frames = out.withUnsafeMutableBufferPointer { buffer -> Int in
                guard let base = buffer.baseAddress else { return 0 }
                return MonoMixdown.mix(list, into: base, capacity: buffer.count)
            }
            XCTAssertEqual(frames, 3)
            XCTAssertEqual(Array(out.prefix(3)), [2, 0, 0.5])
        }
    }

    func testNonInterleavedChannelsMixToMono() {
        withBufferList([(1, [1, 2, 3]), (1, [3, 2, 1])]) { list in
            var out = [Float](repeating: 0, count: 3)
            let frames = out.withUnsafeMutableBufferPointer { buffer -> Int in
                guard let base = buffer.baseAddress else { return 0 }
                return MonoMixdown.mix(list, into: base, capacity: buffer.count)
            }
            XCTAssertEqual(frames, 3)
            XCTAssertEqual(out, [2, 2, 2])
        }
    }

    func testMonoPassesThroughAndCapacityBounds() {
        withBufferList([(1, [1, 2, 3, 4])]) { list in
            var out = [Float](repeating: 0, count: 2)
            let frames = out.withUnsafeMutableBufferPointer { buffer -> Int in
                guard let base = buffer.baseAddress else { return 0 }
                return MonoMixdown.mix(list, into: base, capacity: buffer.count)
            }
            XCTAssertEqual(frames, 2, "never writes past the slot")
            XCTAssertEqual(out, [1, 2])
        }
    }

    func testMailboxDeliversInOrderAndDropsOldestWhenFull() {
        let mailbox = SampleMailbox(slotCapacity: 4, slotCount: 2)
        XCTAssertNil(mailbox.read())
        for value: Float in [1, 2, 3] {
            withBufferList([(1, [value, value])]) { list in
                XCTAssertTrue(mailbox.write(list))
            }
        }
        XCTAssertEqual(mailbox.read(), [2, 2], "the oldest was overwritten")
        XCTAssertEqual(mailbox.read(), [3, 3])
        XCTAssertNil(mailbox.read())
    }

    // MARK: - 15. Analysis independent of the hardware buffer size

    /// `frames` interleaved stereo frames of a sine, starting at `offset`.
    private func stereoSine(frames: Int, offset: Int = 0) -> [Float] {
        (0..<frames).flatMap { i -> [Float] in
            let value = sinf(Float(offset + i) * 0.05)
            return [value, value]
        }
    }

    /// One stereo buffer through the real path: mailbox mixdown, read, then
    /// the accumulator and the analyser, as `drainMailbox` does.
    private func feed(_ interleaved: [Float], mailbox: SampleMailbox,
                      accumulator: inout SampleAccumulator,
                      analyzer: AudioAnalyzer) -> [Float]? {
        var bands: [Float]?
        withBufferList([(2, interleaved)]) { list in
            XCTAssertTrue(mailbox.write(list))
        }
        while let samples = mailbox.read() {
            guard let window = accumulator.append(samples) else { continue }
            bands = analyzer.bands(from: window)
        }
        return bands
    }

    func test512FrameStereoBuffersProduceBandsEverySecondBuffer() {
        let mailbox = SampleMailbox(slotCapacity: SampleMailbox.defaultSlotCapacity,
                                    slotCount: SampleMailbox.defaultSlotCount)
        var accumulator = SampleAccumulator(windowSize: AudioAnalyzer.fftSize)
        let analyzer = AudioAnalyzer()
        // The old symptom: one 512-frame buffer alone is below the window.
        XCTAssertNil(analyzer.bands(from: [Float](repeating: 0.1, count: 512)))

        XCTAssertNil(feed(stereoSine(frames: 512), mailbox: mailbox,
                          accumulator: &accumulator, analyzer: analyzer),
                     "half a window: nothing yet")
        let second = feed(stereoSine(frames: 512, offset: 512), mailbox: mailbox,
                          accumulator: &accumulator, analyzer: analyzer)
        XCTAssertEqual(second?.count, AudioVisualizerService.bandCount,
                       "two 512-frame buffers make one window")
        XCTAssertNil(feed(stereoSine(frames: 512, offset: 1024), mailbox: mailbox,
                          accumulator: &accumulator, analyzer: analyzer),
                     "no overlapping FFT: the rate stays one per window of audio")
        XCTAssertNotNil(feed(stereoSine(frames: 512, offset: 1536), mailbox: mailbox,
                             accumulator: &accumulator, analyzer: analyzer))
    }

    func testFullWindowBuffersStillProduceBandsEveryBuffer() {
        let mailbox = SampleMailbox(slotCapacity: SampleMailbox.defaultSlotCapacity,
                                    slotCount: SampleMailbox.defaultSlotCount)
        var accumulator = SampleAccumulator(windowSize: AudioAnalyzer.fftSize)
        let analyzer = AudioAnalyzer()
        for (index, frames) in [1024, 1024, 2048, 1024].enumerated() {
            XCTAssertNotNil(feed(stereoSine(frames: frames, offset: index * 2048), mailbox: mailbox,
                                 accumulator: &accumulator, analyzer: analyzer),
                            "buffer \(index) of \(frames) frames analyses at once")
        }
    }

    func testAccumulatorWindowIsTheMostRecentSamplesInOrder() {
        var accumulator = SampleAccumulator(windowSize: 4)
        XCTAssertNil(accumulator.append([1, 2]))
        XCTAssertNil(accumulator.append([]), "an empty buffer changes nothing")
        XCTAssertEqual(accumulator.append([3, 4]), [1, 2, 3, 4])
        XCTAssertNil(accumulator.append([5]))
        XCTAssertNil(accumulator.append([6, 7]))
        XCTAssertEqual(accumulator.append([8]), [5, 6, 7, 8])
        XCTAssertEqual(accumulator.append([9, 10, 11, 12, 13, 14]), [11, 12, 13, 14],
                       "a buffer larger than the window keeps its newest samples")
        XCTAssertEqual(accumulator.pending, 0)
    }
}
