import Foundation
import XCTest

final class EnergyVoiceActivityDetectorTests: XCTestCase {
    private let sampleRate = 16_000.0
    private let frameSamples = 160

    func testSpeechStartingInFirstFrameStillAutoStops() {
        var vad = makeVAD()
        for _ in 0..<10 {
            XCTAssertFalse(vad.consume(level: 0.8, sampleCount: frameSamples))
        }
        assertSilenceStops(&vad)
        XCTAssertFalse(vad.consume(level: 0.01, sampleCount: frameSamples), "auto-stop must latch once")
    }

    func testNormalStartupSpeechArmsAtEverySensitivity() {
        for sensitivity in 1...5 {
            var vad = makeVAD(sensitivity: sensitivity)
            for _ in 0..<3 {
                XCTAssertFalse(vad.consume(level: 0.10, sampleCount: frameSamples))
            }
            assertSilenceStops(&vad, message: "sensitivity \(sensitivity) did not arm 0.10 speech")
        }
    }

    func testImmediateNormalLevelSpeechIsNotMistakenForSilence() {
        var vad = makeVAD()
        let speech = [Float(0.10), 0.13, 0.15, 0.14]
        for index in 0..<30 {
            XCTAssertFalse(
                vad.consume(level: speech[index % speech.count], sampleCount: frameSamples),
                "normal speech was classified as a completed silence run"
            )
        }
        assertSilenceStops(&vad)
    }

    func testSpeechTailCannotRatchetdownIntoRoomNoise() {
        var vad = makeVAD()
        let roomNoise = [Float(0.11), 0.10, 0.09]
        for index in 0..<30 {
            XCTAssertFalse(vad.consume(level: roomNoise[index % roomNoise.count], sampleCount: frameSamples))
        }
        for _ in 0..<3 {
            XCTAssertFalse(vad.consume(level: 0.18, sampleCount: frameSamples))
        }
        XCTAssertFalse(vad.consume(level: 0.14, sampleCount: frameSamples))

        for index in 0..<9 {
            XCTAssertFalse(vad.consume(level: roomNoise[index % roomNoise.count], sampleCount: frameSamples))
        }
        XCTAssertTrue(vad.consume(level: roomNoise[0], sampleCount: frameSamples))
    }

    func testFanStartingAfterQuietPrerollBecomesSilenceAfterRealSpeech() {
        var vad = makeVAD()
        for _ in 0..<10 {
            XCTAssertFalse(vad.consume(level: 0.01, sampleCount: frameSamples))
        }
        for level in [Float(0.15), 0.18, 0.16] {
            XCTAssertFalse(vad.consume(level: level, sampleCount: frameSamples))
        }

        let fan = [Float(0.09), 0.10, 0.11]
        var stopped = false
        for index in 0..<60 where !stopped {
            stopped = vad.consume(level: fan[index % fan.count], sampleCount: frameSamples)
        }
        XCTAssertTrue(stopped, "a stationary fan kept a completed dictation alive")
    }

    func testStableNormalVoiceRemainsArmedUntilActualSilence() {
        var vad = makeVAD()
        for _ in 0..<30 {
            XCTAssertFalse(vad.consume(level: 0.10, sampleCount: frameSamples))
        }
        assertSilenceStops(&vad, message: "stationarity disarmed valid stable speech")
    }

    func testBriefPeakCannotTurnStableSpeechIntoSilence() {
        var vad = makeVAD()
        for _ in 0..<30 {
            XCTAssertFalse(vad.consume(level: 0.10, sampleCount: frameSamples))
        }
        XCTAssertFalse(vad.consume(level: 0.18, sampleCount: frameSamples))
        for _ in 0..<30 {
            XCTAssertFalse(
                vad.consume(level: 0.10, sampleCount: frameSamples),
                "a brief peak made continuing stable speech auto-stop"
            )
        }
    }

    func testFluctuatingLowBackgroundEventuallyCountsAsSilence() {
        var vad = makeVAD()
        armSpeech(&vad)

        let background = [Float(0.04), 0.05, 0.06, 0.05]
        var stopped = false
        for index in 0..<40 where !stopped {
            stopped = vad.consume(level: background[index % background.count], sampleCount: frameSamples)
        }
        XCTAssertTrue(stopped, "low fluctuating background kept a completed dictation alive")
    }

