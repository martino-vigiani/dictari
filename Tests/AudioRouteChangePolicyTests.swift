import XCTest

/// Pure decisions behind surviving AirPods / USB microphone route changes. The AVAudioEngine
/// side (notification delivery, the engine stopping itself) needs real hardware switching and
/// is not reproducible in the host-less harness.
final class AudioRouteChangePolicyTests: XCTestCase {

    // MARK: AudioRouteChangeAction

    func testRouteChangeWhileRecordingFinishesTheSession() {
        XCTAssertEqual(
            AudioRouteChangeAction.decide(isRecording: true, finishAlreadyRequested: false),
            .finishRecording
        )
    }

    func testBurstOfRouteChangesRequestsTheFinishOnlyOnce() {
        XCTAssertEqual(
            AudioRouteChangeAction.decide(isRecording: true, finishAlreadyRequested: true),
            .ignore
        )
    }

    func testRouteChangeWhileIdleRebuildsTheGraph() {
        XCTAssertEqual(
            AudioRouteChangeAction.decide(isRecording: false, finishAlreadyRequested: false),
            .rebuildIdleGraph
        )
        // A stale latch from a session that already ended must not suppress the rebuild.
        XCTAssertEqual(
            AudioRouteChangeAction.decide(isRecording: false, finishAlreadyRequested: true),
            .rebuildIdleGraph
        )
    }

    // MARK: TapFormatDecision

    func testMatchingFormatsTapWithTheOutputFormat() {
        XCTAssertEqual(
            TapFormatDecision.decide(hardwareSampleRate: 48_000, hardwareChannels: 1,
                                     outputSampleRate: 48_000, outputChannels: 1,
                                     alreadyRebuilt: false),
            .useOutputFormat
        )
    }

    func testNoDeviceIsAnErrorNotACrash() {
        for rebuilt in [false, true] {
            XCTAssertEqual(
                TapFormatDecision.decide(hardwareSampleRate: 0, hardwareChannels: 0,
                                         outputSampleRate: 48_000, outputChannels: 1,
                                         alreadyRebuilt: rebuilt),
                .noInputDevice
            )
            XCTAssertEqual(
                TapFormatDecision.decide(hardwareSampleRate: 24_000, hardwareChannels: 0,
                                         outputSampleRate: 24_000, outputChannels: 1,
                                         alreadyRebuilt: rebuilt),
                .noInputDevice
            )
        }
    }

    /// The exact shape of the crash: AirPods switch to 24 kHz while the prepared graph's
    /// output side still says 48 kHz.
    func testStaleOutputRateRebuildsBeforeTapping() {
        XCTAssertEqual(
            TapFormatDecision.decide(hardwareSampleRate: 24_000, hardwareChannels: 1,
                                     outputSampleRate: 48_000, outputChannels: 1,
                                     alreadyRebuilt: false),
            .rebuildGraph
        )
    }

    func testStillStaleAfterRebuildFallsBackToTheHardwareFormat() {
        XCTAssertEqual(
            TapFormatDecision.decide(hardwareSampleRate: 24_000, hardwareChannels: 1,
                                     outputSampleRate: 48_000, outputChannels: 1,
                                     alreadyRebuilt: true),
            .useHardwareFormat
        )
        XCTAssertEqual(
            TapFormatDecision.decide(hardwareSampleRate: 48_000, hardwareChannels: 2,
                                     outputSampleRate: 0, outputChannels: 0,
                                     alreadyRebuilt: true),
            .useHardwareFormat
        )
    }

    func testNoInputDeviceHasAUserFacingMessage() {
        let message = AudioCaptureError.noInputDevice.errorDescription ?? ""
        XCTAssertTrue(message.contains("microphone"), message)
    }
}
