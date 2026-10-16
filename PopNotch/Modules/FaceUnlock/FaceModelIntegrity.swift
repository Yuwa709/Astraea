import CoreML
import CoreVideo
import CryptoKit
import Foundation
import os

/// The compiled face model is checked against a pinned SHA-256 before it is
/// loaded, so a model swapped inside the app bundle (one that embeds every
/// face close to the owner's, say) is refused instead of trusted.
///
/// What is pinned, and why not every byte of `FaceReidentification.mlmodelc`:
/// Xcode's Core ML compiler writes the model's user metadata in a random
/// order, so `coremldata.bin` and `metadata.json` differ between two builds
/// of the same commit (seen 2026-10-15). A whole-directory hash would fail
/// on a clean rebuild. So:
/// - the directory must hold exactly `expectedFiles`, no more, no fewer;
/// - the graph and the weights (`hashedFiles`), which are what turns a face
///   into an embedding, are hashed: each file's SHA-256 as `shasum -a 256`
///   prints it (`<hex>  ./<path>`), one line per file in this order, and the
///   SHA-256 of those lines;
/// - the description `coremldata.bin` carries (input and output names,
///   sizes, pixel format) is checked after loading by
///   `checkDescription(_:)`.
nonisolated enum FaceModelIntegrity {

    /// Regenerate when the model changes, or when an Xcode update changes
    /// what its compiler emits (`testBundledModelMatchesThePinnedDigest`
    /// fails and prints the value it found):
    ///
    ///     xcodebuild -scheme PopNotch -configuration Debug -destination 'platform=macOS' build
    ///     cd <DerivedData>/Build/Products/Debug/PopNotch.app/Contents/Resources/FaceReidentification.mlmodelc
    ///     shasum -a 256 ./model.mil ./weights/weight.bin | shasum -a 256
    static let expectedDigest = "29eb658cda412f43775b761c2025f7269f52bffacafe2fb044cb35427c7e1c3f"

    /// Hashed, in this order.
    static let hashedFiles = ["./model.mil", "./weights/weight.bin"]
    /// Every regular file the compiled model may contain.
    static let expectedFiles: Set<String> = [
        "./analytics/coremldata.bin", "./coremldata.bin", "./metadata.json", "./model.mil", "./weights/weight.bin",
    ]

    private static let logger = Logger(subsystem: "com.techie.PopNotch", category: "FaceUnlock")

    /// The bundled model's URL once it has passed the check. Located and
    /// hashed on first use, once per launch; every later `FaceEmbedder`
    /// reuses the answer.
    static let verifiedBundledModel: Result<URL, FaceEmbedderError> = {
        guard let url = Bundle.main.url(forResource: FaceEmbedder.resourceName, withExtension: "mlmodelc") else {
            logger.error("Face model missing from the bundle: \(FaceEmbedder.resourceName, privacy: .public).mlmodelc")
            return .failure(.modelNotFound)
        }
        let started = ContinuousClock.now
        do {
            try verify(modelAt: url)
        } catch {
            return .failure(.modelIntegrityFailed)
        }
        let elapsed = (ContinuousClock.now - started).components
        let milliseconds = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
        logger.notice("Face model integrity checked: \(milliseconds, format: .fixed(precision: 1), privacy: .public) ms")
        return .success(url)
    }()

    /// Throws `.modelIntegrityFailed`, logged at `.error`, unless the
    /// directory holds exactly the expected files and its digest is
    /// `expected`.
    static func verify(modelAt url: URL, expected: String = expectedDigest) throws {
        let found: String
        do {
            let files = try regularFiles(in: url)
            guard Set(files.keys) == expectedFiles else {
                let extra = Set(files.keys).subtracting(expectedFiles).sorted()
                let missing = expectedFiles.subtracting(files.keys).sorted()
                logger.error("Face model failed its integrity check: unexpected files \(extra, privacy: .public), missing \(missing, privacy: .public); not loaded")
                throw FaceEmbedderError.modelIntegrityFailed
            }
            found = try digest(of: hashedFiles.compactMap { path in files[path].map { (path, $0) } })
        } catch let error as FaceEmbedderError {
            throw error
        } catch {
            logger.error("Face model integrity check could not read the model: \(error.localizedDescription, privacy: .public)")
            throw FaceEmbedderError.modelIntegrityFailed
        }
        guard found == expected else {
            logger.error("Face model failed its integrity check: expected \(expected, privacy: .public), found \(found, privacy: .public); not loaded")
            throw FaceEmbedderError.modelIntegrityFailed
        }
    }

    /// The `shasum -a 256 <files> | shasum -a 256` digest of `files`, in
    /// the order given.
    static func digest(of files: [(path: String, url: URL)]) throws -> String {
        var listing = ""
        for file in files {
            listing += "\(hex(SHA256.hash(data: try Data(contentsOf: file.url))))  \(file.path)\n"
        }
        return hex(SHA256.hash(data: Data(listing.utf8)))
    }

    /// Every regular file under `directory` by "./relative/path", as
    /// `find . -type f` lists them (symbolic links are not regular files).
    static func regularFiles(in directory: URL) throws -> [String: URL] {
        let base = directory.standardizedFileURL
        let basePath = base.path.hasSuffix("/") ? base.path : base.path + "/"
        guard let enumerator = FileManager.default.enumerator(
            at: base, includingPropertiesForKeys: [.isRegularFileKey], options: [],
            errorHandler: { _, _ in false }) else {
            throw CocoaError(.fileReadUnknown)
        }
        var files: [String: URL] = [:]
        for case let url as URL in enumerator {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(basePath) else { throw CocoaError(.fileReadInvalidFileName) }
            files["./" + path.dropFirst(basePath.count)] = url
        }
        return files
    }

    /// Nil when the loaded model takes a 128x128 32BGRA image called
    /// `input_image` and returns `embedding`, 256 values; else what is
    /// wrong. Guards the part of the model the hash cannot cover.
    static func checkDescription(_ description: MLModelDescription, inputName: String, outputName: String) -> String? {
        guard let input = description.inputDescriptionsByName[inputName], input.type == .image,
              let image = input.imageConstraint else {
            return "no image input '\(inputName)'"
        }
        let size = FaceAligner.outputSize
        guard image.pixelsWide == size, image.pixelsHigh == size,
              image.pixelFormatType == kCVPixelFormatType_32BGRA else {
            return "input is \(image.pixelsWide)x\(image.pixelsHigh), format \(image.pixelFormatType)"
        }
        guard let output = description.outputDescriptionsByName[outputName], output.type == .multiArray,
              let shape = output.multiArrayConstraint?.shape else {
            return "no array output '\(outputName)'"
        }
        let count = shape.reduce(1) { $0 * $1.intValue }
        guard count == FaceEmbedder.embeddingDimension else {
            return "output has \(count) values"
        }
        return nil
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
