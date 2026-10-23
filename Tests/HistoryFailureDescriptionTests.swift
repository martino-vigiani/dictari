import XCTest

final class HistoryFailureDescriptionTests: XCTestCase {
    // Regression: transcription succeeded; only correction failed, so the original remains recoverable.
    func testRevisionFailureExplainsThatTheOriginalWasSaved() {
        XCTAssertEqual(HistoryFailureDescription.text(for: "revision failed"),
                       "Correction failed — original saved")
    }

    func testRecoveryCommitFailureExplainsThatTheRecordingCouldNotBeSaved() {
        XCTAssertEqual(
            HistoryFailureDescription.text(for: "recovery failed"),
            "Recording couldn't be saved — check free disk space"
        )
    }

    func testSubmitReplayFailureNeverClaimsThatAnUnverifiedPasteWasInserted() {
        let label = DictationState.SuccessKind.submitFailed.statusLabel

        XCTAssertEqual(label, "Paste unverified — check, then press Return")
        XCTAssertFalse(label.localizedCaseInsensitiveContains("inserted"))
    }
}
