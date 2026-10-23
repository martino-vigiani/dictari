// TranscriptConfidenceTests.swift
// Dictari — per-word confidence from engine to History, and the confidence-gated corrector.
//
// As in VocabularyTests, the negative cases matter as much as the positive ones: a looser match
// is only acceptable because it is fenced in by the engine's own uncertainty.

import FluidAudio
import XCTest
import os

final class TranscriptConfidenceTests: XCTestCase {

    // MARK: - Parakeet token grouping

    private func token(_ text: String, _ confidence: Float) -> TokenTiming {
        TokenTiming(token: text, tokenId: 0, startTime: 0, endTime: 0.08, confidence: confidence)
    }

    func testGroupsSentencePiecesIntoWordsWithTheWeakestPieceAsConfidence() {
        // FluidAudio 0.15.7 hands tokens over with "▁" already turned into a space.
        let words = ParakeetWordGrouping.words(from: [
            token(" Uso", 0.98), token(" Ch", 0.91), token("uber", 0.42), token("net", 0.77),
            token("is", 0.88), token(" ogni", 0.97), token(" giorno", 0.99), token(".", 0.95),
        ])
        XCTAssertEqual(words.map(\.text), ["Uso", "Chubernetis", "ogni", "giorno."])
        XCTAssertEqual(words.map(\.confidence), [0.98, 0.42, 0.97, 0.95])
    }

    func testAcceptsTheRawSentencePieceMarkerAndSkipsControlPieces() {
        let words = ParakeetWordGrouping.words(from: [
            token("<blank>", 0.1), token("\u{2581}l", 0.9), token("'", 0.8), token("albero", 0.7),
            token("<pad>", 0.0), token("\u{2581}", 0.99), token("è", 0.6), token("<unk>", 0.01),
        ])
        XCTAssertEqual(words.map(\.text), ["l'albero", "è"])
        XCTAssertEqual(words.map(\.confidence), [0.7, 0.6])
    }

    func testNonFiniteOrOutOfRangeScoresNeverPoisonAWord() {
        let words = ParakeetWordGrouping.words(from: [
            token(" ciao", .nan), token(" a", 1.7), token(" tutti", -0.2),
        ])
        XCTAssertEqual(words.map(\.text), ["ciao", "a", "tutti"])
        XCTAssertEqual(words.map(\.confidence), [nil, 1, 0])
    }

    func testEmptyTimingsProduceNoWords() {
        XCTAssertTrue(ParakeetWordGrouping.words(from: []).isEmpty)
    }

    // MARK: - Output plumbing

    func testUnscoredOutputHasWordsButNoConfidence() {
        let output = TranscriptionOutput.unscored("Ciao  a tutti")
        XCTAssertEqual(output.text, "Ciao  a tutti")
        XCTAssertEqual(output.words.map(\.text), ["Ciao", "a", "tutti"])
        XCTAssertFalse(output.hasConfidence)
    }

    func testJoinedTextIsExactlyThePhraseStitchingRule() {
        let parts = [
            TranscriptionOutput(text: "Prima frase.", words: [.init(text: "Prima", confidence: 0.9),
                                                              .init(text: "frase.", confidence: 0.4)]),
            TranscriptionOutput(text: "Seconda", words: [.init(text: "Seconda", confidence: 0.8)]),
        ]
        let joined = TranscriptionOutput.joined(parts)
        XCTAssertEqual(joined.text, parts.map(\.text).joined(separator: " "))
        XCTAssertEqual(joined.words.map(\.confidence), [0.9, 0.4, 0.8])
    }

    func testWhisperLogProbabilityMapsOntoTheSameScale() {
        XCTAssertEqual(TranscriptConfidence.confidence(fromAverageLogProbability: 0), 1)
        XCTAssertEqual(TranscriptConfidence.confidence(fromAverageLogProbability: -0.6)!, 0.549, accuracy: 0.001)
        XCTAssertNil(TranscriptConfidence.confidence(fromAverageLogProbability: -.infinity))
        XCTAssertNil(TranscriptConfidence.confidence(fromAverageLogProbability: .nan))
    }

