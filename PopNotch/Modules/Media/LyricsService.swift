import Foundation
import os

/// Resolves time-synced lyrics for the current track.
///
/// Order, cheapest first:
/// 1. **The player's own lyrics.** Music.app exposes a read-write `lyrics`
///    property per track. Free, offline, and often what the user embedded
///    themselves. Usually plain text though, so it only counts when it
///    actually parses as timed LRC.
/// 2. **LRCLIB `/api/get`.** Exact-ish lookup by artist, title and duration.
/// 3. **LRCLIB `/api/search`**, when the above 404s. This is what covers
///    titles that differ by a `feat.` or `- Remastered 2011` suffix: search
///    is fuzzy on the name, and the right record is then picked by duration.
///
/// No API key and no account — LRCLIB requires neither, which is why hard
/// rule 6 pre-approves it. Nothing identifying the user is ever sent; the
/// query carries song metadata only.
///
/// Endpoint behaviour below was measured against the live API on
/// 2026-08-28, not taken from documentation:
/// - `/api/get` already applies its own duration tolerance server-side — a
///   request 6s off still matched, 16s off returned 404 — so the client does
///   not need to widen it for this path.
/// - A miss is `404` with a `TrackNotFound` body, not an empty `200`.
/// - `/api/search` returns a bare JSON array, each element carrying
///   `duration`, `syncedLyrics`, `plainLyrics` and `instrumental`.
@MainActor
final class LyricsService {

    private static let logger = Logger(subsystem: "com.techie.PopNotch", category: "Lyrics")

    /// How far a search result's duration may sit from the track's before it
    /// is rejected. Two seconds: enough to absorb the difference between a
    /// player's reported length and a contributor's, tight enough that a
    /// different edit of the same song does not match.
    static let durationTolerance: TimeInterval = 2

    /// What one lookup concluded. The distinction that matters is between
    /// the two kinds of "nothing": a definitive miss is cached so it is never
    /// asked again, a transient failure is not, so the next play retries.
    nonisolated enum Outcome: Equatable {
        case found([LyricsLine])
        /// LRCLIB answered and there is nothing usable: a 404, an
        /// instrumental, untimed text only, or no search result in tolerance.
        case definitiveMiss
        /// LRCLIB did not really answer: no network, a timeout, a 429, a
        /// 5xx, or a body that would not decode.
        case transientFailure

        var lines: [LyricsLine]? {
            if case .found(let lines) = self { return lines }
            return nil
        }

        /// Hits and definitive misses only. Caching a transient failure is
        /// the bug this type exists to prevent: one offline track change
        /// used to write "no lyrics" to disk for that track forever.
        var isCacheable: Bool { self != .transientFailure }
    }

    /// An HTTP exchange reduced to the three things a lookup acts on.
    nonisolated enum Response: Equatable {
        case ok(Data)
        case notFound
        case transient
    }

    /// Bounded: the app runs for days, and one entry per distinct track
    /// played would otherwise grow without limit.
    static let memoryCapacity = 200

    /// In-memory layer over the disk cache, so a track already resolved this
    /// run costs nothing at all. nil value = known miss.
    private var memory = LyricsMemoryCache(capacity: LyricsService.memoryCapacity)
    /// Every caller waiting on a lookup, by key. A second request for a key
    /// already in flight joins it rather than being dropped: the drop never
    /// called its completion, which left `lyricsReserved` stuck on.
    private var pending: [String: [([LyricsLine]?) -> Void]] = [:]
    private let disk = LyricsDiskCache()

    /// Cache identity: artist, title and duration. Duration is part of the
    /// key because it is what distinguishes a radio edit from an album cut
    /// when the title cannot.
    nonisolated static func cacheKey(artist: String, title: String, duration: TimeInterval?) -> String {
        let seconds = duration.map { String(Int($0.rounded())) } ?? "?"
        return "\(artist.lowercased())|\(title.lowercased())|\(seconds)"
    }

