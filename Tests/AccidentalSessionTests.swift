import XCTest

final class AccidentalSessionTests: XCTestCase {
    private let normal = ProximityFilter.normal.minimumSpeechLevel

    // Regression: a quick open-and-close flashed "Too far from the mic".
    func testQuickOpenAndCloseWithoutVoiceIsAccidental() {
        XCTAssertTrue(AccidentalSession.isAccidental(
            duration: 0.8, peak: 0.02, speechLevel: 0.01, minimumSpeechLevel: normal))
    }

    func testQuickOpenAndCloseInSilenceIsAccidentalEvenWithTheFilterOff() {
        XCTAssertTrue(AccidentalSession.isAccidental(
            duration: 0.8, peak: 0.001, speechLevel: 0, minimumSpeechLevel: 0))
    }

    func testMisTapIsAccidentalWhateverItCaptured() {
        XCTAssertTrue(AccidentalSession.isAccidental(
            duration: 0.2, peak: 0.5, speechLevel: 0.4, minimumSpeechLevel: normal))
    }

    func testShortButLoudOneWordDictationIsKept() {
        XCTAssertFalse(AccidentalSession.isAccidental(
            duration: 0.8, peak: 0.4, speechLevel: 0.2, minimumSpeechLevel: normal))
    }

    func testLongerQuietSessionStillReportsItsRejection() {
        XCTAssertFalse(AccidentalSession.isAccidental(
            duration: 3, peak: 0.02, speechLevel: 0.01, minimumSpeechLevel: normal))
    }

    func testEmptyTranscriptIsAccidentalOnlyWhenShort() {
        XCTAssertTrue(AccidentalSession.isAccidental(duration: 1.0, transcriptIsEmpty: true))
        XCTAssertFalse(AccidentalSession.isAccidental(duration: 4.0, transcriptIsEmpty: true))
        XCTAssertFalse(AccidentalSession.isAccidental(duration: 1.0, transcriptIsEmpty: false))
    }
}
