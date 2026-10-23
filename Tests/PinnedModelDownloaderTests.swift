import CryptoKit
import Foundation
import XCTest

/// Host-less coverage for the pinned installer, the shared-cache seed and the verification
/// stamps. Every byte comes from an in-memory fetcher and temporary folders: no network, and
/// nothing under the user's real Application Support is read or written.
final class PinnedModelDownloaderTests: XCTestCase {
    private let modelID = "fixture-model"
    private let revision = String(repeating: "b", count: 40)
    private let weights = Data("weights-bytes".utf8)
    private let graph = Data("compiled graph".utf8)

    private var root: URL!
    private var directory: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DictariPinnedModelTests-" + UUID().uuidString, isDirectory: true)
        directory = root.appendingPathComponent("model", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Pinned downloads

    /// Regression: the large weights came from upstream `main`. Every file, weights included,
    /// must be requested at the manifest's immutable revision.
    func testDownloadsEveryListedFileFromThePinnedRevision() async throws {
        let fetcher = FakeFetcher(bodies: [
            "weights.bin": weights,
            "Model.mlmodelc/coremldata.bin": graph
        ])
        let progress = ProgressRecorder()

        let installed = try await ModelFiles.ensurePinnedModel(
            modelID: modelID, directory: directory, manifestData: manifest(),
            fetcher: fetcher, progress: { progress.append($0) }
        )

        XCTAssertEqual(installed, Int64(weights.count + graph.count))
        XCTAssertEqual(Set(fetcher.requested.map(\.absoluteString)), [
            "https://huggingface.co/owner/repository/resolve/\(revision)/prefix/weights.bin",
            "https://huggingface.co/owner/repository/resolve/\(revision)/prefix/Model.mlmodelc/coremldata.bin"
        ])
        XCTAssertFalse(fetcher.requested.contains { $0.absoluteString.contains("/main/") })
        XCTAssertEqual(try Data(contentsOf: file("weights.bin")), weights)
        XCTAssertEqual(try Data(contentsOf: file("Model.mlmodelc/coremldata.bin")), graph)
        XCTAssertNoThrow(try ModelFiles.verifyIntegrity(
            modelID: modelID, directory: directory, manifestData: manifest()
        ))
        XCTAssertEqual(progress.values.last, 1)
        XCTAssertEqual(progress.values, progress.values.sorted(), "progress must never go backwards")
        XCTAssertEqual(partialFiles(), [])
    }

    func testKeepsFilesThatAlreadyMatchAndFetchesOnlyTheRest() async throws {
        try write(weights, to: "weights.bin")
        let fetcher = FakeFetcher(bodies: ["Model.mlmodelc/coremldata.bin": graph])

        let installed = try await ModelFiles.ensurePinnedModel(
            modelID: modelID, directory: directory, manifestData: manifest(), fetcher: fetcher
        )

        XCTAssertEqual(installed, Int64(graph.count))
        XCTAssertEqual(fetcher.requested.map(\.lastPathComponent), ["coremldata.bin"])
    }

    func testCompleteModelNeedsNoNetworkAndReportsNothingInstalled() async throws {
        try write(weights, to: "weights.bin")
        try write(graph, to: "Model.mlmodelc/coremldata.bin")
        let fetcher = FakeFetcher(bodies: [:])
        let progress = ProgressRecorder()

        let installed = try await ModelFiles.ensurePinnedModel(
            modelID: modelID, directory: directory, manifestData: manifest(),
            fetcher: fetcher, progress: { progress.append($0) }
        )

        XCTAssertEqual(installed, 0)
        XCTAssertEqual(fetcher.requested, [])
        XCTAssertEqual(progress.values, [])
    }

    /// A corrupt cached file is replaced by the pinned bytes rather than failing forever.
    func testReplacesAMismatchingCachedFileWithPinnedBytes() async throws {
        try write(Data("weights-BYTES".utf8), to: "weights.bin")
        try write(graph, to: "Model.mlmodelc/coremldata.bin")
        let fetcher = FakeFetcher(bodies: ["weights.bin": weights])

        try await ModelFiles.ensurePinnedModel(
            modelID: modelID, directory: directory, manifestData: manifest(), fetcher: fetcher
        )

        XCTAssertEqual(try Data(contentsOf: file("weights.bin")), weights)
    }

    /// Regression: rejected transfer bytes must never replace a file a loader could open.
    func testWrongHashBodyNeverReplacesTheExistingFile() async throws {
        let old = Data("old-contents!".utf8)
        try write(old, to: "weights.bin")
        try write(graph, to: "Model.mlmodelc/coremldata.bin")
        let fetcher = FakeFetcher(bodies: ["weights.bin": Data("WEIGHTS-BYTES".utf8)])

        do {
            try await ModelFiles.ensurePinnedModel(
                modelID: modelID, directory: directory, manifestData: manifest(), fetcher: fetcher
            )
            XCTFail("a body with the wrong digest must be rejected")
        } catch {
            guard case .checksumMismatch(let path, _, _) = error as? ModelIntegrityError else {
                return XCTFail("expected checksumMismatch, got \(error)")
            }
            XCTAssertEqual(path, "weights.bin")
        }

        XCTAssertEqual(try Data(contentsOf: file("weights.bin")), old)
        XCTAssertEqual(partialFiles(), [])
    }

    func testOversizedBodyIsAbortedWithoutWritingTheFile() async throws {
        try write(graph, to: "Model.mlmodelc/coremldata.bin")
        let fetcher = FakeFetcher(bodies: ["weights.bin": weights + Data(repeating: 0, count: 64)])

        do {
            try await ModelFiles.ensurePinnedModel(
                modelID: modelID, directory: directory, manifestData: manifest(), fetcher: fetcher
            )
            XCTFail("an oversized body must be rejected")
        } catch {
            guard case .sizeMismatch(let path, let expected, let actual) = error as? ModelIntegrityError else {
                return XCTFail("expected sizeMismatch, got \(error)")
            }
            XCTAssertEqual(path, "weights.bin")
            XCTAssertEqual(expected, Int64(weights.count))
            XCTAssertGreaterThan(actual, expected)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: file("weights.bin").path))
        XCTAssertEqual(partialFiles(), [])
    }

