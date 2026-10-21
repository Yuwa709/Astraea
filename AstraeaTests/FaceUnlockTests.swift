import XCTest
import CryptoKit
@testable import Astraea

/// Face Unlock, phase 1: the maths, the pose bands, and the store's safety
/// rules. Every store test injects `MemoryKeyVault` and a temporary file;
/// none may reach the real Keychain or the real face data.
@MainActor
final class FaceUnlockTests: XCTestCase {

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appending(path: "AstraeaFaceTests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        super.tearDown()
    }

    private var fileURL: URL { directory.appending(path: "face-identities.enc") }

    private func store(_ vault: MemoryKeyVault) -> FaceEnrollmentStore {
        FaceEnrollmentStore(session: FaceUnlockSession(vault: vault, authenticator: FakeOwnerAuthenticator(),
                                                       directory: directory))
    }

    private func sample(_ embedding: [Float]) -> FaceSample {
        FaceSample(embedding: embedding, pose: "center", capturedAt: Date(timeIntervalSince1970: 0), quality: 0.6)
    }

    private func identity(_ name: String, _ embeddings: [[Float]], model: String = FaceEmbedder.modelIdentifier) -> FaceIdentity {
        FaceIdentity(name: name, samples: embeddings.map(sample), modelIdentifier: model)
    }

    // MARK: - Embedding maths

    func testCosineSimilarityEdges() {
        XCTAssertEqual(FaceEmbedding.cosineSimilarity([1, 2, 3], [2, 4, 6]), 1, accuracy: 1e-6)
        XCTAssertEqual(FaceEmbedding.cosineSimilarity([1, 0], [0, 1]), 0, accuracy: 1e-6)
        XCTAssertEqual(FaceEmbedding.cosineSimilarity([1, 0], [-1, 0]), -1, accuracy: 1e-6)
        XCTAssertEqual(FaceEmbedding.cosineSimilarity([1, 0], [1, 0, 0]), 0, "mismatched lengths never match")
        XCTAssertEqual(FaceEmbedding.cosineSimilarity([], []), 0)
        XCTAssertEqual(FaceEmbedding.cosineSimilarity([0, 0], [1, 0]), 0)
    }

    func testAverageIsUnitLengthAndMagnitudeBlind() throws {
        let mean = try XCTUnwrap(FaceEmbedding.average([[10, 0], [0, 1]]))
        XCTAssertEqual(mean[0], mean[1], accuracy: 1e-6, "a larger vector must not dominate")
        XCTAssertEqual(mean[0] * mean[0] + mean[1] * mean[1], 1, accuracy: 1e-6)
    }

    func testAverageSkipsWrongLengthVectorsWithoutCountingThem() throws {
        let mean = try XCTUnwrap(FaceEmbedding.average([[1, 0], [1, 0, 0], [1, 0]]))
        XCTAssertEqual(mean, [1, 0])
        XCTAssertNil(FaceEmbedding.average([]))
    }

    // MARK: - Matching

    func testBestMatchNeedsBothCentroidAndClosestSample() {
        let you = identity("You", [[1, 0, 0], [0.9, 0.1, 0]])
        let scored = FaceMatcher.score([1, 0, 0], against: [you])
        XCTAssertNotNil(FaceMatcher.bestMatch(in: scored, threshold: 0.9))

        // The centroid clears 0.6 but no single sample is close enough.
        let spread = identity("Spread", [[1, 1, 0], [1, -1, 0]])
        let spreadScore = FaceMatcher.score([1, 0, 0], against: [spread])
        XCTAssertGreaterThan(spreadScore[0].centroidSimilarity, 0.99)
        XCTAssertLessThan(spreadScore[0].maxSampleSimilarity, 0.75)
        XCTAssertNil(FaceMatcher.bestMatch(in: spreadScore, threshold: 0.8))
    }

    func testScoreSortsBestFirstAndBelowThresholdIsNoMatch() {
        let near = identity("Near", [[1, 0.1, 0]])
        let far = identity("Far", [[0, 1, 0]])
        let scored = FaceMatcher.score([1, 0, 0], against: [far, near])
        XCTAssertEqual(scored.map(\.identity.name), ["Near", "Far"])
        XCTAssertNil(FaceMatcher.bestMatch(in: scored, threshold: 0.999))
        XCTAssertNil(FaceMatcher.bestMatch(in: [], threshold: 0.1))
    }

