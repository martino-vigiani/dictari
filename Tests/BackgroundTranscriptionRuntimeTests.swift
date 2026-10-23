import XCTest
import os

/// Explicit, slower local-model check. Speech is synthesized to files and never played;
/// no microphone, event tap, application launch or paste is involved.
final class BackgroundTranscriptionRuntimeTests: XCTestCase {
    func testOneMinuteItalianDictationReusesWorkWithoutBlockingMainActor() async throws {
        let model = ParakeetEngine(displayName: "Parakeet v3")
        try await model.warmUp { _ in }
        let sentences = [
            "Domani mattina devo passare in ufficio per ritirare tutti i documenti.",
            "Poi controllo il progetto e preparo una relazione per la riunione.",
            "Ricordati di aggiungere anche le ultime tre parole: mare sole montagna."
        ]
        var paragraph: [Float] = []
        for sentence in sentences {
            paragraph += try AudioFixture.samples(text: sentence, voice: "Alice")
            paragraph += [Float](repeating: 0, count: 9_600)
        }
        // Stop immediately after the final spoken sentence, without an artificial final pause.
        let samples = Array(Array(repeating: paragraph, count: 5).flatMap { $0 }.dropLast(9_600))
        let expected = Array(repeating: sentences.joined(separator: " "), count: 5).joined(separator: " ")
        let batchStart = ContinuousClock.now
        let batch = try await model.transcribe(samples: samples, language: "auto")
        let batchSeconds = seconds(batchStart.duration(to: .now))

        let heartbeat = Task.detached { () -> Double in
            var maximum: Double = 0
            while !Task.isCancelled {
                let started = ContinuousClock.now
                await MainActor.run {}
                let duration = started.duration(to: .now).components
                maximum = max(maximum, Double(duration.seconds) + Double(duration.attoseconds) / 1e18)
                try? await Task.sleep(for: .milliseconds(20))
            }
            return maximum
        }
        defer { heartbeat.cancel() }
        let measured = MeasuredBackgroundEngine(engine: model)
        let session = BackgroundTranscriptionSession(engine: measured, language: "auto")
        let start = ContinuousClock.now
        for offset in stride(from: 0, to: samples.count - 560, by: 1_600) {
            let end = min(offset + 1_600, samples.count - 560)
            session.append(Array(samples[offset..<end]), at: offset)
            try await Task.sleep(until: start + .seconds(Double(end) / 16_000), clock: .continuous)
        }
        let beforeStop = measured.calls.count
        let stop = ContinuousClock.now
        let result = try await session.finish(samples: samples)
        let stopSeconds = seconds(stop.duration(to: .now))
        heartbeat.cancel()
        let maximumMainActorDelay = await heartbeat.value
        XCTAssertGreaterThan(beforeStop, 5)
        XCTAssertLessThan(stopSeconds, batchSeconds * 0.8, "long dictation did not reduce stop latency")
        XCTAssertGreaterThanOrEqual(TranscriptMatch.wordRecall(expected: expected, actual: result), 0.95)
        XCTAssertGreaterThanOrEqual(TranscriptMatch.wordRecall(expected: batch, actual: result), 0.95)
        XCTAssertEqual(result.components(separatedBy: "montagna").count - 1, 5,
                       "a repeated phrase was omitted or duplicated")
        XCTAssertLessThan(maximumMainActorDelay, 0.5, "main actor stalled during background inference")
        XCTAssertLessThanOrEqual(measured.calls.reduce(0, +), samples.count,
                                 "background decoding repeatedly processed the same audio")
        print("BACKGROUND_LONG_BENCH audio=\(Double(samples.count) / 16_000)s batch=\(batchSeconds)s stop=\(stopSeconds)s backgroundCalls=\(beforeStop) maxMainActorWait=\(maximumMainActorDelay)s calls=\(measured.timings)")
    }