    /// - Parameter embeddedLRC: reads the player's own lyrics text, when it
    ///   has any. A closure, called only once both caches have missed and no
    ///   lookup is already in flight: for Music it is a synchronous Apple
    ///   Event, which a cached track should never pay for. Used only if the
    ///   text parses as timed.
    func fetch(
        artist: String,
        title: String,
        duration: TimeInterval?,
        embeddedLRC: (() -> String?)? = nil,
        completion: @escaping ([LyricsLine]?) -> Void
    ) {
        let key = Self.cacheKey(artist: artist, title: title, duration: duration)

        if let cached = memory.lookup(key) {
            Self.logger.notice("Cache hit (memory) for \(key, privacy: .public)")
            completion(cached)
            return
        }
        if let cached = disk.read(key: key) {
            Self.logger.notice("Cache hit (disk) for \(key, privacy: .public)")
            memory.insert(cached.lines, for: key)
            completion(cached.lines)
            return
        }
        if pending[key] != nil {
            // Joins the lookup already running; answered when it lands.
            pending[key]?.append(completion)
            return
        }

        // 1. The player's own lyrics, before any network call.
        if let embedded = embeddedLRC?(), !embedded.isEmpty {
            let parsed = LyricsParser.parse(lrc: embedded)
            if !parsed.isEmpty {
                Self.logger.notice("Using player-embedded lyrics for \(title, privacy: .public): \(parsed.count) lines")
                store(.found(parsed), key: key)
                completion(parsed)
                return
            }
            Self.logger.notice("Player lyrics for \(title, privacy: .public) are plain text, not timed; falling through to LRCLIB")
        }

        pending[key] = [completion]
        Task { [weak self] in
            let outcome = await Self.lookUp(artist: artist, title: title, duration: duration)
            guard let self else { return }
            let waiting = self.pending.removeValue(forKey: key) ?? []
            self.store(outcome, key: key)
            let summary: String
            switch outcome {
            case .found(let lines): summary = "\(lines.count) lines"
            case .definitiveMiss: summary = "no match (cached)"
            case .transientFailure: summary = "lookup failed; not cached, retried next play"
            }
            Self.logger.notice("LRCLIB for \(title, privacy: .public): \(summary, privacy: .public)")
            for completion in waiting { completion(outcome.lines) }
        }
    }

    /// Hits and definitive misses are cached; a definitive miss is cached
    /// because re-querying a track known to have no synced lyrics costs a
    /// round trip every track change for no possible gain. A transient
    /// failure is not cached at all.
    private func store(_ outcome: Outcome, key: String) {
        guard outcome.isCacheable else { return }
        memory.insert(outcome.lines, for: key)
        disk.write(outcome.lines, key: key)
        pruneDiskIfDue()
    }

    /// Writes since the disk cache was last pruned. Starts due, so the first
    /// write of a run prunes, and again every `pruneEvery` writes after.
    private var writesSincePrune = LyricsService.pruneEvery
    private static let pruneEvery = 100

    /// Bounds the disk cache, off the main actor: listing a directory of a
    /// thousand files is not main-thread work. Runs only after a write, so
    /// nothing touches the directory while nothing new is being cached.
    private func pruneDiskIfDue() {
        writesSincePrune += 1
        guard writesSincePrune >= Self.pruneEvery else { return }
        writesSincePrune = 0
        let disk = self.disk
        let limit = LyricsDiskCache.maxEntries
        Task.detached(priority: .background) {
            disk.prune(keeping: limit)
        }
    }

    // MARK: - Decisions (pure, for tests)

    /// Maps an HTTP exchange. `status` nil means no response at all — a
    /// network error or timeout. Only 200 and 404 are answers; everything
    /// else (429, 5xx, a surprise 3xx) is LRCLIB not answering right now.
    nonisolated static func classify(status: Int?, data: Data?) -> Response {
        switch status {
        case 200: return data.map(Response.ok) ?? .transient
        case 404: return .notFound
        default: return .transient
        }
    }

    /// Combines the exact lookup and the search fallback. A hit from either
    /// wins. Otherwise, if either step failed transiently the answer is
    /// unknown — the step that failed might have matched — so the whole
    /// lookup is transient. Only two real answers make a definitive miss.
    /// `search` is nil when it was not needed (the exact lookup hit).
    nonisolated static func combine(get: Outcome, search: Outcome?) -> Outcome {
        if case .found = get { return get }
        if let search, case .found = search { return search }
        if get == .transientFailure || search == .transientFailure { return .transientFailure }
        return .definitiveMiss
    }

    // MARK: - Network

    private static func lookUp(
        artist: String, title: String, duration: TimeInterval?
    ) async -> Outcome {
        let exact = await get(artist: artist, title: title, duration: duration)
        if case .found = exact { return exact }
        let fuzzy = await search(artist: artist, title: title, duration: duration)
        return combine(get: exact, search: fuzzy)
    }