    func testStaleIdentityNeverMatchesEvenWhenIdentical() {
        let stale = identity("Old", [[1, 0, 0]], model: "some-older-model")
        XCTAssertTrue(stale.isStale)
        XCTAssertNil(FaceMatcher.bestMatch(in: FaceMatcher.score([1, 0, 0], against: [stale]), threshold: 0.5))
    }

    func testIdentityWithoutIsEnabledDecodesAsEnabled() throws {
        let json = """
        {"id":"\(UUID().uuidString)","name":"A","samples":[],"modelIdentifier":"m","embeddingDimension":512,"createdAt":0}
        """
        let decoded = try JSONDecoder().decode(FaceIdentity.self, from: Data(json.utf8))
        XCTAssertTrue(decoded.isEnabled)
    }

    // MARK: - Stale enrolments (ArcFace 512-d before the Intel 256-d model)

    private func arcFaceIdentity(_ name: String) -> FaceIdentity {
        FaceIdentity(name: name, samples: [sample([Float](repeating: 0.04, count: 512))],
                     modelIdentifier: "arcface-w600k_mbf-v1", embeddingDimension: 512)
    }

    func testTheBundledModelIsIntels256DimensionalOne() {
        XCTAssertEqual(FaceEmbedder.embeddingDimension, 256)
        XCTAssertEqual(FaceEmbedder.resourceName, "FaceReidentification")
        XCTAssertNotEqual(FaceEmbedder.modelIdentifier, "arcface-w600k_mbf-v1",
                          "a new identifier is what makes every ArcFace enrolment stale")
        XCTAssertFalse(identity("New", [[1, 0, 0]]).isStale, "a fresh enrolment is current")
    }

    func testOldModelEnrolmentIsStaleAndNeverCompared() {
        let old = arcFaceIdentity("Old")
        XCTAssertTrue(old.isStale)
        let probe = [Float](repeating: 0.0625, count: FaceEmbedder.embeddingDimension)
        XCTAssertTrue(FaceMatcher.score(probe, against: [old]).isEmpty, "a 512-d template is never scored")
        XCTAssertNil(FaceMatcher.bestMatch(in: FaceMatcher.score(probe, against: [old]), threshold: -1))

        // Alongside a current face, only the current one is scored and matches.
        let current = identity("New", [probe])
        let scored = FaceMatcher.score(probe, against: [old, current])
        XCTAssertEqual(scored.map(\.identity.name), ["New"])
        XCTAssertEqual(FaceMatcher.bestMatch(in: scored, threshold: FaceMatchThreshold.strict.value)?.identity.name, "New")
    }

    func testCurrentIdentifierWithTheOldDimensionIsStillStale() {
        let mislabelled = FaceIdentity(name: "Odd", samples: [sample([1, 0, 0])],
                                       modelIdentifier: FaceEmbedder.modelIdentifier, embeddingDimension: 512)
        XCTAssertTrue(mislabelled.isStale)
    }

    /// Loading a pre-swap file keeps every face, flags it, rewrites nothing,
    /// and a recapture brings it back under the same id.
    func testOldModelEnrolmentsLoadKeptFlaggedAndRecapturable() async throws {
        let key = SymmetricKey(size: .bits256)
        let old = arcFaceIdentity("Owner")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FaceFileWriter.replace(fileURL, with: FaceCrypto.sealFile(JSONEncoder().encode([old]), as: .faces,
                                                                      epoch: 0, master: key))
        let before = try Data(contentsOf: fileURL)

        // Current layout, so the first key read has nothing to re-seal.
        let store = store(MemoryKeyVault(key: key, epochs: FaceKeyEpochs(refusesLegacy: true)))
        await store.unlock()
        XCTAssertEqual(store.state, .ready)
        XCTAssertEqual(store.identities, [old], "nothing dropped")
        XCTAssertEqual(store.staleIdentities.map(\.id), [old.id])
        XCTAssertEqual(try Data(contentsOf: fileURL), before, "loading never rewrites or deletes")

        let probe = [Float](repeating: 0.0625, count: FaceEmbedder.embeddingDimension)
        try await store.commitEnrollment(replacing: old.id, name: "Owner", samples: [sample(probe)])
        XCTAssertEqual(store.identities.map(\.id), [old.id])
        XCTAssertTrue(store.staleIdentities.isEmpty)
        XCTAssertEqual(store.identities.first?.modelIdentifier, FaceEmbedder.modelIdentifier)
        XCTAssertEqual(store.identities.first?.embeddingDimension, 256)
    }

