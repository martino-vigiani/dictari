import Foundation
import XCTest

final class DictationRecoveryRetentionPolicyTests: XCTestCase {

    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000_000)
    private let day: TimeInterval = 24 * 60 * 60

    // MARK: - Pure policy

    func testNeverPrunesRecordingsWithoutATranscript() {
        // Thirty old failed transcriptions: every one is the only copy of that speech.
        let failed = (0..<30).map { make(.transcriptionFailed, ageDays: 30 + Double($0), transcript: nil) }
        let damaged = make(.metadataDamaged, ageDays: 400, transcript: nil)

        let prune = DictationRecoveryRetentionPolicy.idsToPrune(failed + [damaged], now: now)

        XCTAssertTrue(prune.isEmpty)
    }

    func testFailedTranscriptionThatKeptAnEarlierTranscriptIsStillKept() {
        // A retry that found "no speech" keeps the prior transcript but stays unresolved.
        let retried = make(.transcriptionFailed, ageDays: 30, transcript: "earlier text")

        XCTAssertTrue(DictationRecoveryRetentionPolicy.idsToPrune([retried], now: now).isEmpty)
    }

    func testEmptyOrWhitespaceTranscriptIsNotDisposable() {
        let blank = make(.injectionFailed, ageDays: 30, transcript: "  \n")
        let missing = make(.transcribed, ageDays: 30, transcript: nil)

        XCTAssertTrue(DictationRecoveryRetentionPolicy.idsToPrune([blank, missing], now: now).isEmpty)
    }

    func testKeepsOnlyTheNewestTwentyTranscribedRecordings() {
        // 25 unverified deliveries in the last day, newest first by index.
        let delivered = (0..<25).map { make(.injectionFailed, ageSeconds: Double($0) * 60, transcript: "t\($0)") }

        let prune = DictationRecoveryRetentionPolicy.idsToPrune(delivered.shuffled(), now: now)

        XCTAssertEqual(Set(prune), Set(delivered[20...].map(\.id)))
    }

    func testPrunesTranscribedRecordingsOlderThanSevenDaysEvenUnderTheCount() {
        let fresh = make(.injectionFailed, ageDays: 6.9, transcript: "fresh")
        let stale = make(.injectionFailed, ageDays: 7.1, transcript: "stale")
        let staleRecovered = make(.transcribed, ageDays: 10, transcript: "recovered")

        let prune = DictationRecoveryRetentionPolicy.idsToPrune([fresh, stale, staleRecovered], now: now)

        XCTAssertEqual(Set(prune), [stale.id, staleRecovered.id])
    }

    func testFailedTranscriptionsDoNotConsumeTranscribedSlots() {
        let failed = (0..<50).map { make(.transcriptionFailed, ageSeconds: Double($0), transcript: nil) }
        let delivered = (0..<20).map { make(.injectionFailed, ageSeconds: 100 + Double($0), transcript: "t") }

        XCTAssertTrue(DictationRecoveryRetentionPolicy.idsToPrune(failed + delivered, now: now).isEmpty)
    }

    func testProtectedRecordIsKeptEvenWhenStaleAndOccupiesASlot() {
        // A retry of a two-week-old recording must not delete it underneath the user.
        let retried = make(.injectionFailed, ageDays: 14, transcript: "retried")
        let recent = (0..<20).map { make(.injectionFailed, ageSeconds: Double($0), transcript: "t\($0)") }

        let prune = DictationRecoveryRetentionPolicy.idsToPrune(
            recent + [retried], now: now, protecting: [retried.id]
        )

        XCTAssertFalse(prune.contains(retried.id))
        // The protected record holds a slot, so the oldest recent one is the overflow.
        XCTAssertEqual(prune, [recent[19].id])
    }

    func testFutureTimestampCountsAsFresh() {
        let skewed = make(.injectionFailed, ageDays: -3, transcript: "clock moved back")

        XCTAssertTrue(DictationRecoveryRetentionPolicy.idsToPrune([skewed], now: now).isEmpty)
    }

    // MARK: - Store integration (temporary directory only)

    func testApplyRetentionDeletesOnlyDisposableRecordingsFromDisk() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dictari-retention-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DictationRecoveryStore(rootURL: root)

        let oldFailed = try store.save(
            samples: [0.1], durationSeconds: 1, language: "en", modelID: "m",
            state: .transcriptionFailed, failureDescription: "Model failed",
            createdAt: now.addingTimeInterval(-30 * day)
        )
        let oldDelivered = try store.save(
            samples: [0.2], durationSeconds: 1, language: "en", modelID: "m",
            state: .injectionFailed, failureDescription: "Paste could not be verified",
            transcript: "old text", createdAt: now.addingTimeInterval(-8 * day)
        )
        let recentDelivered = try store.save(
            samples: [0.3], durationSeconds: 1, language: "en", modelID: "m",
            state: .injectionFailed, failureDescription: "Paste could not be verified",
            transcript: "recent text", createdAt: now.addingTimeInterval(-1 * day)
        )

        let result = try store.applyRetention(now: now)

        XCTAssertEqual(result.deleted, [oldDelivered.id])
        XCTAssertEqual(result.remaining.map(\.id), [recentDelivered.id, oldFailed.id])
        let reloaded = try DictationRecoveryStore(rootURL: root)
        XCTAssertEqual(try reloaded.recoveries().map(\.id), [recentDelivered.id, oldFailed.id])
        XCTAssertEqual(try reloaded.load(oldFailed.id).samples, [0.1])
        XCTAssertThrowsError(try reloaded.load(oldDelivered.id))
    }

    func testBatchDeleteReportsRemovedAndAlreadyAbsentIDs() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dictari-retention-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DictationRecoveryStore(rootURL: root)
        let saved = try store.save(
            samples: [0.1], durationSeconds: 1, language: "en", modelID: "m",
            state: .injectionFailed, failureDescription: "x", transcript: "t"
        )
        let absent = UUID()

        let removed = store.delete([saved.id, absent])

        XCTAssertEqual(Set(removed), [saved.id, absent])
        XCTAssertTrue(try store.recoveries().isEmpty)
    }

    // MARK: - Helpers

    private func make(
        _ state: DictationRecoveryState,
        ageDays: Double,
        transcript: String?
    ) -> DictationRecovery {
        make(state, ageSeconds: ageDays * day, transcript: transcript)
    }

    private func make(
        _ state: DictationRecoveryState,
        ageSeconds: Double,
        transcript: String?
    ) -> DictationRecovery {
        DictationRecovery(
            id: UUID(),
            createdAt: now.addingTimeInterval(-ageSeconds),
            durationSeconds: 1,
            language: "en",
            modelID: "test",
            appName: nil,
            appBundleID: nil,
            state: state,
            failureDescription: "",
            transcript: transcript
        )
    }
}