    func testAlignmentMatchesWholeWordsInOrderAndSkipsWhatItCannotFind() {
        let text = "casa, a casa «Kubernetes»"
        let words: [TranscribedWord] = [
            .init(text: "casa,"), .init(text: "missing"), .init(text: "a"),
            .init(text: "casa"), .init(text: "«Kubernetes»"),
        ]
        let ranges = TranscriptConfidence.align(words, in: text)
        let found = ranges.map { $0.map { String(text[$0]) } }
        XCTAssertEqual(found, ["casa", nil, "a", "casa", "Kubernetes"])
        // "a" must be the standalone word, not the "a" inside the first "casa".
        XCTAssertEqual(text.distance(from: text.startIndex, to: ranges[2]!.lowerBound), 6)
    }

    // MARK: - Uncertain spans

    func testSpansAreUTF16OffsetsIntoTheFinalText() {
        let text = "Già 🙂 usato Kubernetes."
        let spans = UncertainSpan.locate(
            [UncertainWord(text: "usato", confidence: 0.5), UncertainWord(text: "kubernetes", confidence: 0.3)],
            in: text
        )
        let ns = text as NSString
        XCTAssertEqual(spans.map { ns.substring(with: NSRange(location: $0.location, length: $0.length)) },
                       ["usato", "Kubernetes"])
        XCTAssertEqual(spans.map(\.confidence), [0.5, 0.3])
    }