    func testRealtimeCapacityAutoStopsBeforeOverflowAndKeepsPriorAudio() {
        let state = RealtimeState(sampleCapacity: 4, frameLevelCapacity: 2)
        let captured: [Float] = [0.1, 0.2]
        captured.withUnsafeBufferPointer { state.append(samples: $0.baseAddress!, count: $0.count) }
        [Float](repeating: 0.3, count: 3).withUnsafeBufferPointer {
            state.append(samples: $0.baseAddress!, count: $0.count)
        }

        XCTAssertTrue(state.takeSnapshot().didAutoStop)
        XCTAssertEqual(state.drainSamples(), captured)
    }

    func testOneTransientDoesNotArmAutoStop() {
        var vad = makeVAD()
        for _ in 0..<10 {
            XCTAssertFalse(vad.consume(level: 0.03, sampleCount: frameSamples))
        }
        XCTAssertFalse(vad.consume(level: 0.8, sampleCount: frameSamples))
        for _ in 0..<20 {
            XCTAssertFalse(vad.consume(level: 0.03, sampleCount: frameSamples))
        }
    }

    func testOneTransientAboveAStationaryFanCannotBorrowNoiseFrames() {
        var vad = makeVAD()
        for _ in 0..<30 {
            XCTAssertFalse(vad.consume(level: 0.10, sampleCount: frameSamples))
        }
        XCTAssertFalse(vad.consume(level: 0.18, sampleCount: frameSamples))
        for _ in 0..<30 {
            XCTAssertFalse(vad.consume(level: 0.10, sampleCount: frameSamples))
        }

        for level in [Float(0.18), 0.15, 0.16] {
            XCTAssertFalse(vad.consume(level: level, sampleCount: frameSamples))
        }
        var stopped = false
        for _ in 0..<40 where !stopped {
            stopped = vad.consume(level: 0.10, sampleCount: frameSamples)
        }
        XCTAssertTrue(stopped, "a real multi-frame onset did not arm above the fan")
    }

    /// Regression: every continuation-level frame used to zero `silentSampleRun`. A one- or
    /// two-frame weak transient could therefore restart the entire two-second silence window.
    /// The transient is deliberately just above each sensitivity's continuation floor, but below
    /// the validated 0.10 speech reference, so it exercises the debounce rather than the strong
    /// onset path covered by `testShortPauseIsCancelledByMoreSpeech`.
    func testWeakTenMillisecondTransientsDoNotRestartPendingSilenceAtAnySensitivity() {
        let weakLevels: [(sensitivity: Int, level: Float)] = [
            (1, 0.05),
            (2, 0.06),
            (3, 0.08),
            (4, 0.09),
            (5, 0.095)
        ]
        let silenceWindowSamples = 2 * Int(sampleRate)

        for (sensitivity, level) in weakLevels {
            for transientLevels in [[level], [level, min(0.099, level + 0.01)]] {
                var vad = makeVAD(silenceSeconds: 2, sensitivity: sensitivity)
                armSpeech(&vad)

                let silenceBeforeTransients = silenceWindowSamples
                    - (transientLevels.count + 1) * frameSamples
                XCTAssertFalse(vad.consume(
                    level: 0.01,
                    sampleCount: silenceBeforeTransients
                ))
                for transientLevel in transientLevels {
                    XCTAssertFalse(vad.consume(
                        level: transientLevel,
                        sampleCount: frameSamples
                    ), "sensitivity \(sensitivity) treated a weak transient as a new utterance")
                }

                XCTAssertTrue(vad.consume(
                    level: 0.01,
                    sampleCount: frameSamples
                ), "sensitivity \(sensitivity) restarted the full silence window")
            }
        }
    }

