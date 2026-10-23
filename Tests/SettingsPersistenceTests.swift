// SettingsPersistenceTests.swift
// Regression tests for the settings bugs found on the first Parakeet run.
//
// Two of them were silent data loss: adding a key to SettingsData reset every preference,
// and the Parakeet migration lived only in memory. Neither produced an error message, which
// is exactly why they need tests rather than a manual check.

import XCTest

final class SettingsPersistenceTests: XCTestCase {

    // MARK: - Ordered writes

    @MainActor
    func testRapidSettingsEditsFlushOnlyTheLatestSnapshot() async throws {
        let fileURL = try temporaryFileURL(named: "settings.json")
        let store = SettingsStore(fileURL: fileURL, saveDebounce: .seconds(60))

        for wpm in 80..<100 {
            store.data.assumedTypingWPM = wpm
        }
        try await store.flushPendingWrites()

        let persisted = try JSONDecoder().decode(
            SettingsData.self,
            from: Data(contentsOf: fileURL)
        )
        let diagnostics = await store.persistenceDiagnostics()
        XCTAssertEqual(persisted.assumedTypingWPM, 99)
        XCTAssertEqual(diagnostics.writeCount, 1)
        XCTAssertEqual(diagnostics.durableRevision, 20)
    }

    func testWriterRejectsAnOlderRevisionAfterTheLatestIsDurable() async throws {
        let fileURL = try temporaryFileURL(named: "ordered-settings.json")
        let writer = LatestJSONSnapshotWriter<SettingsData>(fileURL: fileURL)
        var old = SettingsData()
        old.assumedTypingWPM = 81
        var latest = SettingsData()
        latest.assumedTypingWPM = 123

        try await writer.persist(latest, revision: 2)
        try await writer.persist(old, revision: 1)

        let persisted = try JSONDecoder().decode(
            SettingsData.self,
            from: Data(contentsOf: fileURL)
        )
        let diagnostics = await writer.diagnostics()
        XCTAssertEqual(persisted.assumedTypingWPM, 123)
        XCTAssertEqual(diagnostics.writeCount, 1)
        XCTAssertEqual(diagnostics.durableRevision, 2)
    }

    func testOneHundredConcurrentBurstsAlwaysPersistTheirLatestRevision() async throws {
        let marker = try temporaryFileURL(named: "cleanup-marker")
        let directory = marker.deletingLastPathComponent()

        for burst in 0..<100 {
            let fileURL = directory.appendingPathComponent("burst-\(burst).json")
            let writer = LatestJSONSnapshotWriter<SettingsData>(fileURL: fileURL)

            await withTaskGroup(of: Void.self) { group in
                for revision in 1...20 {
                    var snapshot = SettingsData()
                    snapshot.activeModelID = "revision-\(revision)"
                    group.addTask {
                        try? await writer.persist(snapshot, revision: UInt(revision))
                    }
                }
            }

            let persisted = try JSONDecoder().decode(
                SettingsData.self,
                from: Data(contentsOf: fileURL)
            )
            XCTAssertEqual(
                persisted.activeModelID,
                "revision-20",
                "burst \(burst) finished with an older snapshot"
            )
        }
    }

    @MainActor
    func testRapidHistoryMutationsFlushTheLatestArrayOnce() async throws {
        let fileURL = try temporaryFileURL(named: "history.json")
        let store = HistoryStore(fileURL: fileURL, saveDebounce: .seconds(60))

        for index in 0..<20 {
            store.add(
                HistoryEntry(
                    date: Date(timeIntervalSince1970: Double(index)),
                    text: "Entry \(index)",
                    durationSeconds: 1,
                    wordCount: 2,
                    latencyMs: index,
                    appName: nil,
                    appBundleID: nil,
                    language: "en",
                    tag: nil,
                    speechLevel: nil
                )
            )
        }
        try await store.flushPendingWrites()

        let persisted = try JSONDecoder().decode(
            [HistoryEntry].self,
            from: Data(contentsOf: fileURL)
        )
        let diagnostics = await store.persistenceDiagnostics()
        XCTAssertEqual(persisted.count, 20)
        XCTAssertEqual(persisted.first?.text, "Entry 19")
        XCTAssertEqual(diagnostics.writeCount, 1)
        XCTAssertEqual(diagnostics.durableRevision, 20)
    }

