import Darwin
import os

/// Reads every process this user may inspect, through libproc's public
/// calls: `proc_listallpids`, `proc_pid_rusage` for CPU time, energy and
/// physical footprint, `proc_pidinfo` for the parent, `proc_pidpath` for the
/// executable. Needs no entitlement and no permission prompt. Processes of
/// other users (root's daemons) refuse `proc_pid_rusage` and are skipped,
/// which is what keeps the kernel and system daemons off the page.
///
/// Off the main actor: the service calls it from a detached task. The
/// executable path is the only costly read, so it is cached per process
/// identity (PID plus start time) and the cache holds only processes alive
/// at the last read.
nonisolated struct ResourceProcessReader: Sendable {

    private static let logger = Logger(subsystem: "com.techie.Astraea", category: "ResourceUsage")

    private struct Identity: Hashable, Sendable {
        let pid: pid_t
        let start: UInt64
    }

    /// The outermost `.app` per live process; nil inside means "none".
    private var appPaths: [Identity: String?] = [:]

    /// Mach time to nanoseconds. `proc_pid_rusage` reports CPU time in Mach
    /// ticks on Apple silicon (24 MHz), not nanoseconds.
    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.denom != 0 else { return (1, 1) }
        return (UInt64(info.numer), UInt64(info.denom))
    }()

    mutating func readAll() -> [ResourceProcess] {
        let pids = Self.allPIDs()
        var processes: [ResourceProcess] = []
        processes.reserveCapacity(pids.count)
        var nextPaths: [Identity: String?] = [:]
        for pid in pids where pid > 0 {
            guard let usage = Self.usage(of: pid) else { continue }
            let identity = Identity(pid: pid, start: usage.ri_proc_start_abstime)
            let appPath: String?
            if let cached = appPaths[identity] {
                appPath = cached
            } else {
                appPath = Self.executablePath(of: pid).flatMap(Self.outermostAppPath)
            }
            nextPaths[identity] = appPath
            let ticks = usage.ri_user_time &+ usage.ri_system_time
            processes.append(ResourceProcess(
                pid: pid,
                parent: Self.parent(of: pid),
                start: usage.ri_proc_start_abstime,
                cpuTime: ticks.multipliedReportingOverflow(by: Self.timebase.numer).partialValue
                    / Self.timebase.denom,
                footprint: usage.ri_phys_footprint,
                energy: usage.ri_energy_nj,
                appPath: appPath))
        }
        appPaths = nextPaths
        return processes
    }

    // MARK: - libproc

    private static func allPIDs() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else {
            logger.error("proc_listallpids failed (\(errno, privacy: .public))")
            return []
        }
        // Headroom for processes spawned between the two calls.
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = pids.withUnsafeMutableBytes {
            proc_listallpids($0.baseAddress, Int32($0.count))
        }
        guard count > 0 else { return [] }
        return Array(pids.prefix(Int(count)))
    }

    /// Nil for a process that exited, or that this user may not inspect.
    private static func usage(of pid: pid_t) -> rusage_info_v6? {
        var info = rusage_info_v6()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
            }
        }
        return status == 0 ? info : nil
    }

    private static func parent(of pid: pid_t) -> pid_t {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size else { return 0 }
        return pid_t(info.pbsi_ppid)
    }

    private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// The first `.app` from the root, so a helper app nested inside an app
    /// resolves to the app the user launched.
    static func outermostAppPath(_ path: String) -> String? {
        var components: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            components.append(component)
            if component.hasSuffix(".app") {
                return "/" + components.joined(separator: "/")
            }
        }
        return nil
    }
}
