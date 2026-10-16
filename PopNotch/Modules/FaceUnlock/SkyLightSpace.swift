import Foundation
import os

// SkyLight is a private framework. Nothing here links it: every symbol is
// resolved at runtime, and a missing framework or symbol means no lock-screen
// overlay, never a crash. Signatures probed on macOS 27.0.1 (2026-10-15).

/// The SkyLight calls the lock-screen overlay needs, resolved once.
nonisolated struct SkyLightAPI: @unchecked Sendable {

    typealias MainConnectionID = @convention(c) () -> Int32
    /// The new space's id; 0 is failure. The only result this file trusts.
    typealias SpaceCreate = @convention(c) (Int32, Int32, CFDictionary?) -> UInt64
    /// Void, like every call below. Disassembled (2026-10-15): when window
    /// management client operations are enabled these end in a tail call to
    /// `objc_autoreleasePoolPop`, which returns nothing, so whatever sits in
    /// the return register is garbage. Never read a result from them.
    typealias SpaceSetAbsoluteLevel = @convention(c) (Int32, UInt64, Int32) -> Void
    typealias ShowHideSpaces = @convention(c) (Int32, CFArray) -> Void
    /// The last argument is a mode flag; 7 was verified.
    typealias SpaceAddWindows = @convention(c) (Int32, UInt64, CFArray, Int32) -> Void
    typealias SpaceDestroy = @convention(c) (Int32, UInt64) -> Void

    static let frameworkPath = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"

    /// Every symbol `init` resolves; all are required.
    static let symbolNames = [
        "SLSMainConnectionID", "SLSSpaceCreate", "SLSSpaceSetAbsoluteLevel",
        "SLSShowSpaces", "SLSHideSpaces", "SLSSpaceAddWindowsAndRemoveFromSpaces",
        "SLSSpaceDestroy",
    ]

    private static let logger = Logger(subsystem: "com.techie.PopNotch", category: "FaceUnlock")

    let mainConnectionID: MainConnectionID
    let spaceCreate: SpaceCreate
    let spaceSetAbsoluteLevel: SpaceSetAbsoluteLevel
    let showSpaces: ShowHideSpaces
    let hideSpaces: ShowHideSpaces
    let spaceAddWindows: SpaceAddWindows
    let spaceDestroy: SpaceDestroy

    /// Nil, logged, when any symbol is missing. `resolve` is `dlsym` on the
    /// real framework, or a fake in tests.
    init?(resolve: (String) -> UnsafeMutableRawPointer?) {
        var pointers: [String: UnsafeMutableRawPointer] = [:]
        for name in Self.symbolNames {
            guard let pointer = resolve(name) else {
                Self.logger.notice("SkyLight symbol missing: \(name, privacy: .public); no lock-screen overlay")
                return nil
            }
            pointers[name] = pointer
        }
        guard let connection = pointers["SLSMainConnectionID"],
              let create = pointers["SLSSpaceCreate"],
              let setLevel = pointers["SLSSpaceSetAbsoluteLevel"],
              let show = pointers["SLSShowSpaces"],
              let hide = pointers["SLSHideSpaces"],
              let addWindows = pointers["SLSSpaceAddWindowsAndRemoveFromSpaces"],
              let destroy = pointers["SLSSpaceDestroy"] else { return nil }
        mainConnectionID = unsafeBitCast(connection, to: MainConnectionID.self)
        spaceCreate = unsafeBitCast(create, to: SpaceCreate.self)
        spaceSetAbsoluteLevel = unsafeBitCast(setLevel, to: SpaceSetAbsoluteLevel.self)
        showSpaces = unsafeBitCast(show, to: ShowHideSpaces.self)
        hideSpaces = unsafeBitCast(hide, to: ShowHideSpaces.self)
        spaceAddWindows = unsafeBitCast(addWindows, to: SpaceAddWindows.self)
        spaceDestroy = unsafeBitCast(destroy, to: SpaceDestroy.self)
    }

    /// The real framework, opened once and never closed. Nil, logged, when
    /// it cannot be opened or lacks a symbol.
    static let system: SkyLightAPI? = {
        guard let handle = dlopen(frameworkPath, RTLD_LAZY) else {
            let reason = dlerror().map { String(cString: $0) } ?? "unknown error"
            logger.notice("SkyLight could not be opened (\(reason, privacy: .public)); no lock-screen overlay")
            return nil
        }
        return SkyLightAPI { dlsym(handle, $0) }
    }()
}

/// One SkyLight space at an absolute level, shown, holding windows added to
/// it. Level 400 draws above the lock screen (200 does not; probed).
/// Destroyed by `destroy()` or, failing that, on deinit; idempotent.
nonisolated final class SkyLightSpace {

    static let lockScreenLevel: Int32 = 400

    private static let logger = Logger(subsystem: "com.techie.PopNotch", category: "FaceUnlock")

    private let api: SkyLightAPI
    private let connection: Int32
    let spaceID: UInt64
    private(set) var isDestroyed = false

    /// Creates the space, sets its level and shows it. Nil, logged, when
    /// SkyLight returns no space id: the only failure SkyLight reports here
    /// (the level and show calls return nothing; see `SkyLightAPI`).
    init?(api: SkyLightAPI, level: Int32 = SkyLightSpace.lockScreenLevel) {
        let connection = api.mainConnectionID()
        let space = api.spaceCreate(connection, 1, nil)
        guard space != 0 else {
            Self.logger.notice("SkyLight space creation failed (connection \(connection, privacy: .public))")
            return nil
        }
        api.spaceSetAbsoluteLevel(connection, space, level)
        api.showSpaces(connection, [NSNumber(value: space)] as CFArray)
        self.api = api
        self.connection = connection
        self.spaceID = space
        Self.logger.notice("SkyLight space \(space, privacy: .public) created at level \(level, privacy: .public) and shown")
    }

    deinit { destroy() }

    /// Moves the window into this space, out of every other.
    func addWindow(number: Int) {
        guard !isDestroyed else { return }
        api.spaceAddWindows(connection, spaceID, [NSNumber(value: number)] as CFArray, 7)
        Self.logger.notice("Window \(number, privacy: .public) added to SkyLight space \(self.spaceID, privacy: .public)")
    }

    /// Hides and destroys the space. Idempotent. SkyLight reports no
    /// result for either call, so success is not logged as verified.
    func destroy() {
        guard !isDestroyed else { return }
        isDestroyed = true
        api.hideSpaces(connection, [NSNumber(value: spaceID)] as CFArray)
        api.spaceDestroy(connection, spaceID)
        Self.logger.notice("SkyLight space \(self.spaceID, privacy: .public) hidden and destroy requested")
    }
}
