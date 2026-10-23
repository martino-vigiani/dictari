import Foundation
@testable import Hub
import Tokenizers
@testable import WhisperKit
import XCTest

final class ModelIntegrityTests: XCTestCase {
    private let modelID = "fixture-model"
    private let abcSHA256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    private let emptySHA256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    func testCuratedModelSizesMatchPinnedDownloadBytesInsteadOfStaleLabels() throws {
        let manifest = try bundledManifest()

        // Regression: Large v3 Turbo was once advertised as ~810 MB even though its pinned
        // files total 1,638,464,446 bytes. The catalog uses rounded decimal MB, not MiB.
        for descriptor in ModelDescriptor.curated {
            let pinnedModel = try XCTUnwrap(
                manifest.models[descriptor.whisperKitName],
                "No pinned files for curated model \(descriptor.id)"
            )
            let totalBytes = pinnedModel.files.reduce(Int64(0)) { $0 + $1.size }
            let roundedDecimalMB = Int((totalBytes + 500_000) / 1_000_000)

            XCTAssertEqual(
                descriptor.approxSizeMB,
                roundedDecimalMB,
                "\(descriptor.id) should display the size of its pinned model files"
            )
        }
    }

    /// Regression: tokenizer data was previously fetched by the library after our model
    /// checksum gate. These exact official OpenAI revision bytes are now part of that gate.
    func testBundledBaseWhisperTokenizerPinsBothReviewedFiles() throws {
        let model = try XCTUnwrap(bundledManifest().models["tokenizer-whisper-base"])

        XCTAssertEqual(model.repository, "openai/whisper-base")
        XCTAssertEqual(model.revision, "e37978b90ca9030d5170a5c07aadb050351a65bb")
        XCTAssertEqual(model.files, [
            .init(path: "tokenizer.json", size: 2_480_466,
                  sha256: "27fc476bfe7f17299480be2273fc0608e4d5a99aba2ab5dec5374b4482d1a566"),
            .init(path: "tokenizer_config.json", size: 282_683,
                  sha256: "2a4c4281cf9f51ac6ccc406fdc711a087afe6530f671fa7b80953edc498275ce")
        ])
    }

    /// Regression: Large v3 Turbo must use a separately pinned large-v3 tokenizer, not fall
    /// back to an unverified cache or moving upstream default branch.
    func testBundledLargeV3WhisperTokenizerPinsBothReviewedFiles() throws {
        let model = try XCTUnwrap(bundledManifest().models["tokenizer-whisper-large-v3"])

        XCTAssertEqual(model.repository, "openai/whisper-large-v3")
        XCTAssertEqual(model.revision, "06f233fe06e710322aca913c1bc4249a0d71fce1")
        XCTAssertEqual(model.files, [
            .init(path: "tokenizer.json", size: 2_480_617,
                  sha256: "6d8cbd7cd0d8d5815e478dac67b85a26bbe77c1f5e0c6d76d1ce2abc0e5f21ca"),
            .init(path: "tokenizer_config.json", size: 282_843,
                  sha256: "844b642c73a91359722f47b35705f7174686df33d252695d8572cf9ac03a6389")
        ])
    }

    /// Optional local integration: compare Dictari's verified-byte adapter with the pinned
    /// WhisperKit 0.18.0 wrapper and upstream YYJSON parser without invoking its
    /// network-capable tokenizer loader or constructing HubApi.
    /// Parsing roughly 5.5 MB of official JSON twice takes longer than a small unit test,
    /// justified here because a dependency upgrade could silently change multilingual decoding.
    func testVerifiedBaseTokenizerMatchesWhisperKitLocally() throws {
        try assertTokenizerParity(
            modelID: "tokenizer-whisper-base", repositoryName: "whisper-base"
        )
    }

    func testVerifiedLargeV3TokenizerMatchesWhisperKitLocally() throws {
        try assertTokenizerParity(
            modelID: "tokenizer-whisper-large-v3", repositoryName: "whisper-large-v3"
        )
    }

    /// Regression: a mutable `main` URL can change between download and load. Every requested
    /// artifact URL must come from the manifest's reviewed 40-character commit.
    func testPinnedDownloadURLUsesExactRevisionAndManifestPath() throws {
        let revision = String(repeating: "a", count: 40)
        let manifest = try manifestData(revision: revision, files: [
            ManifestFile(path: "weights.bin", size: 3, sha256: abcSHA256)
        ])

        let url = try ModelFiles.pinnedDownloadURL(
            modelID: modelID, path: "weights.bin", manifestData: manifest
        )

        XCTAssertEqual(
            url.absoluteString,
            "https://huggingface.co/owner/repository/resolve/\(revision)/artifacts/weights.bin"
        )
    }

    func testPinnedDownloadURLRejectsAnUnlistedArtifact() throws {
        let manifest = try manifestData(files: [
            ManifestFile(path: "weights.bin", size: 3, sha256: abcSHA256)
        ])

        XCTAssertThrowsError(try ModelFiles.pinnedDownloadURL(
            modelID: modelID, path: "tokenizer.json", manifestData: manifest
        )) { error in
            XCTAssertEqual(error as? ModelIntegrityError, .missingFile(path: "tokenizer.json"))
        }
    }