    @MainActor
    func testFlushIncludesAnEditSubmittedWhileItsFirstWriteIsInFlight() async throws {
        let fileURL = try temporaryFileURL(named: "reentrant-settings.json")
        let barrier = OneShotPersistenceBarrier()
        let store = SettingsStore(
            fileURL: fileURL,
            saveDebounce: .seconds(60),
            beforePersistenceWrite: { await barrier.pauseFirstWrite() }
        )
        store.data.assumedTypingWPM = 80

        let flushTask = Task { @MainActor in
            try await store.flushPendingWrites()
        }
        await barrier.waitUntilPaused()
        store.data.assumedTypingWPM = 115
        await barrier.resume()
        try await flushTask.value

        let persisted = try JSONDecoder().decode(
            SettingsData.self,
            from: Data(contentsOf: fileURL)
        )
        let diagnostics = await store.persistenceDiagnostics()
        XCTAssertEqual(persisted.assumedTypingWPM, 115)
        XCTAssertEqual(diagnostics.durableRevision, 2)
    }

    @MainActor
    func testTerminationBarrierReflushesSettingsChangedDuringHistoryWrite() async throws {
        let settingsURL = try temporaryFileURL(named: "termination-settings.json")
        let historyURL = settingsURL.deletingLastPathComponent()
            .appendingPathComponent("termination-history.json")
        let historyBarrier = OneShotPersistenceBarrier()
        let settings = SettingsStore(fileURL: settingsURL, saveDebounce: .seconds(60))
        let history = HistoryStore(
            fileURL: historyURL,
            saveDebounce: .seconds(60),
            beforePersistenceWrite: { await historyBarrier.pauseFirstWrite() }
        )
        settings.data.assumedTypingWPM = 80
        history.add(
            HistoryEntry(
                date: Date(timeIntervalSince1970: 1),
                text: "Pending history",
                durationSeconds: 1,
                wordCount: 2,
                latencyMs: 10,
                appName: nil,
                appBundleID: nil,
                language: "en",
                tag: nil,
                speechLevel: nil
            )
        )

        let terminationFlush = Task { @MainActor in
            try await flushUserDataUntilStable(settings: settings, history: history)
        }
        await historyBarrier.waitUntilPaused()
        settings.data.assumedTypingWPM = 115
        await historyBarrier.resume()
        try await terminationFlush.value

        let persistedSettings = try JSONDecoder().decode(
            SettingsData.self,
            from: Data(contentsOf: settingsURL)
        )
        let persistedHistory = try JSONDecoder().decode(
            [HistoryEntry].self,
            from: Data(contentsOf: historyURL)
        )
        let settingsDiagnostics = await settings.persistenceDiagnostics()
        XCTAssertEqual(persistedSettings.assumedTypingWPM, 115)
        XCTAssertEqual(persistedHistory.first?.text, "Pending history")
        XCTAssertEqual(settingsDiagnostics.durableRevision, 2)
    }

