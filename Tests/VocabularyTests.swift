// VocabularyTests.swift
// Dictari — VocabularyCorrector.
//
// Half of these tests assert that nothing happens. That is the point: a dictation app that
// rewrites words the model got right is worse than one with no vocabulary feature at all, so
// the negative cases carry as much weight as the Martino/Martina case the feature exists for.

import XCTest

final class VocabularyTests: XCTestCase {

    private func corrector(_ terms: VocabularyTerm...) -> VocabularyCorrector {
        VocabularyCorrector(terms: terms)
    }

    private let martino = VocabularyTerm(text: "Martino")

    func testCombinedResultPreservesTextAndOrderedRewrites() {
        let c = corrector(martino, VocabularyTerm(text: "kubectl", alternatives: ["cube cuddle"]))
        let result = c.result(for: "  Martina,\nrun cube cuddle; MARTINA!")
        XCTAssertEqual(result.text, "  Martino,\nrun kubectl; MARTINO!")
        XCTAssertEqual(result.corrections.map(\.original), ["Martina", "cube cuddle", "MARTINA"])
        XCTAssertEqual(result.corrections.map(\.replacement), ["Martino", "kubectl", "MARTINO"])
    }

    func testCombinedResultLeavesUnmatchedInputUnchanged() {
        for input in ["", " \n—🙂", "Martino"] {
            let result = corrector(martino).result(for: input)
            XCTAssertEqual(result.text, input)
            XCTAssertTrue(result.corrections.isEmpty)
        }
        let empty = VocabularyCorrector(terms: []).result(for: "Martina")
        XCTAssertEqual(empty.text, "Martina")
        XCTAssertTrue(empty.corrections.isEmpty)
    }

    // MARK: - The case the feature exists for

    func testFixesTheGenderFlippedName() {
        let c = corrector(martino)
        XCTAssertEqual(c.correct("Ciao, sono Martina."), "Ciao, sono Martino.")
    }

    func testFixesTheNameInTheMiddleOfASentence() {
        let c = corrector(martino)
        XCTAssertEqual(
            c.correct("I told Martina that the build is green"),
            "I told Martino that the build is green"
        )
    }

    func testReportsWhatItChanged() {
        let c = corrector(martino)
        let corrections = c.corrections(in: "Martina and Martine")
        XCTAssertEqual(corrections.map(\.original), ["Martina", "Martine"])
        XCTAssertEqual(corrections.map(\.replacement), ["Martino", "Martino"])
    }

    func testLeavesAnAlreadyCorrectTranscriptUntouched() {
        let c = corrector(martino)
        let input = "Ciao, sono Martino."
        XCTAssertEqual(c.correct(input), input)
        XCTAssertTrue(c.corrections(in: input).isEmpty)
    }

    // MARK: - Negative cases: these must NOT be rewritten

    /// The one the brief calls out. "Martini" is a real word; `i` is a high vowel and not in
    /// the confusable class with `o`, so it survives.
    func testDoesNotRewriteMartiniTheDrink() {
        let c = corrector(martino)
        XCTAssertEqual(c.correct("I ordered a Martini"), "I ordered a Martini")
    }

    /// Different consonant skeleton (mrn vs mrtn) — rejected before distance matters, even
    /// though the plain edit distance is only 2.
    func testDoesNotRewriteADifferentWordWithASimilarShape() {
        let c = corrector(martino)
        XCTAssertEqual(c.correct("We sailed into the marina"), "We sailed into the marina")
    }

    func testDoesNotFuzzyMatchShortWords() {
        let c = corrector(VocabularyTerm(text: "Ada"))
        XCTAssertEqual(c.correct("He said odo and ado"), "He said odo and ado")
    }

    /// A word the user themselves wrote down as another term is never fuzzily eaten by its
    /// neighbour, in either direction.
    func testATermIsNeverRewrittenIntoAnotherTerm() {
        let c = corrector(VocabularyTerm(text: "Martino"), VocabularyTerm(text: "Martina"))
        XCTAssertEqual(c.correct("Martina met Martino"), "Martina met Martino")
    }

    func testDoesNotRewriteWhenTheVowelCountDiffers() {
        let c = corrector(VocabularyTerm(text: "Dictari"))
        XCTAssertEqual(c.correct("dictar and dictaria"), "dictar and dictaria")
    }