    func testPinnedDownloadURLRejectsMutableRevision() throws {
        let manifest = try manifestData(revision: "main", files: [
            ManifestFile(path: "weights.bin", size: 3, sha256: abcSHA256)
        ])

        XCTAssertThrowsError(try ModelFiles.pinnedDownloadURL(
            modelID: modelID, path: "weights.bin", manifestData: manifest
        )) { error in
            XCTAssertEqual(error as? ModelIntegrityError, .malformedManifest)
        }
    }

    /// Regression: WhisperKit's own downloader followed the moving Hub branch. The pinned
    /// installer now owns the variant folder, at the same Hub layout older builds wrote, so
    /// existing caches are reused rather than re-downloaded.
    func testWhisperKitDirectoryKeepsTheHubLayoutOfEarlierReleases() {
        let root = URL(fileURLWithPath: "/tmp/models-root", isDirectory: true)

        XCTAssertEqual(
            ModelFiles.whisperKitDirectory(forVariant: "openai_whisper-base", modelsRoot: root).path,
            "/tmp/models-root/models/argmaxinc/whisperkit-coreml/openai_whisper-base"
        )
    }

    /// Regression: Direct used FluidAudio's shared cache, which other apps also write to.
    func testParakeetDirectoryIsOwnedByDictariNotFluidAudioSharedCache() {
        let directory = ModelFiles.parakeetDirectory.standardizedFileURL.path

        XCTAssertTrue(directory.hasPrefix(AppPaths.models.standardizedFileURL.path + "/"))
        XCTAssertFalse(directory.contains("/FluidAudio/"))
    }

    func testBundledVerificationGateNeverLoadsWithoutManifest() async throws {
        let fixture = try ModelIntegrityFixture()
        defer { fixture.remove() }
        let bundle = try fixture.makeBundle(manifestData: nil)
        var loadCount = 0

        do {
            let _: String = try await ModelFiles.withBundledVerification(
                modelID: modelID, directory: fixture.modelDirectory, bundle: bundle
            ) {
                loadCount += 1
                return "loaded"
            }
            XCTFail("No trust manifest must mean no local load")
        } catch {
            XCTAssertEqual(error as? ModelIntegrityError, .malformedManifest)
        }

        XCTAssertEqual(loadCount, 0)
    }

    /// Regression: before the strict-local path, dependency download/load helpers could open
    /// model files before Dictari checked their digest. A bad digest must never reach loadLocal.
    func testVerifiedModelGateNeverLoadsCorruptedBytes() async throws {
        let fixture = try ModelIntegrityFixture()
        defer { fixture.remove() }
        try fixture.write(Data("abd".utf8), to: "weights.bin")
        let manifest = try manifestData(files: [
            ManifestFile(path: "weights.bin", size: 3, sha256: abcSHA256)
        ])
        var loadCount = 0

        do {
            let _: String = try await ModelFiles.withVerifiedModel(
                modelID: modelID, directory: fixture.modelDirectory, manifestData: manifest
            ) {
                loadCount += 1
                return "loaded"
            }
            XCTFail("Corrupted bytes must fail before the local loader runs")
        } catch {
            guard case .checksumMismatch(let path, _, _) = error as? ModelIntegrityError else {
                return XCTFail("Expected checksumMismatch, got \(error)")
            }
            XCTAssertEqual(path, "weights.bin")
        }

        XCTAssertEqual(loadCount, 0)
    }

    func testVerifiedModelGateNeverLoadsMissingFiles() async throws {
        let fixture = try ModelIntegrityFixture()
        defer { fixture.remove() }
        let manifest = try manifestData(files: [
            ManifestFile(path: "weights.bin", size: 3, sha256: abcSHA256)
        ])
        var loadCount = 0

        do {
            let _: String = try await ModelFiles.withVerifiedModel(
                modelID: modelID, directory: fixture.modelDirectory, manifestData: manifest
            ) {
                loadCount += 1
                return "loaded"
            }
            XCTFail("A missing artifact must fail before the local loader runs")
        } catch {
            XCTAssertEqual(error as? ModelIntegrityError, .missingFile(path: "weights.bin"))
        }

        XCTAssertEqual(loadCount, 0)
    }

    func testVerifiedModelGateLoadsVerifiedBytesExactlyOnce() async throws {
        let fixture = try ModelIntegrityFixture()
        defer { fixture.remove() }
        try fixture.write(Data("abc".utf8), to: "weights.bin")
        let manifest = try manifestData(files: [
            ManifestFile(path: "weights.bin", size: 3, sha256: abcSHA256)
        ])
        var loadCount = 0

        let result = try await ModelFiles.withVerifiedModel(
            modelID: modelID, directory: fixture.modelDirectory, manifestData: manifest
        ) {
            loadCount += 1
            return "loaded"
        }

        XCTAssertEqual(result, "loaded")
        XCTAssertEqual(loadCount, 1)
    }

