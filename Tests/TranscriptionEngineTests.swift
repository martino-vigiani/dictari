// TranscriptionEngineTests.swift
// End-to-end checks that the shipping engine actually turns speech into text.
//
// These are the tests that answer "does the app work?" without a human pressing a hotkey.
// They synthesize real speech, run it through ParakeetEngine exactly as the coordinator
// does, and assert the transcript resembles what was spoken — in the three languages the
// product is sold on.
//
// The model is downloaded on first run (~460 MB), so the warm-up allowance is generous.
// Subsequent runs load from ~/Library/Application Support/FluidAudio/Models.

import XCTest

/// Loads the model once for the whole test run.
///
/// Deliberately an actor awaited from the tests rather than a blocking `class func setUp`:
/// blocking the main thread while the model loads stops XCTest from servicing its own run
/// loop, and the runner is reported as hung before it ever connects.
actor SharedParakeet {
    static let shared = SharedParakeet()

    private var warmed: ParakeetEngine?
    private var failure: String?

    func engine() async throws -> ParakeetEngine {
        if let warmed { return warmed }
        if let failure { throw XCTSkip("Parakeet model unavailable: \(failure)") }

        let engine = ParakeetEngine(displayName: "Parakeet v3")
        do {
            try await engine.warmUp { _ in }
            warmed = engine
            return engine
        } catch {
            failure = error.localizedDescription
            throw XCTSkip("Parakeet model unavailable: \(error.localizedDescription)")
        }
    }
}

final class TranscriptionEngineTests: XCTestCase {

    private func loadedEngine() async throws -> ParakeetEngine {
        try await SharedParakeet.shared.engine()
    }

    // MARK: - The languages the product is sold on

    func testTranscribesEnglish() async throws {
        try await assertTranscribes(
            "The quick brown fox jumps over the lazy dog near the river bank.",
            voice: "Samantha",
            language: "en"
        )
    }

    func testTranscribesGerman() async throws {
        try await assertTranscribes(
            "Ich möchte morgen früh einen Termin bei meinem Zahnarzt vereinbaren.",
            voice: "Anna",
            language: "de"
        )
    }

    func testTranscribesItalian() async throws {
        try await assertTranscribes(
            "Domani mattina devo passare in ufficio per ritirare i documenti.",
            voice: "Alice",
            language: "it"
        )
    }

    // MARK: - Behaviour the dictation loop depends on

    /// Silence must come back empty. Whisper is known to hallucinate text on silence; if
    /// Parakeet ever starts doing it, the app would paste invented words into the user's
    /// document every time the hotkey is tapped by accident.
    func testSilenceProducesNoText() async throws {
        let engine = try await loadedEngine()
        let silence = [Float](repeating: 0, count: 16_000 * 2)
        let text = try await engine.transcribe(samples: silence, language: "en")
        XCTAssertTrue(
            text.isEmpty,
            "silence should transcribe to nothing, got \"\(text)\""
        )
    }

    func testEmptyInputReturnsEmptyWithoutInference() async throws {
        let engine = try await loadedEngine()
        let text = try await engine.transcribe(samples: [], language: "en")
        XCTAssertEqual(text, "")
    }

    /// Two dictations in a row must not bleed into each other: each utterance starts from a
    /// fresh decoder state, so the second transcript must not contain the first one's words.
    func testConsecutiveDictationsDoNotLeak() async throws {
        let engine = try await loadedEngine()

        let first = try AudioFixture.samples(
            text: "The parliament approved the budget yesterday.", voice: "Samantha")
        let second = try AudioFixture.samples(
            text: "My bicycle needs a new chain.", voice: "Samantha")

        _ = try await engine.transcribe(samples: first, language: "en")
        let secondText = try await engine.transcribe(samples: second, language: "en")

        XCTAssertFalse(
            TranscriptMatch.normalize(secondText).contains("parliament"),
            "state leaked between utterances: \"\(secondText)\""
        )
        XCTAssertGreaterThan(
            TranscriptMatch.wordRecall(expected: "bicycle needs a new chain", actual: secondText),
            0.5,
            "second utterance transcribed poorly: \"\(secondText)\""
        )
    }

    /// The engine must reject work before warm-up rather than crash or return junk.
    func testTranscribeBeforeWarmUpThrowsNotReady() async throws {
        let cold = ParakeetEngine(displayName: "cold")
        do {
            _ = try await cold.transcribe(samples: [0.1, 0.2, 0.3], language: "en")
            XCTFail("expected notReady")
        } catch let error as TranscriptionError {
            guard case .notReady = error else {
                return XCTFail("expected notReady, got \(error)")
            }
        }
    }

    func testWarmUpIsIdempotent() async throws {
        let engine = try await loadedEngine()
        // A second warm-up on an already-loaded engine must return promptly and not reload.
        let started = Date()
        try await engine.warmUp { _ in }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5,
                          "warm-up re-ran work on an already-warm engine")
    }

    // MARK: - Helper

    private func assertTranscribes(
        _ spoken: String,
        voice: String,
        language: String,
        minimumRecall: Double = 0.6,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let engine = try await loadedEngine()
        let samples = try AudioFixture.samples(text: spoken, voice: voice)

        XCTAssertGreaterThan(samples.count, 16_000 / 2,
                             "fixture audio is suspiciously short", file: file, line: line)

        let text = try await engine.transcribe(samples: samples, language: language)

        XCTAssertFalse(text.isEmpty, "engine returned no text", file: file, line: line)

        let recall = TranscriptMatch.wordRecall(expected: spoken, actual: text)
        XCTAssertGreaterThanOrEqual(
            recall, minimumRecall,
            """
            transcript too far from the spoken text (recall \(String(format: "%.2f", recall)))
              spoken: \(spoken)
              got:    \(text)
            """,
            file: file, line: line
        )
    }
}