    // MARK: - Alignment maths

    func testSimilarityTransformRecoversRotationScaleAndTranslation() throws {
        let truth = CGAffineTransform(translationX: 12, y: -5).rotated(by: 0.3).scaledBy(x: 1.7, y: 1.7)
        let source = FaceAligner.referencePoints
        let destination = source.map { $0.applying(truth) }
        let solved = try XCTUnwrap(FaceAligner.solveSimilarityTransform(from: source, to: destination))
        for (point, expected) in zip(source, destination) {
            let got = point.applying(solved)
            XCTAssertEqual(got.x, expected.x, accuracy: 1e-6)
            XCTAssertEqual(got.y, expected.y, accuracy: 1e-6)
        }
        XCTAssertNil(FaceAligner.solveSimilarityTransform(from: [.zero], to: [.zero]))
        XCTAssertNil(FaceAligner.solveSimilarityTransform(from: [.zero, .zero], to: [.zero, CGPoint(x: 1, y: 1)]),
                     "coincident source points have no solution")
    }

    func testAlignerTargetsTheIntel128Template() {
        XCTAssertEqual(FaceAligner.outputSize, 128)
        XCTAssertEqual(FaceAligner.referencePoints.count, 5)
        for point in FaceAligner.referencePoints {
            XCTAssertTrue((0...128).contains(point.x) && (0...128).contains(point.y), "\(point)")
        }
        XCTAssertEqual(FaceAligner.referencePoints[0].x, 40.393, accuracy: 1e-9)
        XCTAssertEqual(FaceAligner.referencePoints[4].y, 105.561, accuracy: 1e-9)
    }

    /// Landmarks already on the template, in a 128 px image, need no warp.
    func testLandmarksOnTheTemplateGiveAnIdentityTransform() throws {
        let transform = try XCTUnwrap(FaceAligner.alignmentTransform(
            sourcePoints: FaceAligner.referencePoints, imageHeight: CGFloat(FaceAligner.outputSize)))
        XCTAssertEqual(transform.a, 1, accuracy: 1e-9)
        XCTAssertEqual(transform.b, 0, accuracy: 1e-9)
        XCTAssertEqual(transform.c, 0, accuracy: 1e-9)
        XCTAssertEqual(transform.d, 1, accuracy: 1e-9)
        XCTAssertEqual(transform.tx, 0, accuracy: 1e-9)
        XCTAssertEqual(transform.ty, 0, accuracy: 1e-9)
    }

    /// Vision labels eyes anatomically: on an unmirrored frame the subject's
    /// left eye is on the image's right. Whatever the labels, the eye on the
    /// image's left must land on the template's left eye.
    func testImageLeftEyeMapsToTheTemplateLeftEye() throws {
        // A face 2.5x the template's size, placed in a 640x480 frame.
        let imageHeight: CGFloat = 480
        let placed = FaceAligner.referencePoints.map { CGPoint(x: $0.x * 2.5 + 150, y: $0.y * 2.5 + 80) }
        let anatomicalLeft = placed[1], anatomicalRight = placed[0]
        let lipMiddle = CGPoint(x: (placed[3].x + placed[4].x) / 2, y: placed[3].y + 6)
        let points = try XCTUnwrap(FaceAligner.orderedFivePoints(
            eyeA: anatomicalLeft, eyeB: anatomicalRight, nose: placed[2],
            outerLips: [lipMiddle, placed[4], placed[3]]))
        XCTAssertEqual(points, placed, "image-left eye first, mouth corners from the lips' extreme x")
        XCTAssertNil(FaceAligner.orderedFivePoints(eyeA: .zero, eyeB: .zero, nose: .zero, outerLips: []))

        let transform = try XCTUnwrap(FaceAligner.alignmentTransform(sourcePoints: points, imageHeight: imageHeight))
        // Both sides in the crop's y-up space, as the warp draws.
        let size = CGFloat(FaceAligner.outputSize)
        for (point, target) in zip(points, FaceAligner.referencePoints) {
            let mapped = CGPoint(x: point.x, y: imageHeight - point.y).applying(transform)
            XCTAssertEqual(mapped.x, target.x, accuracy: 1e-6)
            XCTAssertEqual(mapped.y, size - target.y, accuracy: 1e-6)
        }
        let imageLeftEye = CGPoint(x: anatomicalRight.x, y: imageHeight - anatomicalRight.y).applying(transform)
        XCTAssertLessThan(imageLeftEye.x, size / 2, "lands on the crop's left")
        XCTAssertEqual(transform.a, 0.4, accuracy: 1e-9, "upright, unmirrored, 1/2.5 scale")
        XCTAssertEqual(transform.d, 0.4, accuracy: 1e-9)
        XCTAssertEqual(transform.b, 0, accuracy: 1e-9)
    }

