import AppKit
import Darwin
import Security

/// Collects `ProcessFacts` for one process from public sources: libproc for
/// the executable and parent, `NSRunningApplication` for apps, and the code
/// signature for team ID and platform status. The impure half of the
/// resolver; `AudioOwnerResolver` does the deciding.
///
/// Cheap enough for its cadence — a few property reads and a signature
/// lookup per process — and only called when a process starts playing,
/// because `AppVolumeService` caches the result per process object.
@MainActor
enum ProcessFactsGatherer {

    /// Deep enough for any launcher chain seen so far (a Chromium helper is
    /// one level below its app); stops earlier at launchd or at a process
    /// this user cannot inspect.
    private static let maxAncestors = 8

    static func facts(pid: pid_t, bundleID: String?) -> ProcessFacts? {
        guard let path = executablePath(of: pid) else { return nil }
        let containerPath = AudioOwnerResolver.outermostAppPath(in: path)
        let containerBundleID = containerPath.flatMap { Bundle(path: $0)?.bundleIdentifier }
        return ProcessFacts(pid: pid,
                            bundleID: bundleID,
                            executablePath: path,
                            identity: identity(of: pid),
                            containerBundleID: containerBundleID,
                            ownApp: app(pid: pid),
                            parentApp: parentApp(of: pid),
                            containingApp: containerBundleID.flatMap(runningApp(bundleID:)))
    }

    /// The process as an app, only if its own bundle is the outermost `.app`
    /// around its executable. A helper bundle nested inside an app is an
    /// `NSRunningApplication` too (Discord's renderer is), which is exactly
    /// what this refuses.
    private static func app(pid: pid_t) -> RunningAppFacts? {
        guard let running = NSRunningApplication(processIdentifier: pid),
              let bundleID = running.bundleIdentifier,
              let path = executablePath(of: pid),
              let outer = AudioOwnerResolver.outermostAppPath(in: path),
              Bundle(path: outer)?.bundleIdentifier == bundleID
        else { return nil }
        return RunningAppFacts(pid: pid, bundleID: bundleID,
                               name: running.localizedName ?? bundleID,
                               identity: identity(of: pid),
                               isRegular: running.activationPolicy == .regular)
    }

    private static func parentApp(of pid: pid_t) -> RunningAppFacts? {
        var current = pid
        for _ in 0..<maxAncestors {
            guard let parent = parentPID(of: current), parent > 1 else { return nil }
            if let found = app(pid: parent) { return found }
            current = parent
        }
        return nil
    }

    private static func runningApp(bundleID: String) -> RunningAppFacts? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .lazy
            .compactMap { app(pid: $0.processIdentifier) }
            .first
    }

    private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// Nil for launchd's children and for processes owned by another user,
    /// whose details libproc will not give up.
    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }

    /// The signature of the running code. `.unknown` when it cannot be read,
    /// which matches nothing — failing closed, never guessing a team.
    private static func identity(of pid: pid_t) -> CodeIdentity {
        var code: SecCode?
        let attributes = [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let code else { return .unknown }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else { return .unknown }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode,
                                            SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &information) == errSecSuccess,
              let dictionary = information as? [String: Any] else { return .unknown }
        return CodeIdentity(
            teamID: dictionary[kSecCodeInfoTeamIdentifier as String] as? String,
            isPlatform: dictionary[kSecCodeInfoPlatformIdentifier as String] != nil)
    }
}