    @MainActor
    func testFlushReportsAnUnwritableDestination() async throws {
        let store = SettingsStore(
            fileURL: URL(fileURLWithPath: "/dev/null/settings.json"),
            saveDebounce: .seconds(60)
        )
        store.data.assumedTypingWPM = 117

        do {
            try await store.flushPendingWrites()
            XCTFail("flush claimed success for an unwritable path")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }

    // MARK: - Decoding old files

    /// The synthesized Decodable throws keyNotFound for a missing non-optional property
    /// instead of falling back to its declared default. A settings file written before a key
    /// existed must still decode, or the user silently loses every preference.
    func testDecodesSettingsFileMissingTheMigrationKey() throws {
        // Reconstruct a file written before the key existed: current defaults, minus it.
        var dict = try encodedDefaultsAsDictionary()
        dict.removeValue(forKey: "didMigrateToParakeetDefault")
        let data = try JSONSerialization.data(withJSONObject: dict)

        let decoded = try XCTUnwrap(try? JSONDecoder().decode(SettingsData.self, from: data),
                                    "settings from an older build failed to decode")
        XCTAssertNil(decoded.didMigrateToParakeetDefault)
    }

    /// Preferences the user set must survive an upgrade that adds new keys.
    func testUpgradePreservesExistingPreferences() throws {
        var dict = try encodedDefaultsAsDictionary()
        dict["activeModelID"] = "large-v3-turbo"
        dict["assumedTypingWPM"] = 91
        dict["launchAtLogin"] = false
        dict.removeValue(forKey: "didMigrateToParakeetDefault")

        let data = try JSONSerialization.data(withJSONObject: dict)
        let decoded = try JSONDecoder().decode(SettingsData.self, from: data)

        XCTAssertEqual(decoded.assumedTypingWPM, 91)
        XCTAssertFalse(decoded.launchAtLogin)
    }

    // MARK: - Parakeet migration

    func testMigrationReplacesTheRetiredFinderSearchShortcut() {
        var stored = SettingsData()
        stored.dictationShortcut = .finderSearch

        let migrated = SettingsStore.migrate(stored)

        XCTAssertEqual(migrated.dictationShortcut, .defaultDictation)
        XCTAssertEqual(migrated.dictationShortcut.displayString, "⌥Space")
    }

    func testMigrationPreservesACustomShortcut() {
        var stored = SettingsData()
        let custom = Shortcut(
            keyCode: 49,
            modifiers: NSEvent.ModifierFlags([.control, .shift]).rawValue
        )
        stored.dictationShortcut = custom

        XCTAssertEqual(SettingsStore.migrate(stored).dictationShortcut, custom)
    }

    func testMigrationMovesTheOldDefaultToParakeet() {
        var stored = SettingsData()
        stored.activeModelID = "large-v3-turbo"
        stored.didMigrateToParakeetDefault = nil

        let migrated = SettingsStore.migrate(stored)

        XCTAssertEqual(migrated.activeModelID, "parakeet-v3")
        XCTAssertEqual(migrated.didMigrateToParakeetDefault, true)
    }

    /// Someone who deliberately picked a Whisper model that was never the default keeps it.
    func testMigrationLeavesAnExplicitChoiceAlone() {
        var stored = SettingsData()
        stored.activeModelID = "small"
        stored.didMigrateToParakeetDefault = nil

        let migrated = SettingsStore.migrate(stored)

        XCTAssertEqual(migrated.activeModelID, "small")
        XCTAssertEqual(migrated.didMigrateToParakeetDefault, true)
    }

    /// Once migrated, choosing Large v3 Turbo on purpose must stick across launches.
    func testMigrationDoesNotRunTwice() {
        var stored = SettingsData()
        stored.activeModelID = "large-v3-turbo"
        stored.didMigrateToParakeetDefault = true

        let migrated = SettingsStore.migrate(stored)

        XCTAssertEqual(migrated.activeModelID, "large-v3-turbo",
                       "a deliberate return to Whisper was overwritten on the next launch")
    }

    // MARK: - Helper

    private func encodedDefaultsAsDictionary() throws -> [String: Any] {
        let data = try JSONEncoder().encode(SettingsData())
        return try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    private func temporaryFileURL(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DictariPersistenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent(name)
    }
}

private actor OneShotPersistenceBarrier {
    private var didPause = false
    private var isPaused = false
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeContinuation: CheckedContinuation<Void, Never>?

    func pauseFirstWrite() async {
        guard !didPause else { return }
        didPause = true
        isPaused = true
        let waiters = pauseWaiters
        pauseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { continuation in
            resumeContinuation = continuation
        }
    }

    func waitUntilPaused() async {
        guard !isPaused else { return }
        await withCheckedContinuation { continuation in
            pauseWaiters.append(continuation)
        }
    }

    func resume() {
        isPaused = false
        resumeContinuation?.resume()
        resumeContinuation = nil
    }
}

// MARK: - Model catalog

final class ModelCatalogTests: XCTestCase {

    func testExactlyOneDefaultModel() {
        let defaults = ModelDescriptor.curated.filter(\.isDefault)
        XCTAssertEqual(defaults.count, 1, "the catalog must name exactly one default")
        XCTAssertEqual(defaults.first?.id, "parakeet-v3")
    }

    func testDefaultSettingsPointAtAnExistingModel() {
        let id = SettingsData().activeModelID
        XCTAssertNotNil(ModelDescriptor.curated.first { $0.id == id },
                        "default activeModelID \"\(id)\" is not in the catalog")
    }

    func testModelIDsAreUnique() {
        let ids = ModelDescriptor.curated.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate model ids: \(ids)")
    }

    /// `descriptor(for:)` force-unwraps the default; an unknown id must still be safe.
    func testUnknownIDFallsBackToTheDefault() {
        let d = ModelDescriptor.descriptor(for: "does-not-exist")
        XCTAssertTrue(d.isDefault)
    }

    func testOnlyParakeetUsesTheFluidAudioBackend() {
        let parakeetIDs = Set(ParakeetVariant.allCases.map(\.rawValue))
        for model in ModelDescriptor.curated {
            if parakeetIDs.contains(model.id) {
                XCTAssertEqual(model.backend, .parakeet)
                XCTAssertEqual(model.parakeetVariant?.rawValue, model.id)
            } else {
                XCTAssertEqual(model.backend, .whisperKit, "\(model.id) has the wrong backend")
                XCTAssertNil(model.parakeetVariant)
            }
        }
    }

    func testLiveTranscriptCapabilityMatchesTheStreamingBackend() {
        XCTAssertEqual(
            ModelDescriptor.curated.filter(\.supportsLiveTranscriptPreview).map(\.id),
            ["parakeet-v3", "parakeet-ultra"]
        )
    }

    /// Each Parakeet variant must load its own pinned files from its own folder: a shared
    /// folder would let the integrity check reject one variant's files as the other's.
    func testParakeetVariantsHaveDistinctFoldersAndManifestEntries() {
        let folders = ParakeetVariant.allCases.map { ModelFiles.parakeetDirectory(for: $0) }
        XCTAssertEqual(Set(folders).count, folders.count)
        XCTAssertEqual(ModelFiles.parakeetDirectory, ModelFiles.parakeetDirectory(for: .v3))
        for variant in ParakeetVariant.allCases {
            let descriptor = ModelDescriptor.descriptor(for: variant.rawValue)
            XCTAssertEqual(descriptor.id, variant.rawValue)
            XCTAssertEqual(descriptor.whisperKitName, variant.manifestModelID)
        }
    }

    /// Whisper Turbo stays available for languages Parakeet lacks, but the catalog lists it
    /// last: the order is the recommendation.
    func testWhisperTurboIsListedLast() {
        XCTAssertEqual(ModelDescriptor.curated.last?.id, "large-v3-turbo")
    }
}

// MARK: - Model download failures

/// Deterministic regression coverage for the model-download messages shown in Settings and
/// onboarding. These tests never instantiate an engine, touch its cache, or use the network.
final class ModelDownloadFailureTests: XCTestCase {

    private let model = ModelDescriptor.descriptor(for: "base")

    func testDiskFullFailureHasSpecificRecoveryAndDoesNotExposePath() {
        let error = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileWriteOutOfSpaceError,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "The file /Users/example/Library/Application Support/Dictari/model.bin could not be saved."
            ]
        )

        let failure = ModelDownloadFailure(model: model, error: error)

        XCTAssertEqual(failure.kind, .insufficientDiskSpace)
        XCTAssertEqual(failure.title, "Not enough disk space")
        XCTAssertTrue(failure.message.contains("Free up space"))
        XCTAssertFalse(failure.message.contains("/Users/"))
    }

