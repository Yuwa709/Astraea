import Foundation

// The resource page's pure half: what an app is, how processes are grouped
// under one, how CPU time becomes a percentage, and how the list is ranked.
// No AppKit, no libproc — `ResourceProcessReader` reads, `ResourceUsageService`
// schedules, and everything here is a test.

/// What the resource page ranks by.
/// In the order the segmented control shows them, energy first.
nonisolated enum ResourceMetric: String, CaseIterable, Hashable, Sendable {
    case energy, memory, cpu

    /// The line beside the segmented control.
    var sortDescription: String {
        switch self {
        case .energy: "Sorted by energy use"
        case .memory: "Sorted by memory footprint"
        case .cpu: "Sorted by CPU usage"
        }
    }

    /// Energy and CPU are rates, so they need two samples to diff.
    var needsTwoSamples: Bool { self != .memory }
}

/// A running app as AppKit reports it, captured on the main actor and
/// handed to the sampler as plain data.
nonisolated struct ResourceApp: Sendable, Equatable, Hashable {
    let pid: pid_t
    let bundleID: String?
    let name: String
    /// The app's `.app` bundle, standardized. Nil for a bundle-less app.
    let bundlePath: String?
    /// False for Astraea itself and the system's own shell apps.
    let canQuit: Bool
}

/// One process, read once.
nonisolated struct ResourceProcess: Sendable, Equatable {
    let pid: pid_t
    /// 0 when libproc would not say.
    let parent: pid_t
    /// When the process started, in Mach absolute time. With the PID, this
    /// is the process's identity: a reused PID has a later start.
    let start: UInt64
    /// User plus system CPU time since the process started, nanoseconds.
    let cpuTime: UInt64
    /// Physical footprint, bytes: what Activity Monitor's Memory column shows.
    let footprint: UInt64
    /// Energy the kernel has billed to the process since it started,
    /// nanojoules (`ri_energy_nj`): its CPU cores' energy, per the
    /// performance controller's model.
    var energy: UInt64 = 0
    /// The outermost `.app` around the executable, if any.
    let appPath: String?
}

/// One row of the page: an app and everything it runs.
nonisolated struct ResourceAppUsage: Identifiable, Equatable, Sendable {
    var id: pid_t { app.pid }
    let app: ResourceApp
    /// Percent of one core, so a busy multi-threaded app exceeds 100, as in
    /// Activity Monitor. Nil until two samples exist to diff.
    var cpuPercent: Double?
    /// Average power over the last interval, watts. Nil until two samples.
    var watts: Double? = nil
    /// Summed physical footprint of the app's processes.
    var memoryBytes: UInt64
    /// How many processes were summed into this row.
    var processCount: Int
}

// MARK: - Attribution

/// Which app each process belongs to.
///
/// Only relationships the system states are used, never names: a process
/// belongs to an app when it *is* the app, when its executable sits inside
/// that app's bundle (Chromium and Electron helpers, bundled XPC services),
/// or when an ancestor in the parent chain is the app (a terminal's shells
/// and what they run). Anything else — launchd's daemons, WebKit's shared
/// XPC services whose parent is launchd — is left out rather than guessed
/// at: the responsible-process API that would name Safari for its web
/// content is private.
nonisolated enum ResourceAttribution {

    /// Deeper than any real launcher chain; stops a cycle in a racy read.
    static let maxAncestors = 16

    /// Process PID to owning app PID, for every process that has one.
    static func owners(processes: [ResourceProcess], apps: [ResourceApp]) -> [pid_t: pid_t] {
        let appPIDs = Set(apps.map(\.pid))
        // A bundle path names an app only when exactly one running app has
        // it; two instances of one app leave the helpers to the parent chain.
        var byPath: [String: pid_t] = [:]
        var duplicatePaths: Set<String> = []
        for app in apps {
            guard let path = app.bundlePath else { continue }
            if byPath[path] != nil { duplicatePaths.insert(path) }
            byPath[path] = app.pid
        }
        duplicatePaths.forEach { byPath[$0] = nil }
        let parents = Dictionary(processes.map { ($0.pid, $0.parent) }, uniquingKeysWith: { a, _ in a })

        var result: [pid_t: pid_t] = [:]
        for process in processes {
            if appPIDs.contains(process.pid) {
                result[process.pid] = process.pid
            } else if let path = process.appPath, let owner = byPath[path] {
                result[process.pid] = owner
            } else if let owner = ancestorApp(of: process.pid, parents: parents, apps: appPIDs) {
                result[process.pid] = owner
            }
        }
        return result
    }

    private static func ancestorApp(of pid: pid_t, parents: [pid_t: pid_t], apps: Set<pid_t>) -> pid_t? {
        var current = pid
        for _ in 0..<maxAncestors {
            guard let parent = parents[current], parent > 1, parent != current else { return nil }
            if apps.contains(parent) { return parent }
            current = parent
        }
        return nil
    }
}

