// ConversationAudioSegmentTests.swift
// Conversation mode cuts segments off a capture that keeps running. The cut must hand over
// exactly what was captured since the previous one, start the next segment empty, and re-arm
// VAD (the pump disarms it after delivering an auto-stop) — otherwise the second pause of a
// conversation would never be noticed.

import XCTest

final class ConversationAudioSegmentTests: XCTestCase {

    private func append(_ state: RealtimeState, value: Float, count: Int) {
        let samples = [Float](repeating: value, count: count)
        samples.withUnsafeBufferPointer { state.append(samples: $0.baseAddress!, count: count) }
    }

    func testCutHandsOverTheSegmentAndStartsTheNextOneEmpty() {
        let state = RealtimeState(sampleCapacity: 16_000, frameLevelCapacity: 100)
        append(state, value: 0.1, count: 160)
        append(state, value: 0.1, count: 160)

        let first = state.cutSegment(vadEnabled: true)
        XCTAssertEqual(first.samples.count, 320)
        XCTAssertGreaterThan(first.speechLevel, 0)

        append(state, value: 0.2, count: 160)
        let second = state.cutSegment(vadEnabled: true)
        XCTAssertEqual(second.samples.count, 160)
        XCTAssertEqual(second.samples.first, 0.2)

        let third = state.cutSegment(vadEnabled: true)
        XCTAssertTrue(third.samples.isEmpty)
        XCTAssertEqual(third.speechLevel, 0)
    }

    /// Capacity freed by a cut is reusable: a long conversation is not capped at five minutes
    /// in total, only per turn.
    func testCapacityIsPerSegment() {
        let state = RealtimeState(sampleCapacity: 320, frameLevelCapacity: 100)
        append(state, value: 0.1, count: 320)
        XCTAssertEqual(state.cutSegment(vadEnabled: false).samples.count, 320)
        append(state, value: 0.1, count: 320)
        XCTAssertFalse(state.takeSnapshot().didAutoStop, "a full segment after a cut is not over capacity")
        XCTAssertEqual(state.cutSegment(vadEnabled: false).samples.count, 320)
    }

    /// Speech then a pause stops; after the cut, the next turn's pause stops again.
    func testEveryPauseOfAConversationIsNoticed() {
        let state = RealtimeState(sampleCapacity: 16_000 * 10, frameLevelCapacity: 1_000)
        state.configureVAD(enabled: true, silenceSeconds: 0.1, sensitivity: 3, outputSampleRate: 16_000)
        let speech = 0.10 * EnergyVoiceActivityPipeline.referenceRMS
        let silence = 0.01 * EnergyVoiceActivityPipeline.referenceRMS

        for turn in 0..<3 {
            append(state, value: speech, count: 480)
            append(state, value: silence, count: 1_600)
            XCTAssertTrue(state.takeSnapshot().didAutoStop, "pause \(turn) was not noticed")
            XCTAssertEqual(state.cutSegment(vadEnabled: true).samples.count, 2_080)
        }

        // Without re-arming (what `stop()`'s path would leave behind) the next pause is missed.
        append(state, value: speech, count: 480)
        append(state, value: silence, count: 1_600)
        XCTAssertTrue(state.takeSnapshot().didAutoStop)
        _ = state.cutSegment(vadEnabled: false)
        append(state, value: speech, count: 480)
        append(state, value: silence, count: 1_600)
        XCTAssertFalse(state.takeSnapshot().didAutoStop)
    }

    func testCutClearsAPendingAutoStopAndReArmsVAD() {
        let state = RealtimeState(sampleCapacity: 320, frameLevelCapacity: 100)
        append(state, value: 0.1, count: 320)
        append(state, value: 0.1, count: 16)            // over capacity: auto-stop latched
        XCTAssertTrue(state.takeSnapshot().didAutoStop)  // the pump delivers it and disarms VAD
        _ = state.cutSegment(vadEnabled: true)
        XCTAssertFalse(state.takeSnapshot().didAutoStop, "a cut must not replay the stop it answered")
        // Over capacity again → a new stop is latched, proving the latch was cleared.
        append(state, value: 0.1, count: 320)
        append(state, value: 0.1, count: 16)
        XCTAssertTrue(state.takeSnapshot().didAutoStop)
    }
}