    func testNetworkFailureSurvivesTheEngineLocalizedErrorWrapper() {
        // Both shipping engines currently wrap dependency errors as a localized string.
        let wrapped = TranscriptionError.modelUnavailable(
            "The Internet connection appears to be offline."
        )

        let failure = ModelDownloadFailure(model: model, error: wrapped)

        XCTAssertEqual(failure.kind, .network)
        XCTAssertEqual(failure.title, "Download interrupted")
        XCTAssertTrue(failure.message.contains("Check your connection"))
    }

    func testCorruptFailureExplainsThatRetryStartsFromCleanFiles() {
        let error = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileReadCorruptFileError,
            userInfo: [NSLocalizedDescriptionKey: "The downloaded model is corrupt."]
        )

        let failure = ModelDownloadFailure(model: model, purpose: .activate, error: error)

        XCTAssertEqual(failure.kind, .corruptFiles)
        XCTAssertEqual(failure.purpose, .activate)
        XCTAssertTrue(failure.message.contains("removed the incomplete files"))
    }

    func testStoreIntegrityMismatchIsPresentedAsCorruptDownload() {
        let error = ModelIntegrityError.sizeMismatch(
            path: "Encoder.mlmodelc/coremldata.bin",
            expected: 1024,
            actual: 12
        )

        let failure = ModelDownloadFailure(model: model, error: error)

        XCTAssertEqual(failure.kind, .corruptFiles)
        XCTAssertEqual(failure.title, "Model files are damaged")
    }

    func testOrdinaryLocalizedDescriptionIsKeptForUnknownFailure() {
        let error = NSError(
            domain: "ModelDownloadFailureTests",
            code: 7,
            userInfo: [NSLocalizedDescriptionKey: "The model service refused this request."]
        )

        let failure = ModelDownloadFailure(model: model, error: error)

        XCTAssertEqual(failure.kind, .other)
        XCTAssertTrue(failure.message.contains("The model service refused this request."))
    }

    func testUnsafeLocalizedDescriptionFallsBackWithoutCachePathOrURL() {
        let error = NSError(
            domain: "ModelDownloadFailureTests",
            code: 8,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Read failed at /Users/example/private-cache from https://example.invalid/model"
            ]
        )

        let failure = ModelDownloadFailure(model: model, error: error)

        XCTAssertEqual(failure.kind, .other)
        XCTAssertFalse(failure.message.contains("/Users/"))
        XCTAssertFalse(failure.message.contains("https://"))
        XCTAssertTrue(failure.message.contains("Try again"))
    }

    func testWrappedCancellationIsNotPresentedAsDownloadFailure() {
        let wrapped = TranscriptionError.modelUnavailable(
            "The operation couldn’t be completed. (Swift.CancellationError error 1.)"
        )

        XCTAssertTrue(ModelDownloadFailure.isCancellation(wrapped))
    }

    func testDownloadStateCarriesRetryPurposeAndProgress() {
        let downloading = ModelDownloadState.downloading(
            modelID: model.id,
            progress: 0.42,
            purpose: .activate
        )

        XCTAssertEqual(downloading.modelID, model.id)
        XCTAssertEqual(downloading.progress, 0.42)
        XCTAssertEqual(downloading.purpose, .activate)
        XCTAssertTrue(downloading.isInProgress)

        let failure = ModelDownloadFailure(
            model: model,
            purpose: .activate,
            error: NSError(domain: "tests", code: 1)
        )
        XCTAssertEqual(ModelDownloadState.failed(failure).failure(for: model.id), failure)
    }
}