    /// Regression: the low alternating background observed in practice contains isolated frames
    /// that clear sensitivity 2's continuation floor. They must not keep a completed dictation
    /// alive; only three consecutive resumed speech frames may cancel the pending stop.
    func testAlternatingLowBackgroundWithTwoWeakTransientsStillReachesOriginalDeadline() {
        var vad = makeVAD(silenceSeconds: 2, sensitivity: 2)
        armSpeech(&vad)

        let background = [Float(0.01), 0.06, 0.02, 0.07]
        let silenceWindowSamples = 2 * Int(sampleRate)
        let silenceBeforeBackground = silenceWindowSamples
            - (background.count + 1) * frameSamples
        XCTAssertFalse(vad.consume(level: 0.01, sampleCount: silenceBeforeBackground))

        for level in background {
            XCTAssertFalse(vad.consume(level: level, sampleCount: frameSamples))
        }
        XCTAssertTrue(vad.consume(level: 0.01, sampleCount: frameSamples))
    }

    /// Regression: a quiet three-frame onset used to become the permanent speech reference.
    /// After a real voiced segment, the variable low background from a silent replay must still
    /// reach the two-second stop deadline, including isolated higher noise frames.
    func testWeakOnsetFollowedByVoicedSpeechDoesNotKeepVariableBackgroundAlive() {
        var vad = makeVAD(silenceSeconds: 2, sensitivity: 2)

        for level in [Float(0.04), 0.05, 0.06] {
            XCTAssertFalse(vad.consume(level: level, sampleCount: frameSamples))
        }
        let voicedSegment = [Float(0.5), 0.8, 1.0, 0.7]
        for index in 0..<100 {
            XCTAssertFalse(vad.consume(
                level: voicedSegment[index % voicedSegment.count],
                sampleCount: frameSamples
            ))
        }

        let variableBackground = [Float(0.055), 0.09, 0.10, 0.17, 0.07, 0.13]
        let maximumBackgroundFrames = Int((2.3 * sampleRate) / Double(frameSamples))
        var stopped = false
        for index in 0..<maximumBackgroundFrames where !stopped {
            stopped = vad.consume(
                level: variableBackground[index % variableBackground.count],
                sampleCount: frameSamples
            )
        }

        XCTAssertTrue(stopped, "variable room noise kept the completed dictation alive")
    }

    /// Regression: a loud segment must raise the sustained-speech reference without making a
    /// genuinely quieter continuation look like silence. The continuation lasts three seconds;
    /// only after it ends may the variable background start the two-second stop window.
    func testQuieterSustainedSpeechAfterLoudSpeechRemainsArmedBeforeBackgroundStops() {
        var vad = makeVAD(silenceSeconds: 2, sensitivity: 2)

        for level in [Float(0.04), 0.05, 0.06] {
            XCTAssertFalse(vad.consume(level: level, sampleCount: frameSamples))
        }
        let loudSpeech = [Float(0.5), 0.8, 1.0, 0.7]
        for index in 0..<100 {
            XCTAssertFalse(vad.consume(
                level: loudSpeech[index % loudSpeech.count],
                sampleCount: frameSamples
            ))
        }

        let quieterSpeech = [Float(0.25), 0.35, 0.30, 0.40]
        for index in 0..<300 {
            XCTAssertFalse(vad.consume(
                level: quieterSpeech[index % quieterSpeech.count],
                sampleCount: frameSamples
            ), "quieter sustained speech was mistaken for silence at frame \(index)")
        }

        let variableBackground = [Float(0.055), 0.09, 0.10, 0.17, 0.07, 0.13]
        let maximumBackgroundFrames = Int((2.3 * sampleRate) / Double(frameSamples))
        var stopped = false
        for index in 0..<maximumBackgroundFrames where !stopped {
            stopped = vad.consume(
                level: variableBackground[index % variableBackground.count],
                sampleCount: frameSamples
            )
        }

        XCTAssertTrue(stopped, "variable room noise kept the completed dictation alive")
    }