    func testHistoryEntryWithoutSpansStillDecodes() throws {
        let old = Data(#"""
        {"id":"7E1F2C44-8B53-4E1A-9A5C-2B4C7D0E9F11","date":0,"text":"Ciao","durationSeconds":1,
         "wordCount":1,"latencyMs":90}
        """#.utf8)
        let entry = try JSONDecoder().decode(HistoryEntry.self, from: old)
        XCTAssertNil(entry.uncertainSpans)

        var scored = entry
        scored.uncertainSpans = [UncertainSpan(location: 0, length: 4, confidence: 0.4)]
        let roundTrip = try JSONDecoder().decode(HistoryEntry.self, from: JSONEncoder().encode(scored))
        XCTAssertEqual(roundTrip, scored)
    }

    // MARK: - Confidence-gated corrector

    private let kubernetes = VocabularyTerm(text: "Kubernetes")

    private func output(_ text: String, uncertain: Set<String> = [], score: Float = 0.3) -> TranscriptionOutput {
        TranscriptionOutput(
            text: text,
            words: text.split(separator: " ").map { piece in
                let word = String(piece)
                let core = String(TranscriptConfidence.core(of: word))
                return TranscribedWord(text: word, confidence: uncertain.contains(core) ? score : 0.97)
            }
        )
    }

    func testFixesAnUncertainItalianMishearingOfATerm() {
        let c = VocabularyCorrector(terms: [kubernetes])
        let result = c.correct(output("Domani aggiorno il cluster Chubernetis.", uncertain: ["Chubernetis"]))
        XCTAssertEqual(result.text, "Domani aggiorno il cluster Kubernetes.")
        XCTAssertEqual(result.corrections, [VocabularyCorrection(original: "Chubernetis", replacement: "Kubernetes")])
        // The span follows the word into its corrected spelling.
        XCTAssertEqual(result.uncertainWords, [UncertainWord(text: "Kubernetes", confidence: 0.3)])
    }

    func testLeavesTheSameMishearingAloneWhenTheEngineWasSure() {
        let c = VocabularyCorrector(terms: [kubernetes])
        let text = "Domani aggiorno il cluster Chubernetis."
        XCTAssertEqual(c.correct(output(text)).text, text)
        XCTAssertEqual(c.correct(text), text, "the strict corrector must not reach it either")
    }

    func testAtTheThresholdAWordCountsAsConfident() {
        let c = VocabularyCorrector(terms: [kubernetes])
        let text = "cluster Chubernetis"
        let atThreshold = output(text, uncertain: ["Chubernetis"], score: TranscriptConfidence.uncertainThreshold)
        XCTAssertEqual(c.correct(atThreshold).text, text)
    }

    func testSoundClassesAcrossItalianEnglishAndGerman() {
        let c = VocabularyCorrector(terms: [
            VocabularyTerm(text: "Wikipedia"), VocabularyTerm(text: "Schiaparelli"),
            VocabularyTerm(text: "Philips"), VocabularyTerm(text: "Schwarzkopf"),
            VocabularyTerm(text: "Nietzsche"), VocabularyTerm(text: "Dictari"),
        ])
        let cases = [
            ("Vichipedia", "Wikipedia"),       // v/w, ch/k
            ("Sciaparelli", "Schiaparelli"),   // sc(i)/sch
            ("Filips", "Philips"),             // f/ph
            ("Schwartskopf", "Schwarzkopf"),   // ts/z
            ("Diktar", "Dictari"),             // c/k plus one dropped vowel (measured on Parakeet)
            ("Nicce", "Nicce"),                // not the same consonant classes: untouched
        ]
        for (heard, expected) in cases {
            let result = c.correct(output("ho letto \(heard) ieri", uncertain: [heard]))
            XCTAssertEqual(result.text, "ho letto \(expected) ieri", heard)
        }
    }

    func testCommonItalianWordsAreNeverRewrittenEvenWhenUncertain() {
        let c = VocabularyCorrector(terms: [
            kubernetes, VocabularyTerm(text: "Martino"), VocabularyTerm(text: "Dora"),
            VocabularyTerm(text: "Gnocchi"), VocabularyTerm(text: "Castello"),
        ])
        let text = "Questo cane dura poco, la casa della cugina è cara e il cabernet costa caro."
        let everyWord = Set(text.split(separator: " ").map { String(TranscriptConfidence.core(of: String($0))) })
        let result = c.correct(output(text, uncertain: everyWord, score: 0.1))
        XCTAssertEqual(result.text, text)
        XCTAssertTrue(result.corrections.isEmpty)
    }

    func testShortWordsAndProtectedSpellingsStayUntouched() {
        let c = VocabularyCorrector(terms: [
            VocabularyTerm(text: "Kafe"),                                   // 4 letters, key "kf": too short a key
            VocabularyTerm(text: "Kubernetes", alternatives: ["Cubernetes"]),
            VocabularyTerm(text: "Kubernates"),                             // the user's own spelling
        ])
        // "café" → "kf" has only two consonant classes; "Kubernates" is itself a term.
        let text = "un cafe per Kubernates"
        let result = c.correct(output(text, uncertain: ["cafe", "Kubernates"], score: 0.1))
        XCTAssertEqual(result.text, text)
    }

    func testAMultiWordTermAllowsOneLooseWordAfterAnExactOne() {
        let c = VocabularyCorrector(terms: [VocabularyTerm(text: "Google Scholar")])
        let result = c.correct(output("apri google Sholar adesso", uncertain: ["Sholar"]))
        XCTAssertEqual(result.text, "apri Google Scholar adesso")
        // The uncertain word was absorbed into a phrase replacement; the span covers it all.
        XCTAssertEqual(result.uncertainWords.map(\.text), ["Google Scholar"])
        // Confident, the same phrase is left alone.
        XCTAssertEqual(c.correct(output("apri google Sholar adesso")).text, "apri google Sholar adesso")
    }

    func testWithoutVocabularyTheTextIsUntouchedButUncertaintyIsReported() {
        let c = VocabularyCorrector(terms: [])
        let text = "Ciao Chubernetis, come va?"
        let result = c.correct(output(text, uncertain: ["Chubernetis", "va"], score: 0.2))
        XCTAssertEqual(result.text, text)
        XCTAssertEqual(result.uncertainWords.map(\.text), ["Chubernetis", "va"])
    }

    func testConfidentTranscriptsMatchTheStrictCorrectorExactly() {
        let c = VocabularyCorrector(terms: [VocabularyTerm(text: "Martino"), kubernetes,
                                            VocabularyTerm(text: "kubectl", alternatives: ["cube cuddle"])])
        for text in ["Ciao, sono Martina.", "run cube cuddle; MARTINA!", "I ordered a Martini",
                     "  spazi\n e a capo  ", ""] {
            let result = c.correct(output(text))
            XCTAssertEqual(result.text, c.correct(text), text)
            XCTAssertTrue(result.uncertainWords.isEmpty)
        }
        // Unscored output (Whisper fallback, tests' fake engines) too.
        XCTAssertEqual(c.correct(TranscriptionOutput.unscored("Martina")).text, "Martino")
    }

    func testUncertainWordsKeepTheirPlaceAroundStrictCorrections() {
        let c = VocabularyCorrector(terms: [VocabularyTerm(text: "Martino"), kubernetes])
        let result = c.correct(output("Martina usa Chubernetis e l'albero", uncertain: ["Chubernetis", "l'albero"]))
        XCTAssertEqual(result.text, "Martino usa Kubernetes e l'albero")
        XCTAssertEqual(result.uncertainWords.map(\.text), ["Kubernetes", "l'albero"])
        let spans = UncertainSpan.locate(result.uncertainWords, in: result.text)
        XCTAssertEqual(spans.map(\.location), [12, 25])
    }

    func testPhoneticKeys() {
        XCTAssertEqual(VocabularyCorrector.phonetic("chubernetis").key, "kbrnts")
        XCTAssertEqual(VocabularyCorrector.phonetic("kubernetes").key, "kbrnts")
        XCTAssertEqual(VocabularyCorrector.phonetic("bologna").key, VocabularyCorrector.phonetic("bolonya").key)
        XCTAssertEqual(VocabularyCorrector.phonetic("pizza").key, VocabularyCorrector.phonetic("pitsa").key)
        XCTAssertEqual(VocabularyCorrector.phonetic("scena").key, VocabularyCorrector.phonetic("shena").key)
        XCTAssertNotEqual(VocabularyCorrector.phonetic("scala").key, VocabularyCorrector.phonetic("shala").key)
        XCTAssertTrue(VocabularyCorrector.withinOneEdit("uee", "ueei"))
        XCTAssertTrue(VocabularyCorrector.withinOneEdit("ueei", "ueee"))
        XCTAssertFalse(VocabularyCorrector.withinOneEdit("ua", "oi"))
    }

    // MARK: - Background session stitching

    func testBackgroundSessionCarriesWordsThroughPhraseStitching() async throws {
        let engine = ScoredPhraseEngine()
        let speech = [Float](repeating: 0.03, count: 16_000 * 3)
        let pause = [Float](repeating: 0, count: 7_200)
        let phrase = speech + pause
        let tail = [Float](repeating: 0.2, count: BackgroundTranscriptionSession.minimumDecodeSamples)
        let session = BackgroundTranscriptionSession(engine: engine, language: "it")
        session.append(phrase, at: 0)
        try await engine.waitForCalls(1)
        let output = try await session.finishDetailed(samples: phrase + tail)
        XCTAssertEqual(output.text, "parola1 incerta1 parola2 incerta2")
        XCTAssertEqual(output.words.map(\.text), ["parola1", "incerta1", "parola2", "incerta2"])
        XCTAssertEqual(output.words.map(\.confidence), [0.95, 0.2, 0.95, 0.2])
    }

    func testBackgroundPlainFinishIsTheDetailedText() async throws {
        let engine = ScoredPhraseEngine()
        let session = BackgroundTranscriptionSession(engine: engine, language: "it")
        let text = try await session.finish(samples: [0.1, 0.2])
        XCTAssertEqual(text, "parola1 incerta1")
    }

    // MARK: - Cost on the stop→inject path

    /// Budget: < 2 ms added to stop→inject. Measures the three pieces this feature adds —
    /// token grouping (inside the engine call), the confidence-aware correction and span
    /// location — on a 120-word paragraph (~400 tokens) against a 150-term vocabulary, with one
    /// word in five uncertain. Debug build, so Release is faster still.
    func testAddedCostStaysWellUnderTheLatencyBudget() {
        let vocabularyWords = ["Chubernetis", "Vichipedia", "Filips"]
        var tokens: [TokenTiming] = []
        var words: [String] = []
        for i in 0..<120 {
            let word = i % 17 == 0 ? vocabularyWords[i % 3] : "parola\(i % 37)"
            words.append(word)
            let score: Float = i % 5 == 0 ? 0.35 : 0.96
            // ~3 pieces per word, like SentencePiece on Italian.
            let chars = Array(word)
            let cut1 = chars.count / 3, cut2 = 2 * chars.count / 3
            tokens.append(token(" " + String(chars[..<cut1]), score))
            tokens.append(token(String(chars[cut1..<cut2]), 0.99))
            tokens.append(token(String(chars[cut2...]) + (i % 11 == 10 ? "," : ""), 0.98))
        }
        let text = ParakeetWordGrouping.words(from: tokens).map(\.text).joined(separator: " ")

        var terms: [VocabularyTerm] = [kubernetes, VocabularyTerm(text: "Wikipedia"), VocabularyTerm(text: "Philips")]
        for i in 0..<147 {
            terms.append(VocabularyTerm(text: "Zylophar\(i)ne", alternatives: ["zylo far \(i)"]))
        }
        let corrector = VocabularyCorrector(terms: terms)

        func pass() -> [UncertainSpan] {
            let grouped = ParakeetWordGrouping.words(from: tokens)
            let result = corrector.correct(TranscriptionOutput(text: text, words: grouped))
            return UncertainSpan.locate(result.uncertainWords, in: result.text)
        }

        let spans = pass()   // warm-up, and proof the workload does real work
        XCTAssertEqual(spans.count, 24)
        XCTAssertTrue(corrector.correct(TranscriptionOutput(text: text, words: ParakeetWordGrouping.words(from: tokens)))
            .text.contains("Kubernetes"))

        let clock = ContinuousClock()
        let iterations = 50
        var groupingOnly = Duration.zero
        let total = clock.measure {
            for _ in 0..<iterations {
                groupingOnly += clock.measure { _ = ParakeetWordGrouping.words(from: tokens) }
                _ = pass()
            }
        }
        let baseline = clock.measure {
            for _ in 0..<iterations { _ = corrector.correct(text) }
        }
        func ms(_ d: Duration) -> Double {
            (Double(d.components.seconds) * 1_000 + Double(d.components.attoseconds) / 1e15) / Double(iterations)
        }
        let perPass = ms(total) - ms(groupingOnly)   // `pass()` itself includes one grouping
        let added = perPass - ms(baseline)
        print(String(format: "confidence: grouping %.3f ms (360 tokens), full pass %.3f ms, strict corrector %.3f ms, added %.3f ms",
                     ms(groupingOnly), perPass, ms(baseline), added))
        XCTAssertLessThan(added, 2, "confidence plumbing exceeds its stop→inject budget")
    }

    // MARK: - Real model

    /// Runs the real Parakeet model on synthesized Italian speech and logs every word's
    /// confidence. This is where the threshold's "correctly heard words sit above it" claim is
    /// checked: a clean `say` fixture must not come back mostly uncertain.
    func testRealParakeetReportsPerWordConfidence() async throws {
        let engine = try await SharedParakeet.shared.engine()
        let samples = try AudioFixture.samples(
            text: "Domani mattina devo passare in ufficio per ritirare i documenti di Kubernetes.",
            voice: "Alice"
        )
        let output = try await engine.transcribeDetailed(samples: samples, language: "it")
        let plain = try await engine.transcribe(samples: samples, language: "it")
        XCTAssertEqual(output.text, plain, "detailed and plain inference must agree on the text")
        XCTAssertTrue(output.hasConfidence)
        for word in output.words {
            print(String(format: "confidence %.3f  %@", word.confidence ?? -1, word.text))
        }
        let aligned = TranscriptConfidence.align(output.words, in: output.text).compactMap { $0 }.count
        XCTAssertEqual(aligned, output.words.count, "every grouped word must be found in the text")
        let uncertain = output.words.filter { ($0.confidence ?? 1) < TranscriptConfidence.uncertainThreshold }
        XCTAssertLessThanOrEqual(uncertain.count, output.words.count / 4,
                                 "clean speech should be mostly confident: \(uncertain.map(\.text))")
    }

    /// End to end on the real model: Alice says "Dictari", Parakeet hears "Diktar" at ~0.49,
    /// and only the confidence-gated pass can bring it back (the strict skeletons `dktr` and
    /// `dctr` differ). Skips, rather than fails, if a future voice/model hears it differently.
    func testRealParakeetMishearingIsRepairedOnlyThroughConfidence() async throws {
        let engine = try await SharedParakeet.shared.engine()
        let samples = try AudioFixture.samples(
            text: "Ho parlato con Martino Vigiani di Dictari e kubectl ieri sera.", voice: "Alice"
        )
        let output = try await engine.transcribeDetailed(samples: samples, language: "it")
        guard let heard = output.words.first(where: { $0.text.hasPrefix("Diktar") }),
              let score = heard.confidence, score < TranscriptConfidence.uncertainThreshold else {
            throw XCTSkip("fixture no longer produces an uncertain 'Diktar': \(output.text)")
        }
        let corrector = VocabularyCorrector(terms: [VocabularyTerm(text: "Dictari")])
        XCTAssertFalse(corrector.correct(output.text).contains("Dictari"))
        let result = corrector.correct(output)
        XCTAssertTrue(result.text.contains("Dictari"), result.text)
        XCTAssertTrue(result.uncertainWords.map(\.text).contains("Dictari"))
    }
}

/// Returns "paroleN incertaN" per call, the second word uncertain.
private final class ScoredPhraseEngine: TranscriptionEngine, Sendable {
    private let count = OSAllocatedUnfairLock(initialState: 0)
    func warmUp(progress: @escaping @Sendable (Double) -> Void) async throws {}
    func currentModelName() async -> String { "scored test engine" }

    func transcribe(samples: [Float], language: String) async throws -> String {
        try await transcribeDetailed(samples: samples, language: language).text
    }

    func transcribeDetailed(samples: [Float], language: String) async throws -> TranscriptionOutput {
        let n = count.withLock { $0 += 1; return $0 }
        return TranscriptionOutput(
            text: " parola\(n) incerta\(n) ",
            words: [.init(text: "parola\(n)", confidence: 0.95), .init(text: "incerta\(n)", confidence: 0.2)]
        )
    }

    func waitForCalls(_ expected: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while count.withLock({ $0 }) < expected, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
    }
}

/// Short Italian dictations with language "auto" came out in Cyrillic (25 Sep 2026).
final class ParakeetLanguageHintTests: XCTestCase {
    func testAutoForcesLatinScript() {
        XCTAssertEqual(ParakeetEngine.languageHint(for: "auto"), .english)
        XCTAssertEqual(ParakeetEngine.languageHint(for: ""), .english)
    }

    func testPinnedLanguagePassesThrough() {
        XCTAssertEqual(ParakeetEngine.languageHint(for: "it"), .italian)
        XCTAssertEqual(ParakeetEngine.languageHint(for: "ru"), .russian)
    }
}

extension ParakeetLanguageHintTests {
    func testUkrainianAllowsCyrillic() {
        XCTAssertEqual(ParakeetEngine.languageHint(for: "uk"), .ukrainian)
    }
}
