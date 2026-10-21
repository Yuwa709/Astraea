import Foundation

/// Writes Face Unlock's files: the encrypted `face-identities.enc` and
/// `password.enc`, and the signed `session.json` (`FaceSessionRecord`).
///
/// The file is owner-only (0600) from the moment it exists, inside an
/// owner-only (0700) directory. Creating it with `FileManager` or
/// `Data.write` and then changing its mode would leave it 0644 for a moment,
/// and, if the change failed after the rename, on disk that way for good.
nonisolated enum FaceFileWriter {

    /// Replaces the file at `url` with `data`.
    ///
    /// Opened `O_CREAT | O_EXCL` at mode 0600 under a unique temporary name
    /// beside the target, written in full, flushed, then renamed over the
    /// old file, so a crash mid-write leaves the previous file whole. On any
    /// failure the temporary file is removed and a `POSIXError` is thrown.
    static func replace(_ url: URL, with data: Data) throws {
        let directory = url.deletingLastPathComponent()
        try makeOwnerOnlyDirectory(directory)

        let temporary = directory.appending(path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp").path
        let descriptor = Darwin.open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw currentError() }

        do {
            // The mode passed to `open` is masked by the umask; this makes
            // it exactly 0600 before a single byte is written.
            try check(fchmod(descriptor, 0o600))
            try writeAll(data, to: descriptor)
            try retryingOnInterrupt { fsync(descriptor) }
        } catch {
            Darwin.close(descriptor)
            Darwin.unlink(temporary)
            throw error
        }
        // Not retried on EINTR: on Darwin the descriptor is gone either way.
        guard Darwin.close(descriptor) == 0 else {
            let error = currentError()
            Darwin.unlink(temporary)
            throw error
        }
        guard Darwin.rename(temporary, url.path) == 0 else {
            let error = currentError()
            Darwin.unlink(temporary)
            throw error
        }
    }

    /// Created 0700 if missing; tightened to 0700 if an earlier build made
    /// it with the default mode. Its parents are created with their defaults.
    private static func makeOwnerOnlyDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try check(Darwin.chmod(directory.path, 0o700))
    }

    /// Loops over partial writes and retries interrupted ones.
    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, base + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw currentError()
                }
                offset += written
            }
        }
    }

    private static func retryingOnInterrupt(_ call: () -> Int32) throws {
        while call() != 0 {
            if errno != EINTR { throw currentError() }
        }
    }

    private static func check(_ result: Int32) throws {
        guard result == 0 else { throw currentError() }
    }

    private static func currentError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