    // MARK: - Pose bands (raw Vision signs: +yaw = user's left, -pitch = up)

    func testCentreAndDirectionalPoses() {
        XCTAssertTrue(EnrollmentPoseRules.poseMatches(yaw: 0, pitch: 0, pose: .center, widened: false))
        XCTAssertFalse(EnrollmentPoseRules.poseMatches(yaw: 0.3, pitch: 0, pose: .center, widened: false))
        XCTAssertTrue(EnrollmentPoseRules.poseMatches(yaw: 0.3, pitch: 0, pose: .left, widened: false))
        XCTAssertFalse(EnrollmentPoseRules.poseMatches(yaw: -0.3, pitch: 0, pose: .left, widened: false))
        XCTAssertTrue(EnrollmentPoseRules.poseMatches(yaw: 0, pitch: -0.25, pose: .top, widened: false))
        XCTAssertTrue(EnrollmentPoseRules.poseMatches(yaw: -0.3, pitch: 0.25, pose: .bottomRight, widened: false))
    }

    func testStallWideningAndLeniencyRelaxTheInnerThreshold() {
        // 0.21 is short of left's 0.24 until the 1.25 stall widening applies.
        XCTAssertFalse(EnrollmentPoseRules.poseMatches(yaw: 0.21, pitch: 0, pose: .left, widened: false))
        XCTAssertTrue(EnrollmentPoseRules.poseMatches(yaw: 0.21, pitch: 0, pose: .left, widened: true))
        // bottom-left carries 1.5 leniency: 0.12 pitch passes (0.17 / 1.5).
        XCTAssertTrue(EnrollmentPoseRules.poseMatches(yaw: 0.17, pitch: 0.12, pose: .bottomLeft, widened: false))
    }

    func testExcessiveTurnReportsTheDominantDirection() {
        XCTAssertNil(EnrollmentPoseRules.excessiveTurn(yaw: 0.4, pitch: 0.2))
        XCTAssertEqual(EnrollmentPoseRules.excessiveTurn(yaw: 0.6, pitch: 0), .left)
        XCTAssertEqual(EnrollmentPoseRules.excessiveTurn(yaw: -0.6, pitch: 0.1), .right)
        XCTAssertEqual(EnrollmentPoseRules.excessiveTurn(yaw: 0, pitch: -0.4), .up)
        XCTAssertEqual(EnrollmentPoseRules.excessiveTurn(yaw: 0.6, pitch: -0.4), .topLeft)
        XCTAssertFalse(EnrollmentPoseRules.poseMatches(yaw: 0.6, pitch: 0, pose: .left, widened: true),
                       "past the outer cap never matches, widened or not")
    }

