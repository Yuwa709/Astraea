import Foundation
import IOKit.pwr_mgt
import Observation
import os

/// Keeps the Mac awake while active, via a power-management assertion.
///
/// One assertion at a time, created on enable and released on disable. There
/// is no timer and no auto-off (hard rule 9 is satisfied trivially: nothing
/// is scheduled at all). It stays on until the user turns it off.
///
/// **Assertions are process-scoped and the system reclaims them on exit.**
/// Verified on this machine 2026-08-29: a probe holding a
/// `NoDisplaySleepAssertion` was sent `SIGKILL`, and `pmset -g assertions`
/// showed it gone immediately afterwards. So a crash cannot strand the Mac
/// awake. The explicit releases below are still correct — they make a clean
/// quit deterministic and let the user turn it off without quitting — but
/// they are not the only thing standing between a crash and a Mac that never
/// sleeps, and should not be described that way.
@MainActor
@Observable
final class CaffeinateService {

    @ObservationIgnored
    private static let logger = Logger(subsystem: "com.techie.PopNotch", category: "Caffeinate")

    /// Shown in `pmset -g assertions`, so it names the app and the reason
    /// rather than appearing as an anonymous assertion.
    @ObservationIgnored
    private static let reason = "PopNotch is keeping this Mac awake" as CFString

    private(set) var isActive = false

    /// 0 means "no assertion held". IOKit never hands out 0 as a valid id.
    @ObservationIgnored private var assertionID: IOPMAssertionID = 0

    func toggle() {
        isActive ? release() : acquire()
    }

    /// `kIOPMAssertionTypeNoDisplaySleep` keeps the display lit, which keeps
    /// the system awake with it — verified: while held, `pmset -g assertions`
    /// reports `PreventUserIdleDisplaySleep 1`.
    func acquire() {
        guard !isActive else { return }
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            Self.reason,
            &id
        )
        // Every system call that can fail handles its failure (code style):
        // a refused assertion leaves isActive false, so the UI keeps showing
        // "off" rather than claiming a state the Mac is not in.
        guard result == kIOReturnSuccess else {
            Self.logger.error("Sleep assertion refused (\(result, privacy: .public))")
            return
        }
        assertionID = id
        isActive = true
        Self.logger.notice("Sleep assertion held (id \(id, privacy: .public))")
    }

    func release() {
        guard assertionID != 0 else {
            isActive = false
            return
        }
        let result = IOPMAssertionRelease(assertionID)
        if result != kIOReturnSuccess {
            Self.logger.error("Sleep assertion release failed (\(result, privacy: .public))")
        } else {
            Self.logger.notice("Sleep assertion released")
        }
        // Cleared regardless: a failed release is not a reason to keep
        // reporting the Mac as held awake, and retrying a stale id would only
        // fail again.
        assertionID = 0
        isActive = false
    }

    /// Belt and braces alongside `applicationWillTerminate`. `deinit` is
    /// nonisolated, so it touches only the stored id and the C call — no
    /// main-actor state, no logging.
    deinit {
        if assertionID != 0 {
            IOPMAssertionRelease(assertionID)
        }
    }
}
