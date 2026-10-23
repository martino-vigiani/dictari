import XCTest
import os

final class BackgroundTranscriptionTests: XCTestCase {
    private let speech = [Float](repeating: 0.03, count: 16_000 * 3)
    private let pause = [Float](repeating: 0, count: 7_200)

    func testCompletedPhraseIsReusedAndUnpumpedLastSyllableIsDecoded() async throws {
        let engine = RecordingBackgroundEngine()
        let phrase = speech + pause
        let tail = [Float](repeating: 0.12, count: BackgroundTranscriptionSession.minimumDecodeSamples)
        let session = BackgroundTranscriptionSession(engine: engine, language: "it")
        session.append(phrase, at: 0)
        try await engine.waitForCalls(1)
        // This tail was captured but never reached an incremental callback.
        let text = try await session.finish(samples: phrase + tail)
        XCTAssertEqual(text, "phrase1 phrase2")
        XCTAssertTrue(engine.calls.map(\.samples) == [phrase, tail], "decoder input differs from expected audio ranges")
        XCTAssertEqual(engine.calls.map(\.language), ["it", "it"])
    }

    func testTwoBackgroundPhrasesAndFinalTailCoverTheAudioExactlyOnce() async throws {
        let engine = RecordingBackgroundEngine()
        let first = speech + pause
        let second = speech.map { $0 * 2 } + pause
        let tail = [Float](repeating: 0.07, count: 5_137)
        let session = BackgroundTranscriptionSession(engine: engine, language: "de")
        session.append(first, at: 0)
        try await engine.waitForCalls(1)
        session.append(second, at: first.count)
        try await engine.waitForCalls(2)
        let text = try await session.finish(samples: first + second + tail)
        XCTAssertEqual(text, "phrase1 phrase2 phrase3")
        XCTAssertTrue(engine.calls.map(\.samples) == [first, second, tail], "decoder input differs from expected audio ranges")
    }

    func testSilenceFollowingCommittedTextDoesNotStartAnotherDecode() async throws {
        let engine = RecordingBackgroundEngine()
        let phrase = speech + pause
        let session = BackgroundTranscriptionSession(engine: engine, language: "auto")
        session.append(phrase, at: 0)
        try await engine.waitForCalls(1)
        let text = try await session.finish(samples: phrase + pause)
        XCTAssertEqual(text, "phrase1")
        XCTAssertEqual(engine.calls.count, 1)
    }

    func testTailUnderTheModelMinimumIsDecodedWithTheLastPhrase() async throws {
        let engine = RecordingBackgroundEngine()
        let first = speech + pause
        let second = speech.map { $0 * 2 } + pause
        // 149 ms of room noise after the last pause, as in recovery 99FB294A. Parakeet throws on
        // anything under 300 ms, and that throw used to fail the whole dictation.
        let tail = [Float](repeating: 0.004, count: 2_383)
        let session = BackgroundTranscriptionSession(engine: engine, language: "it")
        session.append(first, at: 0)
        try await engine.waitForCalls(1)
        session.append(second, at: first.count)
        try await engine.waitForCalls(2)
        let text = try await session.finish(samples: first + second + tail)
        XCTAssertEqual(text, "phrase1 phrase3")
        XCTAssertTrue(engine.calls.map(\.samples) == [first, second, second + tail],
                      "the short tail was not decoded together with the phrase before it")
        XCTAssertTrue(engine.calls.allSatisfy { $0.samples.count >= BackgroundTranscriptionSession.minimumDecodeSamples })
    }

    func testEmptyRedecodeOfTheLastPhraseKeepsItsCommittedText() async throws {
        let engine = RecordingBackgroundEngine(mode: .emptyAfterFirst)
        let phrase = speech + pause
        let tail = [Float](repeating: 0.004, count: 2_383)
        let session = BackgroundTranscriptionSession(engine: engine, language: "it")
        session.append(phrase, at: 0)
        try await engine.waitForCalls(1)
        let text = try await session.finish(samples: phrase + tail)
        XCTAssertEqual(text, "phrase1")
        XCTAssertTrue(engine.calls.map(\.samples) == [phrase, phrase + tail], "decoder input differs from expected audio ranges")
    }

    func testShortUtteranceUsesOneCompleteDecode() async throws {
        let engine = RecordingBackgroundEngine()
        let samples = Array(speech.prefix(3_200))
        let session = BackgroundTranscriptionSession(engine: engine, language: "en")
        session.append(samples, at: 0)
        let text = try await session.finish(samples: samples)
        XCTAssertEqual(text, "phrase1")
        XCTAssertTrue(engine.calls.map(\.samples) == [samples], "decoder input differs from expected audio ranges")
    }