// MARK: - CPU

/// Turns cumulative CPU times into usage over the interval between two
/// samples. One instance per page visit; it holds only the last sample.
nonisolated struct ResourceCPUTracker: Sendable {

    private struct Seen: Sendable {
        let start: UInt64
        let cpuTime: UInt64
        let energy: UInt64
    }

    /// One process over one interval.
    struct Rate: Sendable, Equatable {
        /// Percent of one core.
        var cpuPercent: Double
        /// Average power, watts.
        var watts: Double
    }

    private var previous: [pid_t: Seen] = [:]
    /// The last sample's time: uptime nanoseconds, and Mach absolute time
    /// to compare process starts against.
    private var previousNanos: UInt64?
    private var previousAbsolute: UInt64?

    /// Records a sample. Returns each process's CPU percent of one core and
    /// power over the interval since the last sample, or nil on the first
    /// call, when there is nothing to diff against.
    ///
    /// - A process seen both times with the same start: its time delta.
    /// - A process that started during the interval: all its time, since
    ///   all of it was spent in the interval.
    /// - A PID whose start changed, or whose time went backwards: a reused
    ///   PID or a reset counter. No figure this round rather than a wrong one.
    /// - A process that exited during the interval: gone, and its last
    ///   moments with it. Activity Monitor drops them the same way.
    mutating func advance(_ processes: [ResourceProcess], nowNanos: UInt64,
                          nowAbsolute: UInt64) -> [pid_t: Rate]? {
        defer {
            previous = Dictionary(processes.map {
                ($0.pid, Seen(start: $0.start, cpuTime: $0.cpuTime, energy: $0.energy))
            }, uniquingKeysWith: { a, _ in a })
            previousNanos = nowNanos
            previousAbsolute = nowAbsolute
        }
        guard let previousNanos, let previousAbsolute, nowNanos > previousNanos else { return nil }
        let elapsed = Double(nowNanos - previousNanos)
        var result: [pid_t: Rate] = [:]
        for process in processes {
            let used: UInt64
            let energy: UInt64
            if let seen = previous[process.pid], seen.start == process.start {
                guard process.cpuTime >= seen.cpuTime, process.energy >= seen.energy else { continue }
                used = process.cpuTime - seen.cpuTime
                energy = process.energy - seen.energy
            } else if process.start > previousAbsolute {
                used = process.cpuTime
                energy = process.energy
            } else {
                continue
            }
            // Nanojoules over nanoseconds is watts.
            result[process.pid] = Rate(cpuPercent: Double(used) / elapsed * 100,
                                       watts: Double(energy) / elapsed)
        }
        return result
    }
}

// MARK: - Aggregation and ranking