    func testTruncatedBodyIsRejected() async throws {
        let fetcher = FakeFetcher(bodies: [
            "weights.bin": weights.prefix(4),
            "Model.mlmodelc/coremldata.bin": graph
        ])

        do {
            try await ModelFiles.ensurePinnedModel(
                modelID: modelID, directory: directory, manifestData: manifest(), fetcher: fetcher
            )
            XCTFail("a short body must be rejected")
        } catch {
            XCTAssertEqual(error as? ModelIntegrityError,
                           .sizeMismatch(path: "weights.bin", expected: Int64(weights.count), actual: 4))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file("weights.bin").path))
    }

    func testTransportErrorPropagatesAndLeavesNoPartialFile() async throws {
        let fetcher = FakeFetcher(bodies: [:], failure: URLError(.notConnectedToInternet))

        do {
            try await ModelFiles.ensurePinnedModel(
                modelID: modelID, directory: directory, manifestData: manifest(), fetcher: fetcher
            )
            XCTFail("a transport failure must surface")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }
        XCTAssertEqual(partialFiles(), [])
    }

    func testSymlinkedDestinationIsRefusedBeforeAnyFetch() async throws {
        let external = root.appendingPathComponent("external.bin")
        try Data("keep".utf8).write(to: external)
        try FileManager.default.createSymbolicLink(at: file("weights.bin"), withDestinationURL: external)
        let fetcher = FakeFetcher(bodies: ["weights.bin": weights, "Model.mlmodelc/coremldata.bin": graph])

        do {
            try await ModelFiles.ensurePinnedModel(
                modelID: modelID, directory: directory, manifestData: manifest(), fetcher: fetcher
            )
            XCTFail("a symlink must never be written through")
        } catch {
            XCTAssertEqual(error as? ModelIntegrityError, .symbolicLink(path: "weights.bin"))
        }
        XCTAssertEqual(try Data(contentsOf: external), Data("keep".utf8))
        XCTAssertEqual(fetcher.requested, [])
    }

    func testStalePartialFilesFromAnInterruptedRunAreRemoved() async throws {
        let stale = directory.appendingPathComponent(ModelFiles.partialFilePrefix + "crashed")
        try Data("half".utf8).write(to: stale)
        let fetcher = FakeFetcher(bodies: ["weights.bin": weights, "Model.mlmodelc/coremldata.bin": graph])

        try await ModelFiles.ensurePinnedModel(
            modelID: modelID, directory: directory, manifestData: manifest(), fetcher: fetcher
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
    }

    func testCancellationIsReportedAsCancellationNotCorruption() async throws {
        let fetcher = HangingFetcher()
        let directory = self.directory!
        let manifest = try manifest()

        let task = Task {
            try await ModelFiles.ensurePinnedModel(
                modelID: "fixture-model", directory: directory, manifestData: manifest,
                fetcher: fetcher
            )
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("a cancelled install must not succeed")
        } catch {
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }
        XCTAssertEqual(partialFiles(), [])
    }

    // MARK: - Seeding from FluidAudio's shared cache

    /// Regression: upgrading Direct users had Parakeet in FluidAudio's shared folder. Matching
    /// bytes are copied (never moved) so no re-download is needed and the other apps keep theirs.
    func testMatchingSharedCacheFilesAreCopiedWithoutNetworkAndLeftInPlace() async throws {
        let shared = root.appendingPathComponent("FluidAudio/parakeet", isDirectory: true)
        try write(weights, to: "weights.bin", in: shared)
        try write(graph, to: "Model.mlmodelc/coremldata.bin", in: shared)
        // Another app's bundle in the shared folder must neither break us nor be copied.
        try write(Data("other".utf8), to: "OtherApp.mlmodelc/model.mil", in: shared)
        let before = try snapshot(shared)
        let fetcher = FakeFetcher(bodies: [:])

        try await ModelFiles.ensurePinnedModel(
            modelID: modelID, directory: directory, manifestData: manifest(),
            fetcher: fetcher, seedDirectory: shared
        )

        XCTAssertEqual(fetcher.requested, [])
        XCTAssertEqual(try snapshot(shared), before, "the shared cache must be left untouched")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: file("OtherApp.mlmodelc").path
        ))
        XCTAssertNoThrow(try ModelFiles.verifyIntegrity(
            modelID: modelID, directory: directory, manifestData: manifest()
        ))
    }

    func testMismatchingSharedCacheFileFallsBackToPinnedDownload() async throws {
        let shared = root.appendingPathComponent("FluidAudio/parakeet", isDirectory: true)
        let foreign = Data("WEIGHTS-bytes".utf8) // same size, different bytes
        try write(foreign, to: "weights.bin", in: shared)
        try write(graph, to: "Model.mlmodelc/coremldata.bin", in: shared)
        let fetcher = FakeFetcher(bodies: ["weights.bin": weights])

        try await ModelFiles.ensurePinnedModel(
            modelID: modelID, directory: directory, manifestData: manifest(),
            fetcher: fetcher, seedDirectory: shared
        )

        XCTAssertEqual(fetcher.requested.map(\.lastPathComponent), ["weights.bin"])
        XCTAssertEqual(try Data(contentsOf: file("weights.bin")), weights)
        XCTAssertEqual(try Data(contentsOf: shared.appendingPathComponent("weights.bin")), foreign)
    }

    // MARK: - Verification stamps

    func testSuccessfulVerificationRecordsStampsNextToTheModel() throws {
        try write(weights, to: "weights.bin")
        try write(graph, to: "Model.mlmodelc/coremldata.bin")

        try ModelFiles.verifyIntegrity(modelID: modelID, directory: directory, manifestData: manifest())

        let stampFile = directory.appendingPathComponent(IntegrityStampCache.fileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stampFile.path))
        // The stamp file is inert top-level metadata: verification still passes with it present.
        XCTAssertNoThrow(try ModelFiles.verifyIntegrity(
            modelID: modelID, directory: directory, manifestData: manifest()
        ))
    }

    /// Proves a matching stamp really skips hashing: the stamp vouches for bytes that do not
    /// match, and verification trusts it. Any later change to the file must void that trust.
    func testMatchingStampSkipsHashingAndAnyChangeForcesARehash() throws {
        let wrong = Data("weights-BYTES".utf8) // same size as the manifest entry
        try write(wrong, to: "weights.bin")
        try write(graph, to: "Model.mlmodelc/coremldata.bin")
        let entry = ModelFiles.IntegrityFile(
            path: "weights.bin", size: Int64(weights.count), sha256: sha256(weights)
        )
        let cache = IntegrityStampCache(directory: directory)
        cache.record(entry, identity: try XCTUnwrap(FileIdentity(of: file("weights.bin"))))
        cache.saveIfNeeded()

        XCTAssertNoThrow(try ModelFiles.verifyIntegrity(
            modelID: modelID, directory: directory, manifestData: manifest()
        ), "an unchanged stamped file must not be re-hashed")

        // Rewrite in place with the same size, then restore the old mtime: ctime still moves.
        let attributes = try FileManager.default.attributesOfItem(atPath: file("weights.bin").path)
        let handle = try FileHandle(forWritingTo: file("weights.bin"))
        try handle.write(contentsOf: wrong)
        try handle.close()
        try FileManager.default.setAttributes(
            [.modificationDate: try XCTUnwrap(attributes[.modificationDate])],
            ofItemAtPath: file("weights.bin").path
        )

        XCTAssertThrowsError(try ModelFiles.verifyIntegrity(
            modelID: modelID, directory: directory, manifestData: manifest()
        )) { error in
            guard case .checksumMismatch(let path, _, _) = error as? ModelIntegrityError else {
                return XCTFail("expected checksumMismatch, got \(error)")
            }
            XCTAssertEqual(path, "weights.bin")
        }
    }

    func testStampForAnOlderManifestDigestIsIgnored() throws {
        try write(Data("weights-BYTES".utf8), to: "weights.bin")
        try write(graph, to: "Model.mlmodelc/coremldata.bin")
        let staleEntry = ModelFiles.IntegrityFile(
            path: "weights.bin", size: Int64(weights.count),
            sha256: sha256(Data("weights-BYTES".utf8))
        )
        let cache = IntegrityStampCache(directory: directory)
        cache.record(staleEntry, identity: try XCTUnwrap(FileIdentity(of: file("weights.bin"))))
        cache.saveIfNeeded()

        XCTAssertThrowsError(try ModelFiles.verifyIntegrity(
            modelID: modelID, directory: directory, manifestData: manifest()
        ))
    }

    func testCorruptStampFileFailsSafeToAFullHash() throws {
        try write(Data("weights-BYTES".utf8), to: "weights.bin")
        try write(graph, to: "Model.mlmodelc/coremldata.bin")
        try Data("{not json".utf8).write(
            to: directory.appendingPathComponent(IntegrityStampCache.fileName)
        )

        XCTAssertThrowsError(try ModelFiles.verifyIntegrity(
            modelID: modelID, directory: directory, manifestData: manifest()
        ))
    }

    func testReplacingAStampedFileWithAnotherInodeForcesARehash() throws {
        try write(weights, to: "weights.bin")
        try write(graph, to: "Model.mlmodelc/coremldata.bin")
        try ModelFiles.verifyIntegrity(modelID: modelID, directory: directory, manifestData: manifest())

        try Data("weights-BYTES".utf8).write(to: file("weights.bin"), options: .atomic)

        XCTAssertThrowsError(try ModelFiles.verifyIntegrity(
            modelID: modelID, directory: directory, manifestData: manifest()
        ))
    }

    // MARK: - Helpers

    private func manifest() throws -> Data {
        let files: [[String: Any]] = [
            ["path": "weights.bin", "size": weights.count, "sha256": sha256(weights)],
            ["path": "Model.mlmodelc/coremldata.bin", "size": graph.count, "sha256": sha256(graph)]
        ]
        return try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "models": [modelID: [
                "repository": "owner/repository",
                "revision": revision,
                "remotePathPrefix": "prefix",
                "files": files
            ]]
        ])
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func file(_ path: String) -> URL {
        directory.appendingPathComponent(path)
    }

    private func write(_ data: Data, to path: String, in base: URL? = nil) throws {
        let destination = (base ?? directory).appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: destination)
    }

    private func partialFiles() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasPrefix(ModelFiles.partialFilePrefix) }
    }

    private func snapshot(_ folder: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
        while let url = walker?.nextObject() as? URL {
            if (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
                result[url.path.replacingOccurrences(of: folder.path, with: "")] = try Data(contentsOf: url)
            }
        }
        return result
    }
}