    /// The realtime pipeline must preserve the same VAD contract when converted callbacks split
    /// frames at arbitrary offsets. A calibrated 800 Hz wave has an integer number of cycles in
    /// each 160-sample frame, so its RMS is exactly `level * referenceRMS`.
    func testPipelineKeepsQuietSpeechAndStopsVariableBackgroundAcrossIrregularCallbacks() {
        var pipeline = EnergyVoiceActivityPipeline(
            silenceSeconds: 2,
            sensitivity: 2,
            sampleRate: sampleRate
        )
        var samples: [Float] = []
        let loudSpeech = [Float(0.5), 0.8, 1.0, 0.7]
        let quieterSpeech = [Float(0.25), 0.35, 0.30, 0.40]
        let variableBackground = [Float(0.055), 0.09, 0.10, 0.17, 0.07, 0.13]

        appendSineFrames([Float(0.04), 0.05, 0.06], to: &samples)
        appendSineFrames(loudSpeech, frameCount: 100, to: &samples)
        appendSineFrames(quieterSpeech, frameCount: 300, to: &samples)
        let preBackgroundSampleCount = samples.count
        let maximumBackgroundFrames = Int((2.3 * sampleRate) / Double(frameSamples))
        appendSineFrames(
            variableBackground,
            frameCount: maximumBackgroundFrames,
            to: &samples
        )

        let callbackSizes = [137, 313, 29, 401, 97, 1, 271, 257, 160, 512, 640, 222]
        var callbackIndex = 0
        var offset = 0
        while offset < preBackgroundSampleCount {
            let requestedCount = callbackSizes[callbackIndex % callbackSizes.count]
            let count = min(requestedCount, preBackgroundSampleCount - offset)
            let stopped = samples.withUnsafeBufferPointer { buffer in
                pipeline.consume(samples: buffer.baseAddress! + offset, count: count)
            }
            XCTAssertFalse(stopped, "pipeline stopped before the variable background began")
            offset += count
            callbackIndex += 1
        }

        var stopped = false
        var backgroundOffset = 0
        while backgroundOffset < maximumBackgroundFrames * frameSamples, !stopped {
            let requestedCount = callbackSizes[callbackIndex % callbackSizes.count]
            let count = min(
                requestedCount,
                maximumBackgroundFrames * frameSamples - backgroundOffset
            )
            stopped = samples.withUnsafeBufferPointer { buffer in
                pipeline.consume(
                    samples: buffer.baseAddress! + preBackgroundSampleCount + backgroundOffset,
                    count: count
                )
            }
            backgroundOffset += count
            callbackIndex += 1
        }

        XCTAssertTrue(stopped, "irregular callback boundaries kept variable room noise alive")
    }

    /// A pause that is shorter than the configured two-second window must remain recoverable.
    /// Three consecutive weak continuation frames are the minimum resumed-speech proof and reset
    /// the counter; the already-covered strong one-frame onset remains intentionally immediate.
    func testThreeConsecutiveWeakSpeechFramesCancelAPendingShortPause() {
        var vad = makeVAD(silenceSeconds: 2, sensitivity: 2)
        armSpeech(&vad)

        let silenceWindowSamples = 2 * Int(sampleRate)
        XCTAssertFalse(vad.consume(
            level: 0.01,
            sampleCount: silenceWindowSamples - 4 * frameSamples
        ))
        for level in [Float(0.06), 0.07, 0.06] {
            XCTAssertFalse(vad.consume(level: level, sampleCount: frameSamples))
        }

        XCTAssertFalse(vad.consume(
            level: 0.01,
            sampleCount: silenceWindowSamples - frameSamples
        ))
        XCTAssertTrue(vad.consume(level: 0.01, sampleCount: frameSamples))
    }

    func testFailedRebaseRestoresPreviouslyValidatedStableSpeech() {
        var vad = makeVAD()
        for _ in 0..<30 {
            XCTAssertFalse(vad.consume(level: 0.10, sampleCount: frameSamples))
        }
        XCTAssertFalse(vad.consume(level: 0.18, sampleCount: frameSamples))
        XCTAssertFalse(vad.consume(level: 0.10, sampleCount: frameSamples))
        assertSilenceStops(&vad, message: "a failed rebase destroyed valid speech state")
    }