    func testDisabledTermsDoNothing() {
        let c = corrector(VocabularyTerm(text: "Martino", enabled: false))
        XCTAssertEqual(c.correct("sono Martina"), "sono Martina")
    }

    func testEmptyVocabularyReturnsTheTranscriptUnchanged() {
        let c = VocabularyCorrector(terms: [])
        XCTAssertEqual(c.correct("Ciao, sono Martina."), "Ciao, sono Martina.")
    }

    // MARK: - Word boundaries

    func testDoesNotMatchInsideALongerWord() {
        let c = corrector(VocabularyTerm(text: "Swift"))
        XCTAssertEqual(c.correct("Swiftly does not become Swiftly"), "Swiftly does not become Swiftly")
    }

    func testMatchesAWholeWordSurroundedByOtherWords() {
        let c = corrector(VocabularyTerm(text: "kubectl", alternatives: ["cube cuddle"]))
        XCTAssertEqual(c.correct("run cube cuddle apply"), "run kubectl apply")
    }

    // MARK: - Punctuation adjacency

    func testPreservesTrailingPunctuation() {
        let c = corrector(martino)
        XCTAssertEqual(c.correct("Martina, Martina! Martina?"), "Martino, Martino! Martino?")
    }

    func testPreservesEnclosingPunctuationAndQuotes() {
        let c = corrector(martino)
        XCTAssertEqual(c.correct("«Martina» (Martina) — \"Martina\""),
                       "«Martino» (Martino) — \"Martino\"")
    }

    func testPreservesAPossessive() {
        let c = corrector(martino)
        XCTAssertEqual(c.correct("Martina's Mac"), "Martino's Mac")
    }

    func testPreservesWhitespaceAndNewlines() {
        let c = corrector(martino)
        XCTAssertEqual(c.correct("  Martina\n\tMartina  "), "  Martino\n\tMartino  ")
    }

    // MARK: - Casing

    func testUsesTheStoredSpellingForCasing() {
        let c = corrector(martino)
        XCTAssertEqual(c.correct("martina arrived"), "Martino arrived")
    }

    func testPreservesShouting() {
        let c = corrector(martino)
        XCTAssertEqual(c.correct("MARTINA!"), "MARTINO!")
    }

    /// A lowercase-by-design term keeps its spelling mid-sentence but is capitalised when the
    /// transcript capitalised it — a sentence-initial "Kubectl" must not become "kubectl".
    func testCapitalisesALowercaseTermWhenTheTranscriptDid() {
        let c = corrector(VocabularyTerm(text: "kubectl", alternatives: ["cubecuddle"]))
        XCTAssertEqual(c.correct("Cubecuddle apply, then cubecuddle get"),
                       "Kubectl apply, then kubectl get")
    }

    func testRestoresCanonicalSpellingIncludingAccents() {
        let c = corrector(VocabularyTerm(text: "Bézier"))
        XCTAssertEqual(c.correct("a bezier curve"), "a Bézier curve")
    }

    // MARK: - Multi-word phrases

    func testCorrectsAMultiWordPhrase() {
        let c = corrector(VocabularyTerm(text: "Dictari Pro", alternatives: ["dictary pro"]))
        XCTAssertEqual(c.correct("I use dictary pro daily"), "I use Dictari Pro daily")
    }

    func testAMultiWordPhraseToleratesOneMisheardWord() {
        let c = corrector(VocabularyTerm(text: "Martino Vigiani"))
        XCTAssertEqual(c.correct("from Martina Vigiani"), "from Martino Vigiani")
    }

    func testAMultiWordPhraseDoesNotMatchAcrossASentenceBoundary() {
        let c = corrector(VocabularyTerm(text: "Martino Vigiani"))
        XCTAssertEqual(c.correct("Martino. Vigiani spoke"), "Martino. Vigiani spoke")
    }

    func testTheLongestPhraseWins() {
        let c = corrector(
            VocabularyTerm(text: "Martino"),
            VocabularyTerm(text: "Martino Vigiani", alternatives: ["martina viviani"])
        )
        XCTAssertEqual(c.correct("martina viviani here"), "Martino Vigiani here")
    }

    // MARK: - Alternatives