    func testMissingOrReorderedChunkFallsBackToCompleteRecording() async throws {
        for offset in [1, -1, 5_000] {
            let engine = RecordingBackgroundEngine()
            let phrase = speech + pause
            let session = BackgroundTranscriptionSession(engine: engine, language: "it")
            session.append(phrase, at: offset)
            _ = try await session.finish(samples: phrase)
            XCTAssertTrue(engine.calls.map(\.samples) == [phrase], "decoder input differs from expected audio ranges")
        }
    }

    func testEmptyOrFailedBackgroundResultRetriesAllAudio() async throws {
        for mode in [RecordingBackgroundEngine.Mode.emptyFirst, .failFirst] {
            let engine = RecordingBackgroundEngine(mode: mode)
            let phrase = speech + pause
            let complete = phrase + [0.08, 0.09]
            let session = BackgroundTranscriptionSession(engine: engine, language: "auto")
            session.append(phrase, at: 0)
            try await engine.waitForCalls(1)
            let text = try await session.finish(samples: complete)
            XCTAssertEqual(text, "phrase2")
            XCTAssertTrue(engine.calls.map(\.samples) == [phrase, complete], "decoder input differs from expected audio ranges")
        }
    }

    func testQueueOverflowRetriesCompleteAudioWithoutLosingSamples() async throws {
        let engine = RecordingBackgroundEngine(mode: .holdFirst)
        let phrase = speech + pause
        let session = BackgroundTranscriptionSession(
            engine: engine, language: "it", tuning: .init(queuedChunks: 1)
        )
        session.append(phrase, at: 0)
        try await engine.waitForCalls(1)
        session.append([0.11], at: phrase.count)
        session.append([0.12], at: phrase.count + 1)
        session.append([0.13], at: phrase.count + 2)
        engine.release()
        let complete = phrase + [0.11, 0.12, 0.13]
        _ = try await session.finish(samples: complete)
        XCTAssertTrue(engine.calls.map(\.samples) == [phrase, complete], "decoder input differs from expected audio ranges")
    }

    func testCancellationWaitsForNativeWorkAndNeverDecodesTheTail() async throws {
        let engine = RecordingBackgroundEngine(mode: .holdFirst)
        let finished = BackgroundCompletionProbe()
        let phrase = speech + pause
        let session = BackgroundTranscriptionSession(
            engine: engine, language: "it", onFinished: { finished.mark() }
        )
        session.append(phrase, at: 0)
        try await engine.waitForCalls(1)
        XCTAssertTrue(session.cancel(), "an uncooperative native call must retain its lease")
        XCTAssertEqual(finished.count, 0)
        session.append(phrase, at: phrase.count)
        engine.release()
        do {
            _ = try await session.finish(samples: phrase + phrase)
            XCTFail("cancelled session returned text")
        } catch is CancellationError {} catch { XCTFail("unexpected error: \(error)") }
        XCTAssertEqual(finished.count, 1)
        XCTAssertEqual(engine.calls.count, 1)
    }

    func testCancellingAnIdleSessionNeedsNoEngineQuarantine() async throws {
        let engine = RecordingBackgroundEngine()
        let session = BackgroundTranscriptionSession(engine: engine, language: "it")
        XCTAssertFalse(session.cancel())
        do {
            _ = try await session.finish(samples: speech)
            XCTFail("cancelled session returned text")
        } catch is CancellationError {} catch { XCTFail("unexpected error: \(error)") }
        XCTAssertTrue(engine.calls.isEmpty)
    }

    func testStopWhileBackgroundDecodeIsRunningSerializesTheTail() async throws {
        let engine = RecordingBackgroundEngine(mode: .holdFirst)
        let phrase = speech + pause
        let tail = [Float](repeating: 0.08, count: BackgroundTranscriptionSession.minimumDecodeSamples)
        let session = BackgroundTranscriptionSession(engine: engine, language: "it")
        session.append(phrase, at: 0)
        try await engine.waitForCalls(1)
        let stop = Task { try await session.finish(samples: phrase + tail) }
        engine.release()
        let text = try await stop.value
        XCTAssertEqual(text, "phrase1 phrase2")
        XCTAssertTrue(engine.calls.map(\.samples) == [phrase, tail], "decoder input differs from expected audio ranges")
        XCTAssertEqual(engine.maximumConcurrency, 1)
    }