    func testTwoSpeechFramesDoNotArmButThreeDo() {
        var twoFrames = makeVAD()
        for _ in 0..<2 {
            XCTAssertFalse(twoFrames.consume(level: 0.10, sampleCount: frameSamples))
        }
        for _ in 0..<10 {
            XCTAssertFalse(twoFrames.consume(level: 0.01, sampleCount: frameSamples))
        }

        var threeFrames = makeVAD()
        for _ in 0..<3 {
            XCTAssertFalse(threeFrames.consume(level: 0.10, sampleCount: frameSamples))
        }
        assertSilenceStops(&threeFrames)
    }

    func testAutoStopUsesExactSampleDuration() {
        var vad = makeVAD()
        armSpeech(&vad)
        XCTAssertFalse(vad.consume(level: 0.01, sampleCount: 1_599))
        XCTAssertTrue(vad.consume(level: 0.01, sampleCount: 1))
    }

    func testShortPauseIsCancelledByMoreSpeech() {
        var vad = makeVAD()
        armSpeech(&vad)
        XCTAssertFalse(vad.consume(level: 0.01, sampleCount: 1_200))
        XCTAssertFalse(vad.consume(level: 0.14, sampleCount: frameSamples))
        XCTAssertFalse(vad.consume(level: 0.01, sampleCount: 1_599))
        XCTAssertTrue(vad.consume(level: 0.01, sampleCount: 1))
    }

    func testIrregularCallbacksPreserveExactTenMillisecondFrames() {
        var pipeline = EnergyVoiceActivityPipeline(
            silenceSeconds: 0.1,
            sensitivity: 3,
            sampleRate: sampleRate
        )
        let speech = [Float](repeating: 0.10 * EnergyVoiceActivityPipeline.referenceRMS, count: 480)
        let silence = [Float](repeating: 0.01 * EnergyVoiceActivityPipeline.referenceRMS, count: 1_600)
        let samples = speech + silence
        let callbackSizes = [341, 342, 341, 342, 341, 342, 31]

        var offset = 0
        for (index, requestedCount) in callbackSizes.enumerated() {
            let count = min(requestedCount, samples.count - offset)
            let stopped = samples.withUnsafeBufferPointer { buffer in
                pipeline.consume(samples: buffer.baseAddress! + offset, count: count)
            }
            offset += count
            if index == callbackSizes.count - 1 {
                XCTAssertTrue(stopped, "the final 160-sample silence frame did not stop")
            } else {
                XCTAssertFalse(stopped, "callback boundaries rounded the silence duration")
            }
        }
        XCTAssertEqual(offset, samples.count)
    }

    private func makeVAD(
        silenceSeconds: Double = 0.1,
        sensitivity: Int = 3
    ) -> EnergyVoiceActivityDetector {
        EnergyVoiceActivityDetector(
            silenceSeconds: silenceSeconds,
            sensitivity: sensitivity,
            sampleRate: sampleRate
        )
    }

    private func armSpeech(_ vad: inout EnergyVoiceActivityDetector) {
        for level in [Float(0.10), 0.13, 0.12] {
            XCTAssertFalse(vad.consume(level: level, sampleCount: frameSamples))
        }
    }

    private func appendSineFrames(
        _ levels: [Float],
        frameCount: Int? = nil,
        to samples: inout [Float]
    ) {
        let count = frameCount ?? levels.count
        let frameWaveforms = levels.map(sineFrame(for:))
        samples.reserveCapacity(samples.count + count * frameSamples)
        for index in 0..<count {
            samples.append(contentsOf: frameWaveforms[index % frameWaveforms.count])
        }
    }

    private func sineFrame(for level: Float) -> [Float] {
        let amplitude = Double(level)
            * Double(EnergyVoiceActivityPipeline.referenceRMS)
            * sqrt(2)
        let angularStep = 2 * Double.pi * 800 / sampleRate
        return (0..<frameSamples).map { index in
            Float(amplitude * sin(Double(index) * angularStep))
        }
    }

    private func assertSilenceStops(
        _ vad: inout EnergyVoiceActivityDetector,
        message: String = "silence did not auto-stop"
    ) {
        for _ in 0..<9 {
            XCTAssertFalse(vad.consume(level: 0.01, sampleCount: frameSamples), message)
        }
        XCTAssertTrue(vad.consume(level: 0.01, sampleCount: frameSamples), message)
    }
}