    /// Regression: a failed local load should surface, not trigger a hidden downloader retry.
    func testVerifiedModelGatePropagatesLoaderFailureWithoutRetry() async throws {
        let fixture = try ModelIntegrityFixture()
        defer { fixture.remove() }
        try fixture.write(Data("abc".utf8), to: "weights.bin")
        let manifest = try manifestData(files: [
            ManifestFile(path: "weights.bin", size: 3, sha256: abcSHA256)
        ])
        var loadCount = 0

        do {
            let _: String = try await ModelFiles.withVerifiedModel(
                modelID: modelID, directory: fixture.modelDirectory, manifestData: manifest
            ) {
                loadCount += 1
                throw LocalLoaderFailure.simulated
            }
            XCTFail("Local loader failure must propagate")
        } catch {
            XCTAssertEqual(error as? LocalLoaderFailure, .simulated)
        }

        XCTAssertEqual(loadCount, 1, "The gate must not retry a failed loader")
    }

    /// Regression: WhisperKit can open an optional prefill Core ML bundle even when the
    /// manifest lists only the required decoder. An unlisted compiled model must block load.
    func testVerifiedModelGateRejectsUnlistedOptionalCoreMLModelBeforeLoad() async throws {
        let fixture = try ModelIntegrityFixture()
        defer { fixture.remove() }
        try fixture.write(Data("abc".utf8), to: "weights.bin")
        try fixture.write(
            Data("unreviewed graph".utf8),
            to: "TextDecoderContextPrefill.mlmodelc/model.mil"
        )
        let manifest = try manifestData(files: [
            ManifestFile(path: "weights.bin", size: 3, sha256: abcSHA256)
        ])
        var loadCount = 0

        do {
            let _: String = try await ModelFiles.withVerifiedModel(
                modelID: modelID, directory: fixture.modelDirectory, manifestData: manifest
            ) {
                loadCount += 1
                return "loaded"
            }
            XCTFail("Unlisted Core ML graph must block local load")
        } catch {
            XCTAssertEqual(error as? ModelIntegrityError,
                           .unexpectedFile(path: "TextDecoderContextPrefill.mlmodelc"))
        }

        XCTAssertEqual(loadCount, 0)
    }

    func testVerifiedModelGateRejectsUnlistedSourceCoreMLPackageBeforeLoad() async throws {
        let fixture = try ModelIntegrityFixture()
        defer { fixture.remove() }
        try fixture.write(Data("abc".utf8), to: "weights.bin")
        try fixture.write(Data("unreviewed graph".utf8),
                          to: "Optional.mlpackage/Data/com.apple.CoreML/model.mlmodel")
        let manifest = try manifestData(files: [
            ManifestFile(path: "weights.bin", size: 3, sha256: abcSHA256)
        ])
        var loadCount = 0

        do {
            let _: String = try await ModelFiles.withVerifiedModel(
                modelID: modelID, directory: fixture.modelDirectory, manifestData: manifest
            ) {
                loadCount += 1
                return "loaded"
            }
            XCTFail("Unlisted Core ML source package must block local load")
        } catch {
            XCTAssertEqual(error as? ModelIntegrityError,
                           .unexpectedFile(path: "Optional.mlpackage"))
        }

        XCTAssertEqual(loadCount, 0)
    }

    /// Regression: case-insensitive APFS may resolve an uppercase bundle suffix through a
    /// lowercase Core ML lookup. Filename case cannot bypass manifest admission.
    func testVerifiedModelGateRejectsUppercaseCompiledModelSuffix() async throws {
        try await assertUnlistedCoreMLBundleBlocksLoad("Optional.MLMODELC")
    }

    func testVerifiedModelGateRejectsUppercaseSourcePackageSuffix() async throws {
        try await assertUnlistedCoreMLBundleBlocksLoad("Optional.MLPACKAGE")
    }

    func testVerifiedModelGateRejectsUnlistedFileInsideListedCoreMLBundle() async throws {
        let fixture = try ModelIntegrityFixture()
        defer { fixture.remove() }
        try fixture.write(Data("abc".utf8), to: "Safe.mlmodelc/model.mil")
        try fixture.write(Data("unreviewed weights".utf8),
                          to: "Safe.mlmodelc/weights/weight.bin")
        let manifest = try manifestData(files: [
            ManifestFile(path: "Safe.mlmodelc/model.mil", size: 3, sha256: abcSHA256)
        ])
        var loadCount = 0

        do {
            let _: String = try await ModelFiles.withVerifiedModel(
                modelID: modelID, directory: fixture.modelDirectory, manifestData: manifest
            ) {
                loadCount += 1
                return "loaded"
            }
            XCTFail("Unlisted bytes inside a reviewed Core ML bundle must block load")
        } catch {
            XCTAssertEqual(error as? ModelIntegrityError,
                           .unexpectedFile(path: "Safe.mlmodelc/weights/weight.bin"))
        }

        XCTAssertEqual(loadCount, 0)
    }

    func testVerifiedModelGateRejectsSymlinkInsideListedCoreMLBundle() async throws {
        let fixture = try ModelIntegrityFixture()
        defer { fixture.remove() }
        try fixture.write(Data("abc".utf8), to: "Safe.mlmodelc/model.mil")
        let external = fixture.root.appendingPathComponent("external.bin")
        try Data("outside".utf8).write(to: external)
        let symlink = fixture.modelDirectory
            .appendingPathComponent("Safe.mlmodelc/weights/weight.bin")
        try FileManager.default.createDirectory(
            at: symlink.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: external)
        let manifest = try manifestData(files: [
            ManifestFile(path: "Safe.mlmodelc/model.mil", size: 3, sha256: abcSHA256)
        ])
        var loadCount = 0

        do {
            let _: String = try await ModelFiles.withVerifiedModel(
                modelID: modelID, directory: fixture.modelDirectory, manifestData: manifest
            ) {
                loadCount += 1
                return "loaded"
            }
            XCTFail("Symlink inside Core ML bundle must block local load")
        } catch {
            XCTAssertEqual(error as? ModelIntegrityError,
                           .symbolicLink(path: "Safe.mlmodelc/weights/weight.bin"))
        }

        XCTAssertEqual(loadCount, 0)
    }