    func testAnExplicitAlternativeIsAppliedEvenWhenFuzzyRulesWouldNot() {
        // "Martelli" shares no vowel pattern with "Martino": only the explicit alternative
        // can fix it, which is exactly what alternatives are for.
        let c = corrector(VocabularyTerm(text: "Martino", alternatives: ["Martelli"]))
        XCTAssertEqual(c.correct("ciao Martelli"), "ciao Martino")
    }

    func testAlternativesAreMatchedExactlyNotFuzzily() {
        let c = corrector(VocabularyTerm(text: "Dictari", alternatives: ["dick tarry"]))
        XCTAssertEqual(c.correct("dick terry app"), "dick terry app")
    }

    // MARK: - Doubled letters

    func testFixesADoubledConsonant() {
        let c = corrector(VocabularyTerm(text: "Dictari"))
        XCTAssertEqual(c.correct("the Dictarri app"), "the Dictari app")
    }

    // MARK: - Prompt building

    func testPromptListsEnabledTermsOnly() {
        let prompt = VocabularyPrompt.promptText(for: [
            VocabularyTerm(text: "Martino"),
            VocabularyTerm(text: "Parakeet", enabled: false),
            VocabularyTerm(text: "Dictari"),
        ])
        XCTAssertEqual(prompt, "Martino, Dictari.")
    }

    func testPromptIsNilWhenThereIsNothingToSay() {
        XCTAssertNil(VocabularyPrompt.promptText(for: []))
        XCTAssertNil(VocabularyPrompt.promptText(for: [VocabularyTerm(text: "x", enabled: false)]))
    }

    func testPromptStaysWithinItsCharacterBudget() {
        let terms = (0..<50).map { VocabularyTerm(text: "Term\($0)") }
        let prompt = try? XCTUnwrap(VocabularyPrompt.promptText(for: terms, maxCharacters: 40))
        XCTAssertLessThanOrEqual((prompt ?? "").count, 41)   // budget + the final full stop
    }

    // MARK: - Decoding

    // MARK: - Throughput

    /// Not a functional test — a fixed-workload benchmark for the stop→inject budget: a
    /// 150-term vocabulary (plus alternatives) against a 120-word transcript, the size of a
    /// paragraph dictated in one breath. Prints ms per correction pass; the assertion is a
    /// generous ceiling so a pathological regression fails loudly instead of silently eating
    /// the latency budget.
    func testCorrectorThroughputOnALargeVocabulary() {
        var terms: [VocabularyTerm] = []
        for i in 0..<150 {
            terms.append(VocabularyTerm(
                text: "Zylophar\(i)ne",
                alternatives: ["zylo far \(i)", "silophar\(i)ne"]
            ))
        }
        let corrector = VocabularyCorrector(terms: terms)
        let words = (0..<120).map { "parola\($0 % 37)" }
        let transcript = words.joined(separator: " ") + ", con Zylophar3ne e silophar7ne."

        // Warm-up pass, then the timed passes.
        _ = corrector.correct(transcript)
        let clock = ContinuousClock()
        let iterations = 20
        let elapsed = clock.measure {
            for _ in 0..<iterations { _ = corrector.correct(transcript) }
        }
        let msPerPass = (Double(elapsed.components.seconds) * 1_000
            + Double(elapsed.components.attoseconds) / 1e15) / Double(iterations)
        print(String(format: "corrector: %.3f ms per 120-word pass at 150 terms", msPerPass))
        XCTAssertLessThan(msPerPass, 50, "corrector pass has regressed catastrophically")

        // The workload must actually exercise the matcher, or the number measures nothing.
        XCTAssertTrue(corrector.correct(transcript).contains("Zylophar7ne"))
    }

    /// A vocabulary file written by an older build must still decode; a `keyNotFound` here
    /// would silently wipe every word the user added.
    func testDecodesATermFileMissingNewerKeys() throws {
        let json = Data(#"[{"text":"Martino"}]"#.utf8)
        let terms = try JSONDecoder().decode([VocabularyTerm].self, from: json)
        XCTAssertEqual(terms.count, 1)
        XCTAssertEqual(terms[0].text, "Martino")
        XCTAssertTrue(terms[0].enabled)
        XCTAssertTrue(terms[0].alternatives.isEmpty)
    }
}
