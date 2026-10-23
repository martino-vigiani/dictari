import Foundation
import XCTest

final class DictationRecoveryStoreTests: XCTestCase {

    private var rootURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dictari-recovery-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: rootURL)
        rootURL = nil
        try super.tearDownWithError()
    }

    /// Regression: a long dictation must remain replayable after an inference failure and a
    /// process restart. Four minutes at the engine's 16 kHz Float32 format is 15.36 MB.
    func testFourMinuteTranscriptionFailureRoundTripsAcrossANewStoreInstance() throws {
        // Arrange
        let samples = fourMinutesOfSamples()
        let createdAt = Date(timeIntervalSinceReferenceDate: 42)
        let store = try makeStore()

        // Act
        let saved = try store.save(
            samples: samples,
            durationSeconds: 240,
            language: "en",
            modelID: "parakeet-v3",
            appName: "Xcode",
            appBundleID: "com.apple.dt.Xcode",
            state: .transcriptionFailed,
            failureDescription: "The model stopped responding",
            createdAt: createdAt
        )
        let reloadedStore = try makeStore()
        let recovered = try reloadedStore.load(saved.id)

        // Assert
        XCTAssertEqual(recovered.recovery, saved)
        XCTAssertEqual(recovered.samples, samples)
    }

    func testInjectionFailureRetainsTheOriginalSamplesAcrossANewStoreInstance() throws {
        // Arrange
        let samples: [Float] = [0.125, -0.5, 0.75]
        let store = try makeStore()
        let saved = try store.save(
            samples: samples,
            durationSeconds: 0.000_187_5,
            language: "it",
            modelID: "parakeet-v3",
            state: .transcriptionFailed,
            failureDescription: "Initial transcription failed"
        )

        // Act
        let updated = try store.update(
            saved.id,
            state: .injectionFailed,
            failureDescription: "Paste was not confirmed",
            transcript: "kubectl apply"
        )

        // Assert
        XCTAssertEqual(updated.state, .injectionFailed)
        XCTAssertEqual(updated.failureDescription, "Paste was not confirmed")
        XCTAssertEqual(updated.transcript, "kubectl apply")
        let reloadedStore = try makeStore()
        let recovered = try reloadedStore.load(saved.id)
        XCTAssertEqual(recovered.recovery, updated)
        XCTAssertEqual(recovered.samples, samples)
    }

    func testLowSignalAndEmptyPCMRoundTripAcrossANewStoreInstance() throws {
        // Arrange
        let store = try makeStore()
        let lowSignalSamples: [Float] = [-0.000_001, 0, 0.000_001]
        let lowSignal = try store.save(
            samples: lowSignalSamples,
            durationSeconds: 0.000_187_5,
            language: "auto",
            modelID: "parakeet-v3",
            state: .transcriptionFailed,
            failureDescription: "Low signal",
            createdAt: Date(timeIntervalSinceReferenceDate: 1)
        )
        let empty = try store.save(
            samples: [],
            durationSeconds: 0,
            language: "auto",
            modelID: "parakeet-v3",
            state: .transcriptionFailed,
            failureDescription: "Empty capture",
            createdAt: Date(timeIntervalSinceReferenceDate: 2)
        )

        // Act
        let reloadedStore = try makeStore()

        // Assert
        XCTAssertEqual(try reloadedStore.load(lowSignal.id).samples, lowSignalSamples)
        XCTAssertEqual(try reloadedStore.load(empty.id).samples, [])
        XCTAssertEqual(try reloadedStore.recoveries().map(\.id), [empty.id, lowSignal.id])
    }

    func testExplicitDeleteIsTheOnlyRemovalAfterTranscription() throws {
        // Arrange
        let store = try makeStore()
        let saved = try saveRecovery(store: store, createdAt: Date(timeIntervalSinceReferenceDate: 1))

        // Act
        let transcribed = try store.markTranscribed(saved.id, transcript: "retryable text")
        let beforeDeletion = try makeStore()

        // Assert
        XCTAssertEqual(try beforeDeletion.load(saved.id).recovery, transcribed)
        XCTAssertEqual(try beforeDeletion.load(saved.id).samples, [0.25])

        // Act
        try beforeDeletion.delete(saved.id)

        // Assert
        let afterDeletion = try makeStore()
        XCTAssertTrue(try afterDeletion.recoveries().isEmpty)
        XCTAssertThrowsError(try afterDeletion.load(saved.id)) { error in
            XCTAssertEqual(error as? DictationRecoveryStore.StoreError, .missing(saved.id))
        }
    }

    /// Regression: malformed metadata must not make saved PCM disappear from the recovery UI.
    func testRecoveriesExposeMalformedMetadataAsADeletableDiagnosticRecord() throws {
        // Arrange
        let store = try makeStore()
        let valid = try saveRecovery(store: store, createdAt: Date(timeIntervalSinceReferenceDate: 1))
        let damagedID = UUID()
        let damaged = rootURL.appendingPathComponent(damagedID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: damaged, withIntermediateDirectories: false)
        try Data("not json".utf8).write(to: damaged.appendingPathComponent("metadata.json"))
        let pcm = [Float](repeating: 0.25, count: DictationRecoveryStore.sampleRate)
        let pcmData = pcm.withUnsafeBufferPointer { Data(buffer: $0) }
        try pcmData.write(to: damaged.appendingPathComponent("audio.pcm"))

        // Act
        let recoveries = try store.recoveries()

        // Assert
        XCTAssertEqual(Set(recoveries.map(\.id)), Set([damagedID, valid.id]))
        let diagnostic = try XCTUnwrap(recoveries.first { $0.id == damagedID })
        XCTAssertEqual(diagnostic.state, .metadataDamaged)
        XCTAssertEqual(diagnostic.durationSeconds, 1, accuracy: 0.001)
        XCTAssertEqual(
            diagnostic.failureDescription,
            "Saved recording metadata is damaged; audio remains on this Mac"
        )
    }

    func testMalformedMetadataWithoutPCMDoesNotClaimThatAudioRemains() throws {
        let store = try makeStore()
        let damagedID = UUID()
        let damaged = rootURL.appendingPathComponent(damagedID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: damaged, withIntermediateDirectories: false)
        try Data("not json".utf8).write(to: damaged.appendingPathComponent("metadata.json"))

        let diagnostic = try XCTUnwrap(try store.recoveries().first { $0.id == damagedID })

        XCTAssertEqual(diagnostic.state, .metadataDamaged)
        XCTAssertEqual(diagnostic.durationSeconds, 0)
        XCTAssertEqual(diagnostic.failureDescription, "Saved recording metadata and audio are damaged")
        XCTAssertFalse(diagnostic.failureDescription.localizedCaseInsensitiveContains("remains"))
    }

    func testValidMetadataWithMissingOrMisalignedPCMBecomesDiagnosticOnly() throws {
        let store = try makeStore()
        let missing = try saveRecovery(store: store, createdAt: Date(timeIntervalSinceReferenceDate: 1))
        let misaligned = try saveRecovery(store: store, createdAt: Date(timeIntervalSinceReferenceDate: 2))
        try FileManager.default.removeItem(
            at: rootURL.appendingPathComponent(missing.id.uuidString).appendingPathComponent("audio.pcm")
        )
        try Data([0]).write(
            to: rootURL.appendingPathComponent(misaligned.id.uuidString).appendingPathComponent("audio.pcm")
        )

        let diagnostics = try store.recoveries()
        let missingDiagnostic = try XCTUnwrap(diagnostics.first { $0.id == missing.id })
        let misalignedDiagnostic = try XCTUnwrap(diagnostics.first { $0.id == misaligned.id })

        for diagnostic in [missingDiagnostic, misalignedDiagnostic] {
            XCTAssertEqual(diagnostic.state, .metadataDamaged)
            XCTAssertEqual(diagnostic.failureDescription, "Saved recording audio is missing or damaged")
        }
    }

    /// Regression: an active writer can still own a newly-created temporary directory when a
    /// second store instance opens the same root. Startup cleanup must not delete that writer's
    /// in-flight capture.
    func testInitializingStorePreservesRecentlyCreatedTemporaryDirectory() throws {
        // Arrange
        let store = try makeStore()
        let valid = try saveRecovery(store: store)
        let temporary = rootURL.appendingPathComponent(".\(UUID().uuidString).tmp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        try Data([0]).write(to: temporary.appendingPathComponent("audio.pcm"))

        // Act
        let reloadedStore = try makeStore()

        // Assert
        XCTAssertTrue(FileManager.default.fileExists(atPath: temporary.path))
        XCTAssertEqual(try reloadedStore.load(valid.id).recovery, valid)
    }

    /// Regression: only stale directories left behind before the final rename are clutter. A
    /// directory matching the private temporary name is eligible after its filesystem metadata
    /// is old enough, while final recoveries remain untouched.
    func testInitializingStoreRemovesAnOldInterruptedTemporaryDirectoryWithoutTouchingFinalRecovery() throws {
        // Arrange
        let store = try makeStore()
        let valid = try saveRecovery(store: store)
        let temporary = rootURL.appendingPathComponent(".\(UUID().uuidString).tmp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        try Data([0]).write(to: temporary.appendingPathComponent("audio.pcm"))
        try setModificationDate(of: temporary, to: Date().addingTimeInterval(-3_600))

        // Act
        let reloadedStore = try makeStore()

        // Assert
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
        XCTAssertEqual(try reloadedStore.load(valid.id).recovery, valid)
    }

    func testInitializingStorePreservesOldDirectoriesOutsidePrivateTemporaryName() throws {
        _ = try makeStore()
        let names = [".notes", ".not-a-uuid.tmp-\(UUID().uuidString)",
                     ".\(UUID().uuidString).tmp-invalid",
                     ".\(UUID().uuidString).tmp-\(UUID().uuidString).backup",
                     UUID().uuidString]
        let sentinel = Data([1, 2, 3, 4])
        for name in names {
            let directory = rootURL.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            try sentinel.write(to: directory.appendingPathComponent("audio.pcm"))
            try setModificationDate(of: directory, to: Date().addingTimeInterval(-3_600))
        }
        _ = try makeStore()
        for name in names {
            XCTAssertEqual(try Data(contentsOf: rootURL.appendingPathComponent(name)
                .appendingPathComponent("audio.pcm")), sentinel)
        }
    }

    func testInitializingStorePreservesOldRegularFileWithPrivateTemporaryName() throws {
        _ = try makeStore()
        let file = rootURL.appendingPathComponent(".\(UUID().uuidString).tmp-\(UUID().uuidString)")
        let sentinel = Data([5, 6, 7])
        try sentinel.write(to: file)
        try setModificationDate(of: file, to: Date().addingTimeInterval(-3_600))
        _ = try makeStore()
        XCTAssertEqual(try Data(contentsOf: file), sentinel)
    }

    func testMarkingOneRecoveryTranscribedRetainsEveryRecordAcrossANewStoreInstance() throws {
        // Arrange
        let store = try makeStore()
        let failed = try saveRecovery(store: store, state: .transcriptionFailed,
                                      createdAt: Date(timeIntervalSinceReferenceDate: 1))
        let selected = try saveRecovery(store: store,
                                        createdAt: Date(timeIntervalSinceReferenceDate: 2))
        let previousSuccess = try saveRecovery(store: store, state: .transcribed,
                                               createdAt: Date(timeIntervalSinceReferenceDate: 3))

        // Act
        let updated = try store.markTranscribed(selected.id, transcript: "retryable text")
        let reloadedStore = try makeStore()

        // Assert
        let recoveries = try reloadedStore.recoveries()
        XCTAssertEqual(recoveries.map(\.id), [previousSuccess.id, updated.id, failed.id])
        XCTAssertEqual(recoveries.map(\.state), [.transcribed, .transcribed, .transcriptionFailed])
        XCTAssertEqual(try reloadedStore.load(previousSuccess.id).samples, [0.25])
        XCTAssertEqual(try reloadedStore.load(updated.id).samples, [0.25])
        XCTAssertEqual(try reloadedStore.load(failed.id).samples, [0.25])
    }

    func testConcurrentTranscribedCompletionsRetainEveryRecoveryAcrossANewStoreInstance() async throws {
        // Arrange
        let firstStore = try makeStore()
        let first = try saveRecovery(store: firstStore, createdAt: Date(timeIntervalSinceReferenceDate: 1))
        let secondStore = try makeStore()
        let second = try saveRecovery(store: secondStore, createdAt: Date(timeIntervalSinceReferenceDate: 2))
        let rootURL = try XCTUnwrap(rootURL)

        // Act
        let completedRecoveries = try await withThrowingTaskGroup(of: DictationRecovery.self) { group in
            group.addTask {
                try DictationRecoveryStore(rootURL: rootURL)
                    .markTranscribed(first.id, transcript: "first")
            }
            group.addTask {
                try DictationRecoveryStore(rootURL: rootURL)
                    .markTranscribed(second.id, transcript: "second")
            }

            var recoveries: [DictationRecovery] = []
            for try await recovery in group {
                recoveries.append(recovery)
            }
            return recoveries
        }
        let reloadedRecoveries = try makeStore().recoveries()

        // Assert
        XCTAssertEqual(Set(completedRecoveries.map(\.id)), Set([first.id, second.id]))
        XCTAssertEqual(reloadedRecoveries.map(\.id), [second.id, first.id])
        XCTAssertEqual(reloadedRecoveries.map(\.state), [.transcribed, .transcribed])
        XCTAssertEqual(reloadedRecoveries.map(\.transcript), ["second", "first"])
    }

    private func makeStore() throws -> DictationRecoveryStore {
        try DictationRecoveryStore(rootURL: rootURL)
    }

    private func fourMinutesOfSamples() -> [Float] {
        let count = DictationRecoveryStore.sampleRate * 60 * 4
        var samples = [Float](repeating: 0.125, count: count)
        samples[0] = -1
        samples[count / 2] = 0.5
        samples[count - 1] = 1
        return samples
    }

    private func setModificationDate(of url: URL, to date: Date) throws {
        var url = url
        var values = URLResourceValues()
        values.contentModificationDate = date
        try url.setResourceValues(values)
    }

    private func saveRecovery(
        store: DictationRecoveryStore,
        state: DictationRecoveryState = .transcriptionFailed,
        createdAt: Date = Date()
    ) throws -> DictationRecovery {
        try store.save(
            samples: [0.25],
            durationSeconds: 0.000_062_5,
            language: "auto",
            modelID: "parakeet-v3",
            state: state,
            failureDescription: "Failed",
            createdAt: createdAt
        )
    }
}