nonisolated enum ResourceRanking {

    /// One row per app, summing its processes. CPU and power are nil for
    /// every row when `rates` is nil (the first sample); a process with no
    /// rate of its own this round (a reused PID) adds nothing to its app's.
    static func aggregate(processes: [ResourceProcess], apps: [ResourceApp],
                          rates: [pid_t: ResourceCPUTracker.Rate]?) -> [ResourceAppUsage] {
        let owners = ResourceAttribution.owners(processes: processes, apps: apps)
        var rows: [pid_t: ResourceAppUsage] = [:]
        for app in apps {
            rows[app.pid] = ResourceAppUsage(app: app, cpuPercent: rates == nil ? nil : 0,
                                             watts: rates == nil ? nil : 0,
                                             memoryBytes: 0, processCount: 0)
        }
        for process in processes {
            guard let owner = owners[process.pid], var row = rows[owner] else { continue }
            row.memoryBytes += process.footprint
            row.processCount += 1
            if let rate = rates?[process.pid] {
                row.cpuPercent = (row.cpuPercent ?? 0) + rate.cpuPercent
                row.watts = (row.watts ?? 0) + rate.watts
            }
            rows[owner] = row
        }
        // An app none of whose processes could be read (another user's, or
        // gone mid-sample) has nothing true to show.
        return rows.values.filter { $0.processCount > 0 }
    }

    /// Highest first. Ties, and the rows still without a rate, fall back
    /// to memory and then name, so the order never shuffles at random
    /// between samples.
    static func ranked(_ rows: [ResourceAppUsage], by metric: ResourceMetric) -> [ResourceAppUsage] {
        rows.sorted { a, b in
            if metric == .energy, a.watts != b.watts {
                return (a.watts ?? -1) > (b.watts ?? -1)
            }
            if metric == .cpu, a.cpuPercent != b.cpuPercent {
                return (a.cpuPercent ?? -1) > (b.cpuPercent ?? -1)
            }
            if a.memoryBytes != b.memoryBytes { return a.memoryBytes > b.memoryBytes }
            return a.app.name.localizedStandardCompare(b.app.name) == .orderedAscending
        }
    }
}

// MARK: - Formatting

nonisolated enum ResourceFormat {

    /// "42%", or "4.2%" under ten, where the decimal still says something.
    static func cpu(_ percent: Double?) -> String {
        guard let percent else { return "—" }
        let clamped = max(percent, 0)
        if clamped < 9.95 { return String(format: "%.1f%%", clamped) }
        return "\(Int(clamped.rounded()))%"
    }

    /// "85 mW" under a watt, "1.2 W" from there.
    static func power(_ watts: Double?) -> String {
        guard let watts else { return "—" }
        let clamped = max(watts, 0)
        if clamped < 0.9995 { return "\(Int((clamped * 1000).rounded())) mW" }
        return String(format: "%.1f W", clamped)
    }

    /// "420 MB", "1.6 GB". Binary units, as Activity Monitor counts them.
    static func memory(_ bytes: UInt64) -> String {
        let mib = Double(bytes) / 1_048_576
        if mib < 1000 { return "\(Int(mib.rounded())) MB" }
        return String(format: "%.1f GB", mib / 1024)
    }
}

// MARK: - Smoothing

/// Exponential moving averages of each app's rates, so one busy second
/// doesn't throw an app to the top. Time-based, so the result is the same
/// whatever the sampling cadence: after one time constant of a sustained
/// change, 63% of it shows; after three, 95%.
///
/// CPU settles over about 10 s and energy over about 20 s; energy is the
/// burstier of the two. Memory is a level, not a rate, and passes through
/// as read. An app's first figure is taken as it is, with nothing to
/// average against; the ranking, not the figure, guards against it.
nonisolated struct ResourceSmoother: Sendable {

    static let cpuTimeConstant: Double = 10
    static let energyTimeConstant: Double = 20

    private var cpu: [pid_t: Double] = [:]
    private var watts: [pid_t: Double] = [:]
    private var lastTime: Double?

    /// `time` in seconds on any monotonic clock.
    mutating func smooth(_ rows: [ResourceAppUsage], at time: Double) -> [ResourceAppUsage] {
        let elapsed = lastTime.map { max(time - $0, 0) } ?? 0
        lastTime = time
        let cpuWeight = Self.weight(elapsed: elapsed, timeConstant: Self.cpuTimeConstant)
        let energyWeight = Self.weight(elapsed: elapsed, timeConstant: Self.energyTimeConstant)
        var nextCPU: [pid_t: Double] = [:]
        var nextWatts: [pid_t: Double] = [:]
        let result = rows.map { row -> ResourceAppUsage in
            var row = row
            if let value = row.cpuPercent {
                let smoothed = cpu[row.id].map { $0 + cpuWeight * (value - $0) } ?? value
                nextCPU[row.id] = smoothed
                row.cpuPercent = smoothed
            }
            if let value = row.watts {
                let smoothed = watts[row.id].map { $0 + energyWeight * (value - $0) } ?? value
                nextWatts[row.id] = smoothed
                row.watts = smoothed
            }
            return row
        }
        // Only apps still running are remembered.
        cpu = nextCPU
        watts = nextWatts
        return result
    }

    /// How far toward the new reading the average moves after `elapsed`.
    static func weight(elapsed: Double, timeConstant: Double) -> Double {
        1 - exp(-elapsed / timeConstant)
    }
}

