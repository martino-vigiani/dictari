// StreamingTranscriptionTests.swift
// Does text actually appear before the user stops talking?
//
// The claim this file exists to check is a product claim, not an API claim: feeding real
// synthesized speech in at roughly the rate a person speaks must produce at least one
// hypothesis *before* the final transcript, and the final transcript must still be right.
// Anything less and the streaming path is a demo trick that regressed the app.

import XCTest

final class StreamingTranscriptionTests: XCTestCase {

    private func loadedEngine() async throws -> ParakeetEngine {
        try await SharedParakeet.shared.engine()
    }

    // MARK: - The claim

    /// Feed a sentence in 200 ms slices, paced in real time, and assert that words arrive
    /// while audio is still being appended.
    func testPartialsArriveBeforeTheFinalTranscript() async throws {
        let spoken = "The quick brown fox jumps over the lazy dog near the river bank."
        let engine = try await loadedEngine()
        let samples = try AudioFixture.samples(text: spoken, voice: "Samantha")
        XCTAssertGreaterThan(samples.count, 16_000 * 2, "fixture audio is suspiciously short")

        let stream = try engine.startStream(language: "en")

        // Collect updates concurrently with the feed, exactly as the coordinator will.
        let collector = Task { () -> [TranscriptionUpdate] in
            var received: [TranscriptionUpdate] = []
            for await update in stream.updates { received.append(update) }
            return received
        }

        try await feed(samples, into: stream, sliceSeconds: 0.2)

        let final = try await stream.finish()
        let received = await collector.value

        XCTAssertFalse(final.isEmpty, "streaming session produced no final transcript")

        let partials = received.filter { !$0.isFinal }
        XCTAssertFalse(
            partials.isEmpty,
            """
            no hypothesis arrived before the final transcript — the streaming path is not \
            streaming. Final was: "\(final)"
            """
        )

        // The last update must be the final one, and it must be the text `finish()` returned:
        // whatever the pill last showed, the string that gets inserted is this one.
        XCTAssertEqual(received.last?.isFinal, true, "the final update was not emitted last")
        XCTAssertEqual(received.last?.text, final)
        XCTAssertEqual(received.filter(\.isFinal).count, 1, "more than one final update")

        // Partials are hypotheses, but they are not allowed to be junk: the first one should
        // already contain words from the beginning of the sentence.
        let firstPartial = partials[0].text
        XCTAssertGreaterThan(
            TranscriptMatch.wordRecall(expected: "the quick brown fox", actual: firstPartial),
            0.4,
            "first hypothesis did not resemble the opening of the sentence: \"\(firstPartial)\""
        )
    }

    /// The whole point of keeping the final decode on the existing code path: streaming must
    /// not cost accuracy. The transcript from a streamed session has to match what the same
    /// audio produces through the plain, non-streaming call.
    func testFinalTranscriptMatchesTheNonStreamingPath() async throws {
        let spoken = "Domani mattina devo passare in ufficio per ritirare i documenti."
        let engine = try await loadedEngine()
        let samples = try AudioFixture.samples(text: spoken, voice: "Alice")

        let batch = try await engine.transcribe(samples: samples, language: "it")

        let stream = try engine.startStream(language: "it")
        let drain = Task { for await _ in stream.updates {} }
        try await feed(samples, into: stream, sliceSeconds: 0.2)
        let streamed = try await stream.finish()
        await drain.value

        XCTAssertEqual(
            TranscriptMatch.normalize(streamed),
            TranscriptMatch.normalize(batch),
            "streaming changed the final transcript"
        )
        XCTAssertGreaterThanOrEqual(
            TranscriptMatch.wordRecall(expected: spoken, actual: streamed), 0.6,
            "streamed transcript too far from the spoken text: \"\(streamed)\""
        )
    }

    // MARK: - Behaviour the coordinator depends on

    func testEngineWithoutStreamingRefusesToStart() throws {
        // WhisperKitEngine takes the protocol default: it must say no rather than pretend.
        let whisper = WhisperKitEngine(modelName: "openai_whisper-base")
        XCTAssertFalse(whisper.supportsStreaming)
        XCTAssertThrowsError(try whisper.startStream(language: "en")) { error in
            guard case TranscriptionError.streamingUnavailable = error else {
                return XCTFail("expected streamingUnavailable, got \(error)")
            }
        }
    }

    func testStreamingBeforeWarmUpThrowsNotReady() throws {
        let cold = ParakeetEngine(displayName: "cold")
        XCTAssertTrue(cold.supportsStreaming)
        XCTAssertThrowsError(try cold.startStream(language: "en")) { error in
            guard case TranscriptionError.notReady = error else {
                return XCTFail("expected notReady, got \(error)")
            }
        }
    }

    /// A cancelled dictation must end the update stream and never emit a final transcript —
    /// the coordinator throws the audio away, and nothing may be inserted afterwards.
    func testCancelEndsTheStreamWithoutAFinalUpdate() async throws {
        let engine = try await loadedEngine()
        let samples = try AudioFixture.samples(
            text: "The parliament approved the budget yesterday.", voice: "Samantha")

        let stream = try engine.startStream(language: "en")
        let collector = Task { () -> [TranscriptionUpdate] in
            var received: [TranscriptionUpdate] = []
            for await update in stream.updates { received.append(update) }
            return received
        }

        stream.append(Array(samples.prefix(16_000)))
        stream.cancel()

        let received = await collector.value
        XCTAssertTrue(received.allSatisfy { !$0.isFinal }, "a cancelled session emitted a final")
    }

    // MARK: - Helper

    /// Push `samples` in at wall-clock speed, so the test exercises the same race the app
    /// does: audio arriving while a decode of the previous slice is still running.
    private func feed(
        _ samples: [Float],
        into stream: any TranscriptionStream,
        sliceSeconds: Double
    ) async throws {
        let slice = Int(sliceSeconds * 16_000)
        var offset = 0
        while offset < samples.count {
            let end = min(offset + slice, samples.count)
            stream.append(Array(samples[offset..<end]))
            offset = end
            try await Task.sleep(nanoseconds: UInt64(sliceSeconds * 1_000_000_000))
        }
    }
}