    private struct GetResponse: Decodable {
        let syncedLyrics: String?
        let instrumental: Bool?
    }

    private struct SearchResult: Decodable {
        let syncedLyrics: String?
        let instrumental: Bool?
        let duration: Double?
    }

    private static func get(
        artist: String, title: String, duration: TimeInterval?
    ) async -> Outcome {
        var items = [
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "track_name", value: title),
        ]
        if let duration {
            items.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded()))))
        }
        let data: Data
        switch await request(path: "/api/get", items: items) {
        case .ok(let body): data = body
        case .notFound: return .definitiveMiss
        case .transient: return .transientFailure
        }
        guard let decoded = try? JSONDecoder().decode(GetResponse.self, from: data) else {
            logger.notice("LRCLIB /api/get returned an undecodable body; treated as transient")
            return .transientFailure
        }

        guard decoded.instrumental != true else {
            logger.notice("\(title, privacy: .public) is marked instrumental")
            return .definitiveMiss
        }
        return timed(decoded.syncedLyrics, context: "get")
    }

    /// Fallback for titles that differ by a suffix the exact lookup cannot
    /// forgive — `(feat. …)`, `- Remastered`, and similar. Search is loose on
    /// the name, so duration does the disambiguating.
    private static func search(
        artist: String, title: String, duration: TimeInterval?
    ) async -> Outcome {
        // Checked before the request: without a duration no result can ever
        // be picked, so this is a definitive miss, not worth a round trip.
        guard let duration else {
            logger.notice("Search for \(title, privacy: .public) skipped: no duration to match on")
            return .definitiveMiss
        }
        let items = [
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "track_name", value: title),
        ]
        let data: Data
        switch await request(path: "/api/search", items: items) {
        case .ok(let body): data = body
        // Search answers an empty array rather than 404; a 404 here is
        // still LRCLIB saying "nothing", so it counts as an answer.
        case .notFound: return .definitiveMiss
        case .transient: return .transientFailure
        }
        guard let results = try? JSONDecoder().decode([SearchResult].self, from: data) else {
            logger.notice("LRCLIB /api/search returned an undecodable body; treated as transient")
            return .transientFailure
        }
        // Closest duration inside the tolerance, among results that actually
        // carry synced lyrics. A plain-text-only record is not a match.
        let best = results
            .filter { $0.instrumental != true && $0.syncedLyrics?.isEmpty == false }
            .compactMap { result -> (SearchResult, TimeInterval)? in
                guard let d = result.duration else { return nil }
                let delta = abs(d - duration)
                return delta <= durationTolerance ? (result, delta) : nil
            }
            .min { $0.1 < $1.1 }

        guard let best else {
            logger.notice("Search for \(title, privacy: .public): \(results.count) results, none within \(Int(durationTolerance))s")
            return .definitiveMiss
        }
        logger.notice("Search matched \(title, privacy: .public) at \(best.1, format: .fixed(precision: 1), privacy: .public)s off")
        return timed(best.0.syncedLyrics, context: "search")
    }

    /// Synced lyrics only. A record with nothing but `plainLyrics` is a miss,
    /// not a partial success — the notch has no way to show untimed text.
    private static func timed(_ lrc: String?, context: String) -> Outcome {
        guard let lrc, !lrc.isEmpty else { return .definitiveMiss }
        let parsed = LyricsParser.parse(lrc: lrc)
        if parsed.isEmpty {
            logger.notice("LRCLIB \(context, privacy: .public) returned untimed text only")
            return .definitiveMiss
        }
        return .found(parsed)
    }

    private static func request(path: String, items: [URLQueryItem]) async -> Response {
        var components = URLComponents(string: "https://lrclib.net\(path)")
        components?.queryItems = items
        guard let url = components?.url else { return .transient }

        var request = URLRequest(url: url)
        // LRCLIB asks callers to identify themselves. No key, no account.
        request.setValue("PopNotch/0.1 (https://github.com/techie/PopNotch)",
                         forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await URLSession.shared.data(for: request) else {
            logger.notice("LRCLIB \(path, privacy: .public) failed: network error (transient)")
            return classify(status: nil, data: nil)
        }
        let status = (response as? HTTPURLResponse)?.statusCode
        let result = classify(status: status, data: data)
        // 404 is the ordinary "no such track" answer, not a fault.
        if result == .transient {
            logger.notice("LRCLIB \(path, privacy: .public) -> \(status ?? 0, privacy: .public) (transient)")
        }
        return result
    }
}