    func testHeadTurnPointsWhereTheMirroredPreviewShows() throws {
        // A turn to the user's right (-yaw) points at 90°, the right sector.
        let right = try XCTUnwrap(EnrollmentPoseRules.headTurn(yaw: -0.24, pitch: 0, pose: .right))
        XCTAssertEqual(right.angle, 90, accuracy: 1e-6)
        XCTAssertEqual(right.progress, 1, accuracy: 1e-6)
        // Looking up (-pitch) points at 0°.
        let up = try XCTUnwrap(EnrollmentPoseRules.headTurn(yaw: 0, pitch: -0.1, pose: .top))
        XCTAssertEqual(up.angle, 0, accuracy: 1e-6)
        XCTAssertNil(EnrollmentPoseRules.headTurn(yaw: 0.01, pitch: 0, pose: .left), "inside the dead zone")
        XCTAssertNil(EnrollmentPoseRules.headTurn(yaw: 0.3, pitch: 0, pose: .center))
    }

    // MARK: - Store

    func testUnlockWithNothingOnDiskNeverTouchesTheKeychain() async {
        let vault = MemoryKeyVault()
        let store = store(vault)
        await store.unlock()
        XCTAssertEqual(store.state, .ready)
        XCTAssertEqual(vault.reads, 0)
        XCTAssertEqual(vault.creates, 0)
    }

    func testCommitCreatesOneKeyEncryptsAndRoundTrips() async throws {
        let vault = MemoryKeyVault()
        let first = store(vault)
        await first.unlock()
        try await first.commitEnrollment(name: "Distinctive Name", samples: [sample([1, 0, 0])])
        try await first.commitEnrollment(name: "Second", samples: [sample([0, 1, 0])])
        XCTAssertEqual(vault.creates, 1, "one key, reused")

        let raw = try Data(contentsOf: fileURL)
        XCTAssertNil(raw.range(of: Data("Distinctive Name".utf8)), "the file must not be plaintext")
        let mode = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)

        let second = store(vault)
        await second.unlock()
        XCTAssertEqual(second.state, .ready)
        XCTAssertEqual(second.identities, first.identities)
    }

    func testMissingKeyIsUnreadableAndNeverOverwritesOrMintsAKey() async throws {
        let original = MemoryKeyVault()
        let writer = store(original)
        await writer.unlock()
        try await writer.commitEnrollment(name: "A", samples: [sample([1, 0])])
        let before = try Data(contentsOf: fileURL)

        let emptyVault = MemoryKeyVault()
        let reader = store(emptyVault)
        await reader.unlock()
        guard case .unreadable = reader.state else { return XCTFail("expected unreadable, got \(reader.state)") }
        do {
            try await reader.commitEnrollment(name: "B", samples: [sample([0, 1])])
            XCTFail("an unreadable store must refuse to write")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: fileURL), before)
        XCTAssertEqual(emptyVault.creates, 0)
    }

    func testRefusedKeyReadStaysLockedAndDoesNotMintAKey() async throws {
        let vault = MemoryKeyVault()
        let writer = store(vault)
        await writer.unlock()
        try await writer.commitEnrollment(name: "A", samples: [sample([1, 0])])

        vault.readError = FaceKeyVaultError.keychain(errSecUserCanceled)
        let reader = store(vault)
        await reader.unlock()
        XCTAssertEqual(reader.state, .locked)
        XCTAssertNotNil(reader.lastError)
        XCTAssertEqual(vault.creates, 1, "only the writer's original key")

        vault.readError = nil
        await reader.unlock()
        XCTAssertEqual(reader.state, .ready, "retry works once the read is allowed")
    }

    func testWrongKeyIsUnreadableAndDeleteAllRecovers() async throws {
        let writer = store(MemoryKeyVault())
        await writer.unlock()
        try await writer.commitEnrollment(name: "A", samples: [sample([1, 0])])

        let otherVault = MemoryKeyVault(key: SymmetricKey(size: .bits256))
        let reader = store(otherVault)
        await reader.unlock()
        guard case .unreadable = reader.state else { return XCTFail("expected unreadable, got \(reader.state)") }

        reader.deleteAll()
        XCTAssertEqual(reader.state, .ready)
        XCTAssertFalse(reader.fileExists)
        XCTAssertNil(otherVault.storedKey, "nothing left that it sealed: the key is deleted")
        try await reader.commitEnrollment(name: "Fresh", samples: [sample([0, 1])])
        XCTAssertEqual(otherVault.creates, 1, "a fresh key is minted, never the one that was there")
    }

    func testNamesAreUniqueIgnoringCaseAndDiacritics() async throws {
        let store = store(MemoryKeyVault())
        await store.unlock()
        let alex = try await store.commitEnrollment(name: "  Álex ", samples: [sample([1, 0])])
        XCTAssertEqual(alex.name, "Álex")
        do {
            try await store.commitEnrollment(name: "alex", samples: [sample([0, 1])])
            XCTFail("duplicate name accepted")
        } catch {}
        try await store.commitEnrollment(replacing: alex.id, name: "ALEX", samples: [sample([0, 1])])
        XCTAssertEqual(store.identities.count, 1, "a recapture may keep its own name")
        XCTAssertEqual(store.identities[0].samples.map(\.embedding), [[0, 1]], "a recapture replaces samples")
    }

    func testToggleAndDeletePersist() async throws {
        let vault = MemoryKeyVault()
        let store = store(vault)
        await store.unlock()
        let a = try await store.commitEnrollment(name: "A", samples: [sample([1, 0])])
        let b = try await store.commitEnrollment(name: "B", samples: [sample([0, 1])])
        try store.setEnabled(false, for: a.id)
        try store.delete(b.id)

        let reloaded = self.store(vault)
        await reloaded.unlock()
        XCTAssertEqual(reloaded.identities.map(\.name), ["A"])
        XCTAssertEqual(reloaded.identities.first?.isEnabled, false)
    }
}