    /// Existing Hub and FluidAudio caches contain inert metadata beside model files. The
    /// strict graph check must not break an offline user's already-verified model cache.
    func testVerifiedModelGateAllowsInertCacheMetadataBesidePinnedFiles() async throws {
        let fixture = try ModelIntegrityFixture()
        defer { fixture.remove() }
        try fixture.write(Data("abc".utf8), to: "weights.bin")
        try fixture.write(Data("{}".utf8), to: "config.json")
        try fixture.write(Data("{}".utf8), to: "parakeet_v3_vocab.json")
        let manifest = try manifestData(files: [
            ManifestFile(path: "weights.bin", size: 3, sha256: abcSHA256)
        ])
        var loadCount = 0

        let result = try await ModelFiles.withVerifiedModel(
            modelID: modelID, directory: fixture.modelDirectory, manifestData: manifest
        ) {
            loadCount += 1
            return "loaded"
        }

        XCTAssertEqual(result, "loaded")
        XCTAssertEqual(loadCount, 1)
    }

    /// A fully listed compiled bundle must remain usable; the scanner must compare lexical
    /// relative paths, even when macOS canonicalizes `/var` as `/private/var` in temp fixtures.
    func testVerifiedModelGateLoadsFullyListedCoreMLBundle() async throws {
        let fixture = try ModelIntegrityFixture()
        defer { fixture.remove() }
        try fixture.write(Data("abc".utf8), to: "Safe.mlmodelc/model.mil")
        let manifest = try manifestData(files: [
            ManifestFile(path: "Safe.mlmodelc/model.mil", size: 3, sha256: abcSHA256)
        ])
        var loadCount = 0

        let result = try await ModelFiles.withVerifiedModel(
            modelID: modelID, directory: fixture.modelDirectory, manifestData: manifest
        ) {
            loadCount += 1
            return "loaded"
        }

        XCTAssertEqual(result, "loaded")
        XCTAssertEqual(loadCount, 1)
    }

    func testAcceptsValidManifestAndDirectory() throws {
        let fixture = try ModelIntegrityFixture()
        defer { fixture.remove() }
        try fixture.write(Data("abc".utf8), to: "weights.bin")
        let manifest = try manifestData(files: [
            ManifestFile(path: "weights.bin", size: 3, sha256: abcSHA256)
        ])

        XCTAssertNoThrow(
            try ModelFiles.verifyIntegrity(
                modelID: modelID,
                directory: fixture.modelDirectory,
                manifestData: manifest
            )
        )
    }

    func testBundledManifestAdmitsReviewedBytesAndRejectsTampering() throws {
        let fixture = try ModelIntegrityFixture()
        defer { fixture.remove() }
        try fixture.write(Data("abc".utf8), to: "weights.bin")
        let manifest = try manifestData(files: [
            ManifestFile(path: "weights.bin", size: 3, sha256: abcSHA256)
        ])
        let bundle = try fixture.makeBundle(manifestData: manifest)

        XCTAssertNoThrow(try ModelFiles.verifyBundledIntegrity(
            modelID: modelID, directory: fixture.modelDirectory, bundle: bundle
        ))

        // Same size but different content: a size-only cache check would miss this.
        try fixture.write(Data("abd".utf8), to: "weights.bin")
        XCTAssertThrowsError(try ModelFiles.verifyBundledIntegrity(
            modelID: modelID, directory: fixture.modelDirectory, bundle: bundle
        )) { error in
            guard case .checksumMismatch(let path, _, _) = error as? ModelIntegrityError else {
                return XCTFail("expected checksumMismatch, got \(error)")
            }
            XCTAssertEqual(path, "weights.bin")
        }
    }

    func testMissingBundledManifestFailsClosed() throws {
        let fixture = try ModelIntegrityFixture()
        defer { fixture.remove() }
        let bundle = try fixture.makeBundle(manifestData: nil)

        XCTAssertThrowsError(try ModelFiles.verifyBundledIntegrity(
            modelID: modelID, directory: fixture.modelDirectory, bundle: bundle
        )) { error in
            XCTAssertEqual(error as? ModelIntegrityError, .malformedManifest)
        }
    }

    func testAcceptsEmptyRemotePathPrefix() throws {
        let fixture = try ModelIntegrityFixture()
        defer { fixture.remove() }
        try fixture.write(Data("abc".utf8), to: "weights.bin")
        let manifest = try manifestData(remotePathPrefix: "", files: [
            ManifestFile(path: "weights.bin", size: 3, sha256: abcSHA256)
        ])

        XCTAssertNoThrow(
            try ModelFiles.verifyIntegrity(
                modelID: modelID,
                directory: fixture.modelDirectory,
                manifestData: manifest
            )
        )
    }