/// The in-memory lyrics cache: a small LRU over cache keys.
///
/// The value is `[LyricsLine]?`, where nil is a cached definitive miss, so
/// `lookup` returns a double optional: `.none` for "not cached", `.some(nil)`
/// for "cached: no lyrics". Recency is a plain array of keys — at 200
/// entries a linear move costs less than any cleverer structure, and it
/// runs once per track change.
struct LyricsMemoryCache {
    let capacity: Int
    private var values: [String: [LyricsLine]?] = [:]
    /// Least recently used first.
    private var order: [String] = []

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    var count: Int { values.count }

    /// Marks the key as just used.
    mutating func lookup(_ key: String) -> [LyricsLine]?? {
        guard let value = values[key] else { return nil }
        touch(key)
        return .some(value)
    }

    mutating func insert(_ lines: [LyricsLine]?, for key: String) {
        values[key] = .some(lines)
        touch(key)
        while order.count > capacity {
            let evicted = order.removeFirst()
            values.removeValue(forKey: evicted)
        }
    }

    private mutating func touch(_ key: String) {
        if let index = order.firstIndex(of: key) { order.remove(at: index) }
        order.append(key)
    }
}

/// Lyrics survive relaunch on disk, so a track resolved once is never queried
/// again — including tracks that resolved to nothing.
///
/// One small JSON file per track under Application Support. A single index
/// file would have to be rewritten on every miss; per-track files make a
/// write O(1) and a corrupt entry cost exactly one track.
struct LyricsDiskCache {

    private static let logger = Logger(subsystem: "com.techie.PopNotch", category: "Lyrics")

    struct Entry: Codable {
        let key: String
        /// nil = resolved to no synced lyrics. Cached so it is never retried.
        let lines: [LyricsLine]?
    }

    /// At most this many tracks on disk. Each file is a few KB, so this caps
    /// the cache at a few MB however long the app is used.
    static let maxEntries = 1000

    /// Files beyond `keeping`, oldest written first. Pure, for tests.
    nonisolated static func filesToPrune(_ files: [(url: URL, modified: Date)],
                                         keeping: Int) -> [URL] {
        guard files.count > keeping else { return [] }
        return files
            .sorted { $0.modified < $1.modified }
            .prefix(files.count - max(0, keeping))
            .map(\.url)
    }

    /// Deletes the oldest entries beyond `keeping`. Filesystem only, so it
    /// runs off the main actor (see `LyricsService.store`).
    nonisolated func prune(keeping: Int) {
        guard let directory = Self.directoryURL,
              let urls = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        let files = urls
            .filter { $0.pathExtension == "json" }
            .map { url -> (url: URL, modified: Date) in
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return (url, date)
            }
        let doomed = Self.filesToPrune(files, keeping: keeping)
        guard !doomed.isEmpty else { return }
        for url in doomed { try? FileManager.default.removeItem(at: url) }
        Logger(subsystem: "com.techie.PopNotch", category: "Lyrics")
            .notice("Pruned \(doomed.count, privacy: .public) oldest lyrics cache entries")
    }

    private var directory: URL? { Self.directoryURL }

    private nonisolated static var directoryURL: URL? {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return nil }
        return base.appendingPathComponent("PopNotch/Lyrics", isDirectory: true)
    }

    /// FNV-1a. Swift's own `hashValue` is seeded per process, so it would
    /// produce a different filename on every launch and the cache would never
    /// hit — the exact bug this avoids.
    static func filename(for key: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx.json", hash)
    }

    func read(key: String) -> Entry? {
        guard let url = directory?.appendingPathComponent(Self.filename(for: key)),
              let data = try? Data(contentsOf: url),
              let entry = try? JSONDecoder().decode(Entry.self, from: data)
        else { return nil }
        // Guard against an FNV collision handing back another track's lyrics.
        guard entry.key == key else {
            Self.logger.notice("Cache filename collision for \(key, privacy: .public); ignoring")
            return nil
        }
        return entry
    }

    func write(_ lines: [LyricsLine]?, key: String) {
        guard let directory else { return }
        let entry = Entry(key: key, lines: lines)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(entry)
                .write(to: directory.appendingPathComponent(Self.filename(for: key)))
        } catch {
            // A cache that cannot write is slow, not broken.
            Self.logger.notice("Cache write failed for \(key, privacy: .public)")
        }
    }
}
