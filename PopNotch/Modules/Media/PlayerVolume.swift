import Foundation

/// The player's own output volume, as Spotify and Music expose it: the
/// `sound volume` property, an integer 0...100, read-write in both scripting
/// dictionaries. This is the same value as each app's in-app slider, so
/// PopNotch never stores it — the player remembers it, across PopNotch
/// quitting or crashing. No tap, no capture permission: the existing
/// Automation grant covers it. See docs/FUTURE-audio-mixer.md, *v1 plan*.
enum PlayerVolume {

    nonisolated static let range = 0...100

    nonisolated static func clamp(_ value: Int) -> Int {
        min(range.upperBound, max(range.lowerBound, value))
    }

    /// Parses `sound volume as text`. Nil for anything that is not a whole
    /// number, never a guessed default — the caller keeps the last value it
    /// actually read. Clamped, so an out-of-range answer cannot push the
    /// slider off its track.
    nonisolated static func parse(_ output: String) -> Int? {
        Int(output.trimmingCharacters(in: .whitespacesAndNewlines)).map(clamp)
    }

    /// A position along the slider, 0...1, as a volume. Linear, because the
    /// players' own sliders are linear in this same value.
    nonisolated static func value(atFraction fraction: Double) -> Int {
        clamp(Int((fraction * 100).rounded()))
    }
}

/// Corrects Spotify reading a written volume back one lower.
///
/// Measured 2026-09-17: after `set sound volume to N`, every later read
/// returns N−1 (52 → 51, 65 → 64, 70 → 69), not just the first. Uncorrected,
/// the slider slipped down one on the next live-sync read after each drag.
/// So after a write of N, reads of N−1 (or N) show as N, and keep doing so
/// until any other value is read. That value is a real change, from
/// Spotify's own slider or a phone, and it ends the correction.
///
/// The cost: if the user really does set Spotify to exactly N−1 by other
/// means, the slider shows N until the next change. One point, and only in
/// that one case.
struct VolumeReadBack {
    private(set) var lastWrite: Int?

    mutating func recordWrite(_ value: Int) {
        lastWrite = value
    }

    /// The value to show for a raw read.
    mutating func adjust(_ read: Int) -> Int {
        guard let written = lastWrite else { return read }
        if read == written || read == written - 1 { return written }
        lastWrite = nil
        return read
    }
}

/// Thins volume writes while the slider is dragged.
///
/// Every write is a synchronous Apple Event on the main actor — about 17ms
/// of IPC per property (`AppleScriptRunner`) — so one per drag event would
/// stall the very slider being dragged. At most one write per `interval`;
/// the caller sends whatever is latest when the wait runs out, and always
/// sends the final value on release. Pure, so the timing is a test.
struct VolumeSendThrottle {
    let interval: TimeInterval
    private(set) var lastSend: TimeInterval?

    init(interval: TimeInterval) {
        self.interval = interval
    }

    /// Zero means send now; anything else is how long until a send is due.
    func wait(at now: TimeInterval) -> TimeInterval {
        guard let lastSend else { return 0 }
        return max(0, interval - (now - lastSend))
    }

    mutating func recordSend(at now: TimeInterval) {
        lastSend = now
    }
}

/// `sound volume` reads and writes for one scriptable player.
///
/// Its own scripts, never co-located with any other property: the `starred`
/// incident proved one failing term aborts a whole `return` expression, so
/// a volume failure must cost the volume control and nothing else.
///
/// Write scripts are compiled once per value and kept. A drag touches a few
/// dozen values at most, and each saves the ~16ms compile on every later
/// send of the same value.
@MainActor
final class ScriptedVolume {

    private let application: String
    private lazy var readScript: NSAppleScript? = AppleScriptRunner.compile(
        "tell application \"\(application)\" to return (sound volume as text)")
    private var writeScripts: [Int: NSAppleScript] = [:]

    init(application: String) {
        self.application = application
    }

    /// One Apple Event. Nil on failure or unparseable output; the failure
    /// itself is returned so the adapter can log it its own way.
    func read() -> Result<Int, AppleScriptRunner.Failure> {
        guard let readScript else { return .failure(.init(code: 0)) }
        switch AppleScriptRunner.run(readScript) {
        case .success(let descriptor):
            guard let value = descriptor.stringValue.flatMap(PlayerVolume.parse) else {
                return .failure(.init(code: 0))
            }
            return .success(value)
        case .failure(let failure):
            return .failure(failure)
        }
    }

    /// One Apple Event. Returns the clamped value that was written.
    func write(_ value: Int) -> Result<Int, AppleScriptRunner.Failure> {
        let target = PlayerVolume.clamp(value)
        let script: NSAppleScript
        if let cached = writeScripts[target] {
            script = cached
        } else {
            guard let compiled = AppleScriptRunner.compile(
                "tell application \"\(application)\" to set sound volume to \(target)")
            else { return .failure(.init(code: 0)) }
            writeScripts[target] = compiled
            script = compiled
        }
        return AppleScriptRunner.run(script).map { _ in target }
    }
}