// MARK: - Level buffer

/// The pill's meters read this on every display frame while dictating, so the arithmetic has
/// to be right and the writes must not allocate. The previous implementation appended to an
/// Array and called removeFirst on every sample — O(n), fifty times a second.
@MainActor
final class LevelBufferTests: XCTestCase {

    func testNewestSampleIsAtOffsetZero() {
        let buffer = LevelBuffer()
        buffer.append(0.1)
        buffer.append(0.9)
        XCTAssertEqual(buffer.sample(fromNewest: 0), 0.9, accuracy: 0.0001)
        XCTAssertEqual(buffer.sample(fromNewest: 1), 0.1, accuracy: 0.0001)
        XCTAssertEqual(buffer.latest, 0.9, accuracy: 0.0001)
    }

    func testReadingBeyondWhatWasWrittenIsSilent() {
        let buffer = LevelBuffer()
        buffer.append(0.5)
        XCTAssertEqual(buffer.sample(fromNewest: 5), 0)
        XCTAssertEqual(buffer.sample(fromNewest: -1), 0)
    }

    /// Ordering has to survive the write index wrapping, which is where a ring buffer breaks.
    func testOrderingSurvivesWrapAround() {
        let buffer = LevelBuffer()
        let total = LevelBuffer.capacity + 17
        for index in 0..<total {
            buffer.append(Float(index % 100) / 100)
        }
        XCTAssertEqual(buffer.count, LevelBuffer.capacity)
        for offset in 0..<LevelBuffer.capacity {
            let expected = Float((total - 1 - offset) % 100) / 100
            XCTAssertEqual(buffer.sample(fromNewest: offset), expected, accuracy: 0.0001,
                           "sample \(offset) back is wrong after wrapping")
        }
    }