    func testPauseBoundariesAreIndependentOfPumpSliceSize() {
        let audio = speech + pause + speech + pause
        for strideSize in [1, 157, 320, 3_031, audio.count] {
            var segmenter = BackgroundPhraseSegmenter()
            var chunks: [[Float]] = []
            for start in stride(from: 0, to: audio.count, by: strideSize) {
                chunks += segmenter.append(Array(audio[start..<min(start + strideSize, audio.count)]))
            }
            XCTAssertEqual(chunks, [speech + pause, speech + pause])
        }
    }

    func testLongUninterruptedSpeechIsNotCutAndBackgroundMemoryIsBounded() {
        var segmenter = BackgroundPhraseSegmenter()
        let longSpeech = [Float](repeating: 0.03, count: 16_000 * 20)
        XCTAssertTrue(segmenter.append(longSpeech).isEmpty)
        XCTAssertTrue(segmenter.suspended)
        XCTAssertTrue(segmenter.append(pause + speech + pause).isEmpty)
    }

    func testShortPausesAndQuietWordsDoNotCloseAPhrase() {
        var segmenter = BackgroundPhraseSegmenter()
        let shortPause = [Float](repeating: 0, count: 4_800)
        let quietWord = [Float](repeating: 0.002, count: 8_000)
        XCTAssertTrue(segmenter.append(speech + shortPause + quietWord).isEmpty)
    }

    func testAudioPumpOffsetsAndFinalDrainPreserveTheUnpumpedTailAcrossRecordings() {
        let capture = RealtimeState(sampleCapacity: 16_000, frameLevelCapacity: 100)
        for _ in 0..<2 {
            capture.setIncremental(true)
            capture.reset()
            let first: [Float] = [0.1, 0.2]
            first.withUnsafeBufferPointer { capture.append(samples: $0.baseAddress!, count: $0.count) }
            let chunk = capture.takeNewSamples()
            XCTAssertEqual(chunk?.offset, 0)
            XCTAssertEqual(chunk?.samples, first)
            let last: [Float] = [0.3, 0.4, 0.5]
            last.withUnsafeBufferPointer { capture.append(samples: $0.baseAddress!, count: $0.count) }
            XCTAssertEqual(capture.drainSamples(), first + last)
            capture.reset()
        }
    }
}

private final class BackgroundCompletionProbe: Sendable {
    private let value = OSAllocatedUnfairLock(initialState: 0)
    var count: Int { value.withLock { $0 } }
    func mark() { value.withLock { $0 += 1 } }
}

private final class RecordingBackgroundEngine: TranscriptionEngine, Sendable {
    enum Mode { case normal, emptyFirst, failFirst, holdFirst, emptyAfterFirst }
    struct Call { let samples: [Float]; let language: String }
    private struct State {
        var calls: [Call] = []
        var active = 0
        var maximumConcurrency = 0
        var released = false
        var continuation: CheckedContinuation<Void, Never>?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let mode: Mode
    init(mode: Mode = .normal) { self.mode = mode }
    var calls: [Call] { state.withLock { $0.calls } }
    var maximumConcurrency: Int { state.withLock { $0.maximumConcurrency } }
    func warmUp(progress: @escaping @Sendable (Double) -> Void) async throws {}
    func currentModelName() async -> String { "recording test engine" }

    func transcribe(samples: [Float], language: String) async throws -> String {
        let count = state.withLock { st in
            st.calls.append(Call(samples: samples, language: language))
            st.active += 1
            st.maximumConcurrency = max(st.active, st.maximumConcurrency)
            return st.calls.count
        }
        defer { state.withLock { $0.active -= 1 } }
        if count == 1 {
            switch mode {
            case .normal, .emptyAfterFirst: break
            case .emptyFirst: return ""
            case .failFirst: throw TranscriptionError.inferenceFailed("background test failure")
            case .holdFirst:
                // Deliberately ignores Swift cancellation, like a native model call.
                await withCheckedContinuation { continuation in
                    let released = state.withLock { st in
                        if st.released { return true }
                        st.continuation = continuation
                        return false
                    }
                    if released { continuation.resume() }
                }
            }
        }
        if count > 1, mode == .emptyAfterFirst { return "" }
        return "phrase\(count)"
    }

    func release() {
        let continuation = state.withLock { st in
            st.released = true
            let c = st.continuation
            st.continuation = nil
            return c
        }
        continuation?.resume()
    }

    func waitForCalls(_ count: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while calls.count < count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        guard calls.count >= count else {
            throw TranscriptionError.inferenceFailed("background inference never started")
        }
    }
}