/// Serves in-memory bodies keyed by the manifest path at the end of the pinned URL, in small
/// chunks so the streaming hash and size checks see multiple writes.
private final class FakeFetcher: ModelFileFetching, @unchecked Sendable {
    private let lock = NSLock()
    private let bodies: [String: Data]
    private let failure: (any Error)?
    private var _requested: [URL] = []

    init(bodies: [String: Data], failure: (any Error)? = nil) {
        self.bodies = bodies
        self.failure = failure
    }

    var requested: [URL] {
        lock.withLock { _requested }
    }

    func chunks(from url: URL) -> AsyncThrowingStream<Data, any Error> {
        lock.withLock { _requested.append(url) }
        let body = bodies.first { url.absoluteString.hasSuffix("/prefix/" + $0.key) }?.value
        let failure = self.failure
        return AsyncThrowingStream { continuation in
            if let failure {
                continuation.finish(throwing: failure)
                return
            }
            guard let body else {
                continuation.finish(throwing: URLError(.badServerResponse))
                return
            }
            var offset = 0
            while offset < body.count {
                let end = min(offset + 3, body.count)
                continuation.yield(body.subdata(in: offset..<end))
                offset = end
            }
            continuation.finish()
        }
    }
}

/// Yields one chunk and then never finishes, like a stalled connection.
private struct HangingFetcher: ModelFileFetching {
    func chunks(from url: URL) -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(Data("w".utf8))
        }
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Double] = []

    var values: [Double] { lock.withLock { _values } }

    func append(_ value: Double) {
        lock.withLock { _values.append(value) }
    }
}