    func testLevelsAreClamped() {
        let buffer = LevelBuffer()
        buffer.append(4.2)
        XCTAssertEqual(buffer.latest, 1)
        buffer.append(-3)
        XCTAssertEqual(buffer.latest, 0)
    }

    func testSignalDetection() {
        let buffer = LevelBuffer()
        XCTAssertFalse(buffer.hasSignal(), "an empty buffer must not claim signal")
        buffer.append(0.001)
        XCTAssertFalse(buffer.hasSignal())
        buffer.append(0.4)
        XCTAssertTrue(buffer.hasSignal())
    }

    func testResetClearsHistory() {
        let buffer = LevelBuffer()
        for _ in 0..<10 { buffer.append(0.7) }
        buffer.reset()
        XCTAssertEqual(buffer.count, 0)
        XCTAssertEqual(buffer.latest, 0)
        XCTAssertFalse(buffer.hasSignal())
    }
}

extension SettingsPersistenceTests {
    @MainActor
    func testCorruptSettingsAreBackedUpBeforeReplacement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("settings.json")
        let original = Data("{ damaged but recoverable".utf8)
        try original.write(to: url)
        let store = SettingsStore(fileURL: url)
        XCTAssertNotNil(store.loadWarning)
        store.data.assumedTypingWPM = 99
        try await store.flushPendingWrites()
        let backups = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.pathExtension == "backup" }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first)), original)
        XCTAssertEqual(try JSONDecoder().decode(SettingsData.self, from: Data(contentsOf: url)).assumedTypingWPM, 99)
    }

    @MainActor
    func testCorruptHistoryIsPreservedBeforeClear() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("history.json")
        let original = Data("[ broken history".utf8)
        try original.write(to: url)
        let store = HistoryStore(fileURL: url)
        XCTAssertNotNil(store.loadWarning)
        store.clear()
        try await store.flushPendingWrites()
        let backup = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first { $0.pathExtension == "backup" })
        XCTAssertEqual(try Data(contentsOf: backup), original)
        XCTAssertEqual(try JSONDecoder().decode([HistoryEntry].self, from: Data(contentsOf: url)).count, 0)
    }

    func testUnreadablePathBlocksWritesButMissingFileDoesNot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(ProtectedJSONLoad.read(SettingsData.self, from: root).blocked)
        let missing = ProtectedJSONLoad.read(SettingsData.self, from: root.appendingPathComponent("missing.json"))
        XCTAssertFalse(missing.blocked)
        XCTAssertNil(missing.warning)
    }
}