    func testAcceptsZeroByteFileWithKnownSHA256() throws {
        let fixture = try ModelIntegrityFixture()
        defer { fixture.remove() }
        try fixture.write(Data(), to: "empty.bin")
        // Standard SHA-256 digest for an empty byte sequence.
        let manifest = try manifestData(files: [
            ManifestFile(path: "empty.bin", size: 0, sha256: emptySHA256)
        ])

        XCTAssertNoThrow(
            try ModelFiles.verifyIntegrity(
                modelID: modelID,
                directory: fixture.modelDirectory,
                manifestData: manifest
            )
        )
    }

    func testAcceptsKnownSHA256VectorLargerThanOneReadChunk() throws {
        let fixture = try ModelIntegrityFixture()
        defer { fixture.remove() }
        // One MiB plus one byte forces a second streaming read. The expected digest was
        // generated independently with /usr/bin/shasum, not the production implementation.
        let bytes = Data(repeating: 0x61, count: 1_048_577)
        let knownSHA256 = "4a3f0c0c213adea174f9a3d4c13177315b588bdb2e9c1012d3d0bf0453ca0f6a"
        try fixture.write(bytes, to: "weights.bin")
        let manifest = try manifestData(files: [
            ManifestFile(path: "weights.bin", size: bytes.count, sha256: knownSHA256)
        ])

        XCTAssertNoThrow(
            try ModelFiles.verifyIntegrity(
                modelID: modelID,
                directory: fixture.modelDirectory,
                manifestData: manifest
            )
        )
    }

    func testMissingFileFailsWithItsRelativePath() throws {
        let fixture = try ModelIntegrityFixture()
        defer { fixture.remove() }
        let manifest = try manifestData(files: [
            ManifestFile(path: "missing.bin", size: 3, sha256: abcSHA256)
        ])

        XCTAssertThrowsError(
            try ModelFiles.verifyIntegrity(
                modelID: modelID,
                directory: fixture.modelDirectory,
                manifestData: manifest
            )
        ) { error in
            XCTAssertEqual(error as? ModelIntegrityError, .missingFile(path: "missing.bin"))
        }
    }

    func testEveryListedFileIsVerified() throws {
        let fixture = try ModelIntegrityFixture()
        defer { fixture.remove() }
        try fixture.write(Data("abc".utf8), to: "first.bin")
        let manifest = try manifestData(files: [
            ManifestFile(path: "first.bin", size: 3, sha256: abcSHA256),
            ManifestFile(path: "second.bin", size: 3, sha256: abcSHA256)
        ])

        XCTAssertThrowsError(
            try ModelFiles.verifyIntegrity(
                modelID: modelID,
                directory: fixture.modelDirectory,
                manifestData: manifest
            )
        ) { error in
            XCTAssertEqual(error as? ModelIntegrityError, .missingFile(path: "second.bin"))
        }
    }

    func testSizeMismatchReportsExpectedAndActualBytes() throws {
        let fixture = try ModelIntegrityFixture()
        defer { fixture.remove() }
        try fixture.write(Data("abcd".utf8), to: "weights.bin")
        let manifest = try manifestData(files: [
            ManifestFile(path: "weights.bin", size: 3, sha256: abcSHA256)
        ])

        XCTAssertThrowsError(
            try ModelFiles.verifyIntegrity(
                modelID: modelID,
                directory: fixture.modelDirectory,
                manifestData: manifest
            )
        ) { error in
            XCTAssertEqual(
                error as? ModelIntegrityError,
                .sizeMismatch(path: "weights.bin", expected: 3, actual: 4)
            )
        }
    }

    func testSHA256MismatchReportsExpectedAndActualDigests() throws {
        let fixture = try ModelIntegrityFixture()
        defer { fixture.remove() }
        try fixture.write(Data("abd".utf8), to: "weights.bin")
        let manifest = try manifestData(files: [
            ManifestFile(path: "weights.bin", size: 3, sha256: abcSHA256)
        ])
        let abdSHA256 = "a52d159f262b2c6ddb724a61840befc36eb30c88877a4030b65cbe86298449c9"

        XCTAssertThrowsError(
            try ModelFiles.verifyIntegrity(
                modelID: modelID,
                directory: fixture.modelDirectory,
                manifestData: manifest
            )
        ) { error in
            XCTAssertEqual(
                error as? ModelIntegrityError,
                .checksumMismatch(
                    path: "weights.bin",
                    expected: self.abcSHA256,
                    actual: abdSHA256
                )
            )
        }
    }

    func testSymbolicLinkIsRejectedWithoutFollowingIt() throws {
        let fixture = try ModelIntegrityFixture()
        defer { fixture.remove() }
        let external = fixture.root.appendingPathComponent("external.bin")
        try Data("abc".utf8).write(to: external)
        try FileManager.default.createSymbolicLink(
            at: fixture.modelDirectory.appendingPathComponent("weights.bin"),
            withDestinationURL: external
        )
        let manifest = try manifestData(files: [
            ManifestFile(path: "weights.bin", size: 3, sha256: abcSHA256)
        ])

        XCTAssertThrowsError(
            try ModelFiles.verifyIntegrity(
                modelID: modelID,
                directory: fixture.modelDirectory,
                manifestData: manifest
            )
        ) { error in
            XCTAssertEqual(error as? ModelIntegrityError, .symbolicLink(path: "weights.bin"))
        }
    }