/// Stands in for the login keychain. Counts reads and creates so tests can
/// prove when the Keychain would and would not have been touched.
///
/// `init(key:)` with no epochs is an item made before epochs existed (the
/// legacy layout); `createKey()` makes one with fresh epochs, as the real
/// vault does.
nonisolated final class MemoryKeyVault: FaceKeyVault, @unchecked Sendable {
    private let lock = NSLock()
    private var key: SymmetricKey?
    private var _epochs: FaceKeyEpochs?
    private var _readError: Error?
    private var _deleteError: Error?
    private var _reads = 0
    private var _creates = 0
    private var _deletes = 0
    private var _epochWrites = 0

    init(key: SymmetricKey? = nil, epochs: FaceKeyEpochs? = nil) {
        self.key = key
        _epochs = epochs
    }

    var readError: Error? {
        get { lock.withLock { _readError } }
        set { lock.withLock { _readError = newValue } }
    }
    /// Thrown by `deleteKey()` while an item exists: one this process may
    /// not delete (`errSecInvalidOwnerEdit`).
    var deleteError: Error? {
        get { lock.withLock { _deleteError } }
        set { lock.withLock { _deleteError = newValue } }
    }
    var epochs: FaceKeyEpochs? {
        get { lock.withLock { _epochs } }
        set { lock.withLock { _epochs = newValue } }
    }
    var storedKey: SymmetricKey? { lock.withLock { key } }
    var reads: Int { lock.withLock { _reads } }
    var creates: Int { lock.withLock { _creates } }
    /// Items actually removed.
    var deletes: Int { lock.withLock { _deletes } }
    var epochWrites: Int { lock.withLock { _epochWrites } }

    func readKey() throws -> SymmetricKey? {
        try lock.withLock {
            _reads += 1
            if let error = _readError { throw error }
            return key
        }
    }

    func createKey() throws -> SymmetricKey {
        try lock.withLock {
            guard key == nil else { throw FaceKeyVaultError.keychain(errSecDuplicateItem) }
            _creates += 1
            let created = SymmetricKey(size: .bits256)
            key = created
            _epochs = FaceKeyEpochs()
            return created
        }
    }

    func deleteKey() throws {
        try lock.withLock {
            guard key != nil else { return }
            if let error = _deleteError { throw error }
            key = nil
            _epochs = nil
            _deletes += 1
        }
    }

    func readEpochs() throws -> FaceKeyEpochs? {
        lock.withLock { key == nil ? nil : _epochs }
    }

    func writeEpochs(_ epochs: FaceKeyEpochs) throws {
        try lock.withLock {
            guard key != nil else { throw FaceKeyVaultError.keychain(errSecItemNotFound) }
            _epochs = epochs
            _epochWrites += 1
        }
    }
}