    func testPacedMultilingualSpeechReusesWorkAndPreservesFinalWords() async throws {
        let model = ParakeetEngine(displayName: "Parakeet v3")
        try await model.warmUp { _ in }
        let fixtures = [
            ("it", "Alice", [
                "Domani mattina devo passare in ufficio per ritirare tutti i documenti.",
                "Poi controllo il progetto e preparo una relazione per la riunione.",
                "Ricordati di aggiungere anche le ultime tre parole: mare sole montagna."
            ]),
            ("en", "Samantha", [
                "Tomorrow morning I need to collect all the documents from the office.",
                "Then I will review the project and prepare a report for the meeting.",
                "Please remember the final three words: river mountain sunshine."
            ]),
            ("de", "Anna", [
                "Morgen früh muss ich ins Büro gehen und alle wichtigen Dokumente abholen.",
                "Danach überprüfe ich das Projekt und bereite einen Bericht für die Besprechung vor.",
                "Bitte denke auch an die letzten drei Wörter: Sonne Meer Berge."
            ])
        ]
        for (language, voice, sentences) in fixtures {
            var samples: [Float] = []
            for (index, sentence) in sentences.enumerated() {
                samples += try AudioFixture.samples(text: sentence, voice: voice)
                if index < sentences.count - 1 { samples += [Float](repeating: 0, count: 9_600) }
            }
            let expected = sentences.joined(separator: " ")
            let batchStart = ContinuousClock.now
            let batch = try await model.transcribe(samples: samples, language: language)
            let batchSeconds = seconds(batchStart.duration(to: .now))

            let measured = MeasuredBackgroundEngine(engine: model)
            let session = BackgroundTranscriptionSession(engine: measured, language: language)
            let feedStart = ContinuousClock.now
            // Leave the final 35 ms unpumped, as happens when the hotkey beats the audio timer.
            let pumpedCount = max(0, samples.count - 560)
            for offset in stride(from: 0, to: pumpedCount, by: 1_600) {
                let end = min(offset + 1_600, pumpedCount)
                session.append(Array(samples[offset..<end]), at: offset)
                try await Task.sleep(until: feedStart + .seconds(Double(end) / 16_000), clock: .continuous)
            }
            let beforeStop = measured.calls.count
            let stopStart = ContinuousClock.now
            let streamed = try await session.finish(samples: samples)
            let stopSeconds = seconds(stopStart.duration(to: .now))
            let recall = TranscriptMatch.wordRecall(expected: expected, actual: streamed)
            let batchRecall = TranscriptMatch.wordRecall(expected: expected, actual: batch)
            let batchTail = TranscriptMatch.normalize(batch).split(separator: " ").suffix(3)
            let streamedTail = TranscriptMatch.normalize(streamed).split(separator: " ").suffix(3)
            XCTAssertGreaterThan(beforeStop, 0, "no model work happened while speaking (\(language))")
            XCTAssertLessThan(stopSeconds, 1.5, "short dictation finalization exceeded the latency budget")
            XCTAssertGreaterThanOrEqual(recall, 0.9, "\(language): \(streamed)")
            XCTAssertGreaterThanOrEqual(recall, batchRecall - 0.05, "accuracy regressed: \(streamed)")
            // Compare against the same model's complete recording. German Meer/mehr are
            // homophones: demanding a new spelling here confuses ASR accuracy with tail loss.
            XCTAssertEqual(streamedTail, batchTail, "last words differ from batch: \(streamed)")
            XCTAssertEqual(streamedTail.count, 3)
            XCTAssertEqual(measured.calls.reduce(0) { $0 + $1 }, samples.count,
                           "audio was skipped or redundantly decoded")
            XCTAssertLessThan(measured.calls.last ?? samples.count, samples.count,
                              "stop decoded the full recording again")
            print("BACKGROUND_BENCH language=\(language) audio=\(Double(samples.count) / 16_000)s batch=\(batchSeconds)s stop=\(stopSeconds)s backgroundCalls=\(beforeStop) calls=\(measured.calls) callSeconds=\(measured.timings) recall=\(recall) batchRecall=\(batchRecall) batchTail=\(batchTail) streamedTail=\(streamedTail)")
        }
    }

    /// Recovery 99FB294A (9 Oct 2026): a phrase closed by its pause, then 149 ms of room noise
    /// before the key-up. Decoded alone the tail threw "Invalid audio data … at least 300ms" and
    /// failed the whole dictation; padded with zeros it decoded as "Yeah.".
    func testRoomNoiseTailUnder300MillisecondsKeepsThePhraseAndAddsNothing() async throws {
        let model = ParakeetEngine(displayName: "Parakeet v3")
        try await model.warmUp { _ in }
        let sentence = "Come si recuperano le sessioni archiviate? Domani controllo tutto con calma."
        var generator = SystemRandomNumberGenerator()
        let noise = (0..<2_383).map { _ in Float.random(in: -0.004...0.004, using: &generator) }
        let samples = try AudioFixture.samples(text: sentence, voice: "Alice")
            + [Float](repeating: 0, count: 9_600) + noise
        let batch = try await model.transcribe(samples: samples, language: "auto")

        let measured = MeasuredBackgroundEngine(engine: model)
        let session = BackgroundTranscriptionSession(engine: measured, language: "auto")
        let feedStart = ContinuousClock.now
        for offset in stride(from: 0, to: samples.count, by: 1_600) {
            let end = min(offset + 1_600, samples.count)
            session.append(Array(samples[offset..<end]), at: offset)
            try await Task.sleep(until: feedStart + .seconds(Double(end) / 16_000), clock: .continuous)
        }
        let streamed = try await session.finish(samples: samples)
        XCTAssertGreaterThanOrEqual(measured.calls.count, 2,
                                    "no phrase was committed before stop, so the short tail was not exercised")
        XCTAssertTrue(measured.calls.allSatisfy { $0 >= BackgroundTranscriptionSession.minimumDecodeSamples },
                      "a slice under 300 ms reached the model: \(measured.calls)")
        XCTAssertGreaterThanOrEqual(TranscriptMatch.wordRecall(expected: sentence, actual: streamed), 0.9, streamed)
        XCTAssertEqual(TranscriptMatch.normalize(streamed), TranscriptMatch.normalize(batch),
                       "background result differs from the complete recording")
    }

    private func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}

private final class MeasuredBackgroundEngine: TranscriptionEngine, Sendable {
    let engine: any TranscriptionEngine
    private let recordings = OSAllocatedUnfairLock(initialState: [Int]())
    private let durations = OSAllocatedUnfairLock(initialState: [Double]())
    var calls: [Int] { recordings.withLock { $0 } }
    var timings: [Double] { durations.withLock { $0 } }
    init(engine: any TranscriptionEngine) { self.engine = engine }
    func warmUp(progress: @escaping @Sendable (Double) -> Void) async throws {}
    func currentModelName() async -> String { "measured Parakeet" }
    func transcribe(samples: [Float], language: String) async throws -> String {
        recordings.withLock { $0.append(samples.count) }
        let started = ContinuousClock.now
        defer {
            let d = started.duration(to: .now).components
            durations.withLock { $0.append(Double(d.seconds) + Double(d.attoseconds) / 1e18) }
        }
        return try await engine.transcribe(samples: samples, language: language)
    }
}