    func testSymbolicLinkInParentPathIsRejectedWithoutFollowingIt() throws {
        let fixture = try ModelIntegrityFixture()
        defer { fixture.remove() }
        let externalDirectory = fixture.root.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(
            at: externalDirectory,
            withIntermediateDirectories: true
        )
        try Data("abc".utf8).write(
            to: externalDirectory.appendingPathComponent("weights.bin")
        )
        try FileManager.default.createSymbolicLink(
            at: fixture.modelDirectory.appendingPathComponent("nested"),
            withDestinationURL: externalDirectory
        )
        let manifest = try manifestData(files: [
            ManifestFile(path: "nested/weights.bin", size: 3, sha256: abcSHA256)
        ])

        XCTAssertThrowsError(
            try ModelFiles.verifyIntegrity(
                modelID: modelID,
                directory: fixture.modelDirectory,
                manifestData: manifest
            )
        ) { error in
            XCTAssertEqual(
                error as? ModelIntegrityError,
                .symbolicLink(path: "nested/weights.bin")
            )
        }
    }

    func testMissingModelEntryFailsClosed() throws {
        let fixture = try ModelIntegrityFixture()
        defer { fixture.remove() }
        try fixture.write(Data("abc".utf8), to: "weights.bin")
        let manifest = try manifestData(modelID: "another-model", files: [
            ManifestFile(path: "weights.bin", size: 3, sha256: abcSHA256)
        ])

        XCTAssertThrowsError(
            try ModelFiles.verifyIntegrity(
                modelID: modelID,
                directory: fixture.modelDirectory,
                manifestData: manifest
            )
        ) { error in
            XCTAssertEqual(error as? ModelIntegrityError, .missingModel(modelID))
        }
    }

    func testMalformedDigestFailsWithItsRelativePath() throws {
        let fixture = try ModelIntegrityFixture()
        defer { fixture.remove() }
        try fixture.write(Data("abc".utf8), to: "weights.bin")
        let manifest = try manifestData(files: [
            ManifestFile(path: "weights.bin", size: 3, sha256: String(repeating: "g", count: 64))
        ])

        XCTAssertThrowsError(
            try ModelFiles.verifyIntegrity(
                modelID: modelID,
                directory: fixture.modelDirectory,
                manifestData: manifest
            )
        ) { error in
            XCTAssertEqual(error as? ModelIntegrityError, .malformedDigest(path: "weights.bin"))
        }
    }

    func testInvalidJSONFailsAsMalformedManifest() throws {
        let fixture = try ModelIntegrityFixture()
        defer { fixture.remove() }
        let invalidJSON = Data("{not-json".utf8)

        XCTAssertThrowsError(
            try ModelFiles.verifyIntegrity(
                modelID: modelID,
                directory: fixture.modelDirectory,
                manifestData: invalidJSON
            )
        ) { error in
            XCTAssertEqual(error as? ModelIntegrityError, .malformedManifest)
        }
    }

    func testUnknownSchemaVersionFailsAsMalformedManifest() throws {
        let fixture = try ModelIntegrityFixture()
        defer { fixture.remove() }
        try fixture.write(Data("abc".utf8), to: "weights.bin")
        let manifest = try manifestData(schemaVersion: 2, files: [
            ManifestFile(path: "weights.bin", size: 3, sha256: abcSHA256)
        ])

        XCTAssertThrowsError(
            try ModelFiles.verifyIntegrity(
                modelID: modelID,
                directory: fixture.modelDirectory,
                manifestData: manifest
            )
        ) { error in
            XCTAssertEqual(error as? ModelIntegrityError, .malformedManifest)
        }
    }

    func testEmptyFileInventoryFailsAsMalformedManifest() throws {
        let fixture = try ModelIntegrityFixture()
        defer { fixture.remove() }
        let manifest = try manifestData(files: [])

        XCTAssertThrowsError(
            try ModelFiles.verifyIntegrity(
                modelID: modelID,
                directory: fixture.modelDirectory,
                manifestData: manifest
            )
        ) { error in
            XCTAssertEqual(error as? ModelIntegrityError, .malformedManifest)
        }
    }

    func testMalformedRevisionFailsAsMalformedManifest() throws {
        let fixture = try ModelIntegrityFixture()
        defer { fixture.remove() }
        try fixture.write(Data("abc".utf8), to: "weights.bin")
        let manifest = try manifestData(revision: "main", files: [
            ManifestFile(path: "weights.bin", size: 3, sha256: abcSHA256)
        ])

        XCTAssertThrowsError(
            try ModelFiles.verifyIntegrity(
                modelID: modelID,
                directory: fixture.modelDirectory,
                manifestData: manifest
            )
        ) { error in
            XCTAssertEqual(error as? ModelIntegrityError, .malformedManifest)
        }
    }

    func testMalformedRepositoryFailsAsMalformedManifest() throws {
        let fixture = try ModelIntegrityFixture()
        defer { fixture.remove() }
        try fixture.write(Data("abc".utf8), to: "weights.bin")
        let manifest = try manifestData(repository: "missing-repository-name", files: [
            ManifestFile(path: "weights.bin", size: 3, sha256: abcSHA256)
        ])

        XCTAssertThrowsError(
            try ModelFiles.verifyIntegrity(
                modelID: modelID,
                directory: fixture.modelDirectory,
                manifestData: manifest
            )
        ) { error in
            XCTAssertEqual(error as? ModelIntegrityError, .malformedManifest)
        }
    }