// MARK: - Stable ordering

/// Keeps the list's order still unless a change is real.
///
/// - **A fresh order** on the first rows, on a change of metric, and when
///   `reset()` asks (the first rates arriving): a plain ranking, since
///   there is no order on screen to protect.
/// - **Otherwise the order is reconsidered every five seconds**, not on
///   every sample; between evaluations values update in place.
/// - **Hysteresis.** At an evaluation an app moves ahead of one above it
///   only if it leads by `margin` (12%) and by the metric's floor, and did
///   so at the previous evaluation too. A lead that holds moves an app as
///   far as it has earned in one step; a lead that flickers moves nothing.
/// - **New apps join at the bottom** and climb like any other, so a
///   launch's first busy second doesn't push the list down.
///
/// Rows keep their app's PID as identity throughout.
nonisolated struct ResourceRankStabilizer: Sendable {

    static let evaluationInterval: Double = 5
    static let margin = 0.12

    private struct Pair: Hashable, Sendable {
        let challenger: pid_t
        let leader: pid_t
    }

    private(set) var order: [pid_t] = []
    private var metric: ResourceMetric?
    private var lastEvaluation: Double?
    /// Overtakes that qualified at the last evaluation.
    private var pending: Set<Pair> = []

    /// The next arrangement asks for a fresh order.
    mutating func reset() {
        metric = nil
    }

    mutating func arrange(_ rows: [ResourceAppUsage], by metric: ResourceMetric,
                          at time: Double) -> [ResourceAppUsage] {
        let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        if metric != self.metric || order.isEmpty {
            order = ResourceRanking.ranked(rows, by: metric).map(\.id)
            self.metric = metric
            lastEvaluation = time
            pending = []
        } else {
            let known = Set(order)
            let newcomers = ResourceRanking.ranked(rows.filter { !known.contains($0.id) }, by: metric)
            let current = order.filter { byID[$0] != nil } + newcomers.map(\.id)
            if let last = lastEvaluation, time - last >= Self.evaluationInterval {
                order = evaluate(current, values: byID, metric: metric)
                lastEvaluation = time
            } else {
                order = current
            }
        }
        return order.compactMap { byID[$0] }
    }

    private mutating func evaluate(_ current: [pid_t], values: [pid_t: ResourceAppUsage],
                                   metric: ResourceMetric) -> [pid_t] {
        var qualifying: Set<Pair> = []
        for (index, challenger) in current.enumerated() {
            for leader in current[..<index]
            where Self.leads(values[challenger], over: values[leader], by: metric) {
                qualifying.insert(Pair(challenger: challenger, leader: leader))
            }
        }
        // Insertion in the current order: each app moves up past every app
        // it has confirmed a lead over, and stops at the first it hasn't.
        var result: [pid_t] = []
        result.reserveCapacity(current.count)
        for challenger in current {
            var index = result.count
            while index > 0 {
                let pair = Pair(challenger: challenger, leader: result[index - 1])
                guard qualifying.contains(pair), pending.contains(pair) else { break }
                index -= 1
            }
            result.insert(challenger, at: index)
        }
        pending = qualifying
        return result
    }

    static func leads(_ a: ResourceAppUsage?, over b: ResourceAppUsage?, by metric: ResourceMetric) -> Bool {
        guard let a, let challenger = value(a, metric) else { return false }
        let leader = b.flatMap { value($0, metric) } ?? 0
        return challenger > leader * (1 + margin) && challenger - leader > floor(metric)
    }

    private static func value(_ row: ResourceAppUsage, _ metric: ResourceMetric) -> Double? {
        switch metric {
        case .energy: row.watts
        case .memory: Double(row.memoryBytes)
        case .cpu: row.cpuPercent
        }
    }

    /// Below this, a lead is noise however large in proportion: two idle
    /// apps at 0.1% and 0.3% CPU are not worth a swap.
    private static func floor(_ metric: ResourceMetric) -> Double {
        switch metric {
        case .energy: 0.005          // 5 mW
        case .memory: 10 * 1_048_576 // 10 MB
        case .cpu: 0.5               // half a percent of a core
        }
    }
}
