import Foundation

/// The decrypted password on its way to the keyboard, in one manually
/// allocated buffer that is zeroed on `wipe()` and again on release.
///
/// A `Data` cannot be relied on for this: a copy that shares its storage
/// makes `resetBytes` zero a fresh copy and leave the original, and short
/// values live inline in the struct, wherever it was copied to. This holds
/// the one copy, hands it out only by pointer, and zeroes it with
/// `memset_s`, which the optimiser may not drop.
///
/// Used in sequence, never concurrently: created on the main actor, read
/// by the typing thread, wiped on the main actor after typing returns.
nonisolated final class SecretBytes: @unchecked Sendable {

    private let buffer: UnsafeMutableRawBufferPointer
    let count: Int

    /// Copies `data` in, then zeroes `data` in place. The caller's `Data`
    /// must be uniquely referenced (as `FacePasswordStore`'s freshly
    /// decrypted value is), or zeroing it would only zero a copy.
    init(taking data: inout Data) {
        count = data.count
        buffer = .allocate(byteCount: max(count, 1), alignment: MemoryLayout<UInt8>.alignment)
        data.withUnsafeBytes { source in
            guard let base = source.baseAddress, let destination = buffer.baseAddress else { return }
            destination.copyMemory(from: base, byteCount: source.count)
        }
        data.resetBytes(in: 0..<data.count)
    }

    deinit {
        wipe()
        buffer.deallocate()
    }

    func withUnsafeBytes<Result>(_ body: (UnsafeRawBufferPointer) throws -> Result) rethrows -> Result {
        try body(UnsafeRawBufferPointer(rebasing: buffer[0..<count]))
    }

    /// Zeroes the buffer. Idempotent.
    func wipe() {
        guard let base = buffer.baseAddress else { return }
        _ = memset_s(base, buffer.count, 0, buffer.count)
    }

    /// For tests: every byte is zero.
    var isWiped: Bool {
        withUnsafeBytes { bytes in bytes.allSatisfy { $0 == 0 } }
    }
}