    func testFilePathTraversalFailsAsMalformedManifest() throws {
        let fixture = try ModelIntegrityFixture()
        defer { fixture.remove() }
        try Data("abc".utf8).write(to: fixture.root.appendingPathComponent("outside.bin"))
        let manifest = try manifestData(files: [
            ManifestFile(path: "../outside.bin", size: 3, sha256: abcSHA256)
        ])

        XCTAssertThrowsError(
            try ModelFiles.verifyIntegrity(
                modelID: modelID,
                directory: fixture.modelDirectory,
                manifestData: manifest
            )
        ) { error in
            XCTAssertEqual(error as? ModelIntegrityError, .malformedManifest)
        }
    }

    func testRemotePathPrefixTraversalFailsAsMalformedManifest() throws {
        let fixture = try ModelIntegrityFixture()
        defer { fixture.remove() }
        try fixture.write(Data("abc".utf8), to: "weights.bin")
        let manifest = try manifestData(remotePathPrefix: "../outside", files: [
            ManifestFile(path: "weights.bin", size: 3, sha256: abcSHA256)
        ])

        XCTAssertThrowsError(
            try ModelFiles.verifyIntegrity(
                modelID: modelID,
                directory: fixture.modelDirectory,
                manifestData: manifest
            )
        ) { error in
            XCTAssertEqual(error as? ModelIntegrityError, .malformedManifest)
        }
    }

    func testDuplicateFilePathsFailAsMalformedManifest() throws {
        let fixture = try ModelIntegrityFixture()
        defer { fixture.remove() }
        try fixture.write(Data("abc".utf8), to: "weights.bin")
        let duplicate = ManifestFile(path: "weights.bin", size: 3, sha256: abcSHA256)
        let manifest = try manifestData(files: [duplicate, duplicate])

        XCTAssertThrowsError(
            try ModelFiles.verifyIntegrity(
                modelID: modelID,
                directory: fixture.modelDirectory,
                manifestData: manifest
            )
        ) { error in
            XCTAssertEqual(error as? ModelIntegrityError, .malformedManifest)
        }
    }

    private func manifestData(
        schemaVersion: Int = 1,
        modelID: String = "fixture-model",
        repository: String = "owner/repository",
        revision: String = String(repeating: "a", count: 40),
        remotePathPrefix: String = "artifacts",
        files: [ManifestFile]
    ) throws -> Data {
        let model: [String: Any] = [
            "repository": repository,
            "revision": revision,
            "remotePathPrefix": remotePathPrefix,
            "files": files.map { file in
                [
                    "path": file.path,
                    "size": file.size,
                    "sha256": file.sha256
                ]
            }
        ]

        return try JSONSerialization.data(withJSONObject: [
            "schemaVersion": schemaVersion,
            "models": [modelID: model]
        ])
    }

    private func bundledManifest() throws -> PinnedModelManifest {
        let bundle = Bundle(for: Self.self)
        let manifestURL = try XCTUnwrap(
            bundle.url(forResource: "ModelIntegrityManifest", withExtension: "json"),
            "The test bundle must contain the reviewed model manifest"
        )
        return try JSONDecoder().decode(
            PinnedModelManifest.self,
            from: Data(contentsOf: manifestURL)
        )
    }

    private func assertUnlistedCoreMLBundleBlocksLoad(_ bundleName: String) async throws {
        let fixture = try ModelIntegrityFixture()
        defer { fixture.remove() }
        try fixture.write(Data("abc".utf8), to: "weights.bin")
        try fixture.write(Data("unreviewed graph".utf8), to: "\(bundleName)/model.mil")
        let manifest = try manifestData(files: [
            ManifestFile(path: "weights.bin", size: 3, sha256: abcSHA256)
        ])
        var loadCount = 0

        do {
            let _: String = try await ModelFiles.withVerifiedModel(
                modelID: modelID, directory: fixture.modelDirectory, manifestData: manifest
            ) {
                loadCount += 1
                return "loaded"
            }
            XCTFail("\(bundleName) must not bypass the manifest")
        } catch {
            XCTAssertEqual(error as? ModelIntegrityError,
                           .unexpectedFile(path: bundleName))
        }

        XCTAssertEqual(loadCount, 0)
    }

    private func assertTokenizerParity(modelID: String, repositoryName: String) throws {
        let cache = AppPaths.models
            .appendingPathComponent("models/openai", isDirectory: true)
            .appendingPathComponent(repositoryName, isDirectory: true)
        try XCTSkipUnless(
            ["tokenizer.json", "tokenizer_config.json"].allSatisfy {
                FileManager.default.fileExists(atPath: cache.appendingPathComponent($0).path)
            },
            "Optional official tokenizer cache is absent; no network download in tests"
        )
        // Verify a private copy: successful verification records stamps in the folder it
        // checks, and a test must never write into the user's real model cache.
        let fixture = try ModelIntegrityFixture()
        defer { fixture.remove() }
        let directory = fixture.modelDirectory
        for name in ["tokenizer.json", "tokenizer_config.json"] {
            try FileManager.default.copyItem(
                at: cache.appendingPathComponent(name), to: directory.appendingPathComponent(name)
            )
        }
        let tokenizerURL = directory.appendingPathComponent("tokenizer.json")
        let configURL = directory.appendingPathComponent("tokenizer_config.json")
        try ModelFiles.verifyBundledIntegrity(
            modelID: modelID, directory: directory, bundle: Bundle(for: Self.self)
        )
        let configBytes = try Data(contentsOf: configURL)
        let tokenizerBytes = try Data(contentsOf: tokenizerURL)
        let config = try JSONDecoder().decode(Config.self, from: configBytes)
        let data = try JSONDecoder().decode(Config.self, from: tokenizerBytes)
        let upstreamConfig = try YYJSONParser.parseToConfig(configBytes)
        let upstreamData = try YYJSONParser.parseToConfig(tokenizerBytes)
        XCTAssertEqual(config, upstreamConfig,
                       "\(modelID): config parser diverged from upstream YYJSON")
        XCTAssertEqual(data, upstreamData,
                       "\(modelID): tokenizer parser diverged from upstream YYJSON")
        let reference = WhisperTokenizerWrapper(
            tokenizer: try PreTrainedTokenizer(
                tokenizerConfig: upstreamConfig, tokenizerData: upstreamData
            )
        )
        let verified = VerifiedWhisperTokenizer(
            tokenizer: try PreTrainedTokenizer(tokenizerConfig: config, tokenizerData: data)
        )

        XCTAssertEqual(
            specialTokenValues(verified.specialTokens),
            specialTokenValues(reference.specialTokens),
            "\(modelID): special token IDs diverged from WhisperKit 0.18.0"
        )
        XCTAssertEqual(verified.allLanguageTokens, reference.allLanguageTokens,
                       "\(modelID): multilingual token set diverged")

        let samples = [
            "Ciao, come stai?",
            "Guten Morgen, Straße!",
            "Hello world!",
            "😀👨‍👩‍👧‍👦",
            "你好世界"
        ]
        for sample in samples {
            let expectedTokens = reference.encode(text: sample)
            let actualTokens = verified.encode(text: sample)
            XCTAssertEqual(actualTokens, expectedTokens,
                           "\(modelID): encoding differs for \(sample)")
            XCTAssertEqual(verified.decode(tokens: actualTokens),
                           reference.decode(tokens: expectedTokens),
                           "\(modelID): decoding differs for \(sample)")

            let expectedWords = reference.splitToWordTokens(tokenIds: expectedTokens)
            let actualWords = verified.splitToWordTokens(tokenIds: actualTokens)
            XCTAssertEqual(actualWords.words, expectedWords.words,
                           "\(modelID): word splitting differs for \(sample)")
            XCTAssertEqual(actualWords.wordTokens, expectedWords.wordTokens,
                           "\(modelID): word-token grouping differs for \(sample)")
        }
    }

    private func specialTokenValues(_ tokens: SpecialTokens) -> [Int] {
        [
            tokens.endToken,
            tokens.englishToken,
            tokens.noSpeechToken,
            tokens.noTimestampsToken,
            tokens.specialTokenBegin,
            tokens.startOfPreviousToken,
            tokens.startOfTranscriptToken,
            tokens.timeTokenBegin,
            tokens.transcribeToken,
            tokens.translateToken,
            tokens.whitespaceToken
        ]
    }
}

private enum LocalLoaderFailure: Error, Equatable {
    case simulated
}

private struct PinnedModelManifest: Decodable {
    let models: [String: PinnedModel]

    struct PinnedModel: Decodable {
        let repository: String
        let revision: String
        let files: [PinnedFile]
    }

    struct PinnedFile: Decodable, Equatable {
        let path: String
        let size: Int64
        let sha256: String
    }
}

private struct ManifestFile {
    let path: String
    let size: Int
    let sha256: String
}

private final class ModelIntegrityFixture {
    let root: URL
    let modelDirectory: URL

    init(fileManager: FileManager = .default) throws {
        root = fileManager.temporaryDirectory
            .appendingPathComponent(
                "DictariModelIntegrityTests-" + UUID().uuidString,
                isDirectory: true
            )
        modelDirectory = root.appendingPathComponent("model", isDirectory: true)
        try fileManager.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
    }

    func write(_ data: Data, to relativePath: String) throws {
        let destination = modelDirectory.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: destination)
    }

    func makeBundle(manifestData: Data?) throws -> Bundle {
        let bundleRoot = root.appendingPathComponent("Fixture.bundle", isDirectory: true)
        let contents = bundleRoot.appendingPathComponent("Contents", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let info: [String: String] = [
            "CFBundleIdentifier": "com.dictari.integrity-fixture",
            "CFBundleName": "IntegrityFixture",
            "CFBundlePackageType": "BNDL",
            "CFBundleVersion": "1"
        ]
        let plist = try PropertyListSerialization.data(
            fromPropertyList: info, format: .xml, options: 0
        )
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        if let manifestData {
            try manifestData.write(
                to: resources.appendingPathComponent("ModelIntegrityManifest.json")
            )
        }
        guard let bundle = Bundle(url: bundleRoot) else {
            throw NSError(domain: "DictariModelIntegrityTests", code: 1)
        }
        return bundle
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
