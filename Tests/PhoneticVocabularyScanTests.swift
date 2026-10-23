import XCTest

/// The history scan against real mishearings from Dictari history, and ordinary sentences that
/// must not produce suggestions. Prints precision and recall so a tuning change shows its
/// cost on both sides, not just on the case it was made for.
final class PhoneticVocabularyScanTests: XCTestCase {

    private static let terms: [VocabularyTerm] = [
        "Sense Calibrator", "Claude Code", "Codex", "Dictari", "Deepseek", "Subagent", "DualSense", "Martino",
    ].map { VocabularyTerm(text: $0) }

    /// (term, heard, sentence as it was saved). Every "heard" spelling is a real one.
    private static let mishearings: [(term: String, heard: String, text: String)] = [
        ("Sense Calibrator", "Science Calibrator", "Ho aperto Science Calibrator per sistemare il microfono."),
        ("Sense Calibrator", "Asense calibrator", "Poi Asense calibrator ha salvato il profilo."),
        ("Claude Code", "clode code", "Oggi uso clode code per il refactoring."),
        ("Claude Code", "Clude Code", "Chiedi a Clude Code di scrivere i test."),
        ("Claude Code", "cloth code", "Ho lanciato cloth code sul progetto."),
        ("Claude Code", "Cloud Code", "Cloud Code ha finito il lavoro."),
        ("Codex", "Codeks", "Apri Codeks e fai una review."),
        ("Dictari", "dictare", "Sto provando dictare con il nuovo modello."),
        ("Dictari", "dettari", "Il bug di dettari è sistemato."),
        ("Dictari", "di Tari", "Apri le impostazioni di Tari e controlla il vocabolario."),
        ("Deepseek", "DeepSick", "Ho confrontato DeepSick con gli altri modelli."),
        ("Deepseek", "Dipsick", "Dipsick risponde in fretta."),
        ("Deepseek", "dipsi", "Chiedi a dipsi una seconda opinione."),
        ("Subagent", "sabagent", "Ogni sabagent lavora in parallelo."),
        ("Subagent", "SubAgence", "Le SubAgence finiscono prima."),
        ("Subagent", "savagene", "Lancia un savagene per la ricerca."),
        ("Subagent", "sub agent", "Crea un sub agent dedicato."),
        ("DualSense", "dual sens", "Il controller dual sens vibra troppo."),
        ("Martino", "Martina", "Scrivi a Martina che arrivo."),
    ]

    /// Correct spellings: never suggested, and they own their words ("Code" is not Codex's).
    private static let correct = [
        "Claude Code e Codex lavorano insieme su Dictari.",
        "Deepseek e il Subagent girano sul DualSense di Martino con Sense Calibrator.",
    ]

    /// Ordinary Italian, English and German sentences. None of them is a mishearing, several
    /// are deliberate traps: they share letters or most of the sound with a term.
    private static let negatives = [
        "Domani mattina devo chiamare il dentista alle nove.",
        "Il mattino ha l'oro in bocca.",
        "Martedì vado a trovare Marta al mare.",
        "Il martello è nel garage.",
        "Il codice della strada è cambiato di nuovo.",
        "Ho comprato un nuovo codice sconto.",
        "Ho letto un articolo sulla scienza dei materiali.",
        "Il senso della calibrazione non è chiaro.",
        "Dicevamo che il progetto è quasi finito.",
        "Ho dettato tutto in un minuto.",
        "Devo dettare una lettera al notaio.",
        "Sabato andiamo al cinema con gli amici.",
        "La cloud di Apple sincronizza le foto.",
        "Il deep learning cambia tutto.",
        "Deep sea fishing is fun.",
        "La console DualShock funziona ancora.",
        "Could you send me the code before lunch?",
        "The code review is done.",
        "Claudia mi ha scritto ieri sera.",
        "Der Code ist fertig und die Tasse steht auf dem Tisch.",
        "Wir sehen uns morgen früh im Büro.",
        "Il sub è andato in immersione con l'agente.",
    ]

    /// Words of the fixture corpus that a spelling dictionary (it/en/de) knows. A fixed
    /// stand-in for `SpellingLexicon`, so the numbers do not depend on installed dictionaries.
    private static let fixedLexicon: Set<String> = [
        "mattina", "mattino", "martedi", "marta", "martello", "codice", "scienza", "senso",
        "calibrazione", "dettato", "dettare", "sabato", "cloud", "deep", "sea", "learning", "code",
        "console", "science", "calibrator", "cloth", "dual", "sub", "agent", "agente", "martina",
        "claudia", "tasse", "dicevamo",
    ]

    private func entry(_ text: String, _ offset: Double) -> HistoryEntry {
        HistoryEntry(date: Date(timeIntervalSince1970: 1_000 + offset), text: text,
                     durationSeconds: 1, wordCount: 4, latencyMs: 10)
    }

    private var history: [HistoryEntry] {
        let texts = Self.mishearings.map(\.text) + Self.correct + Self.negatives
        return texts.enumerated().map { entry($0.element, Double($0.offset)) }
    }

    private struct Pair: Hashable, CustomStringConvertible {
        let term: String
        let heard: String
        var description: String { "\(heard) → \(term)" }
    }

    private func found(lexicon: ((String) -> Bool)?) throws -> Set<Pair> {
        let results = try VocabularySuggestions.scan(terms: Self.terms, in: history, knownTerms: Self.terms,
                                                     limit: VocabularySuggestions.candidatePool)
        var pairs: Set<Pair> = []
        for result in results {
            let suggestions = lexicon.map {
                VocabularySuggestions.filtered(result.suggestions, limit: 12, isKnownWord: $0)
            } ?? Array(result.suggestions.prefix(12))
            for suggestion in suggestions {
                pairs.insert(Pair(term: result.term.text, heard: VocabularySuggestions.key(suggestion.phrase)))
                if lexicon == nil {
                    print(String(format: "[phonetic-scan]   %@ ← %@: sound %.3f, letters %d, score %.3f, %@",
                                 result.term.text, suggestion.phrase, suggestion.soundDistance,
                                 suggestion.distance, suggestion.score, "\(suggestion.match)"))
                }
            }
        }
        return pairs
    }

    private var expected: Set<Pair> {
        Set(Self.mishearings.map { Pair(term: $0.term, heard: VocabularySuggestions.key($0.heard)) })
    }

    private func report(_ label: String, _ found: Set<Pair>) -> (precision: Double, recall: Double) {
        let truePositives = found.intersection(expected)
        let precision = found.isEmpty ? 1 : Double(truePositives.count) / Double(found.count)
        let recall = Double(truePositives.count) / Double(expected.count)
        let falsePositives = found.subtracting(expected).map(\.description).sorted()
        let missed = expected.subtracting(found).map(\.description).sorted()
        print(String(format: "[phonetic-scan] %@: precision %.2f (%d/%d), recall %.2f (%d/%d)",
                     label, precision, truePositives.count, found.count, recall, truePositives.count, expected.count))
        print("[phonetic-scan] \(label) false positives: \(falsePositives)")
        print("[phonetic-scan] \(label) missed: \(missed)")
        return (precision, recall)
    }

    // MARK: - Fixture metrics

    func testFindsEveryRealMishearingByTheSoundAlone() throws {
        let metrics = report("sound only", try found(lexicon: nil))
        XCTAssertEqual(metrics.recall, 1, "every real mishearing must be proposed")
        XCTAssertGreaterThanOrEqual(metrics.precision, 0.8)
    }

    func testDictionaryPassRemovesOrdinaryWordsWithoutLosingMishearings() throws {
        let metrics = report("sound + fixed lexicon", try found(lexicon: { Self.fixedLexicon.contains($0) }))
        XCTAssertEqual(metrics.recall, 1)
        XCTAssertEqual(metrics.precision, 1)
    }

    /// Same pass with the Mac's real dictionaries. Informational: the numbers depend on which
    /// dictionaries are installed, so only a total loss of recall fails the test.
    @MainActor func testSystemDictionaryPass() throws {
        let lexicon = SpellingLexicon()
        guard !lexicon.isEmpty else { throw XCTSkip("No it/en/de spelling dictionary available") }
        let metrics = report("sound + system lexicon", try found(lexicon: { lexicon.isKnownWord($0) }))
        XCTAssertGreaterThan(metrics.recall, 0.8)
    }

    func testOrdinarySentencesAloneProduceNoSuggestionsAfterTheDictionaryPass() throws {
        let history = Self.negatives.enumerated().map { entry($0.element, Double($0.offset)) }
        let results = try VocabularySuggestions.scan(terms: Self.terms, in: history, knownTerms: Self.terms,
                                                     limit: VocabularySuggestions.candidatePool)
        for result in results {
            let kept = VocabularySuggestions.filtered(result.suggestions, limit: 12) { Self.fixedLexicon.contains($0) }
            XCTAssertTrue(kept.isEmpty, "\(result.term.text): \(kept.map(\.phrase))")
        }
    }

    // MARK: - Rules

    func testDifferentFirstLetterIsFoundWhenTheSoundIsNearlyIdentical() throws {
        let term = VocabularyTerm(text: "Sense Calibrator")
        let results = try VocabularySuggestions.find(for: term,
            in: [entry("Poi Asense calibrator ha salvato il profilo.", 0)], knownTerms: [term])
        let match = try XCTUnwrap(results.first)
        XCTAssertEqual(match.phrase, "Asense calibrator")
        XCTAssertEqual(match.match, .sound)
    }

    func testTypoLevelMatchesKeepTheSpellingLabel() throws {
        let term = VocabularyTerm(text: "Martino")
        let results = try VocabularySuggestions.find(for: term, in: [entry("Scrivi a Martina.", 0)], knownTerms: [])
        XCTAssertEqual(results.first?.match, .spelling)
    }

    func testCloudAloneIsNotClaudeCode() throws {
        let term = VocabularyTerm(text: "Claude Code")
        let results = try VocabularySuggestions.find(for: term,
            in: [entry("La cloud di Apple. Il cloud è pieno. Cloud!", 0)], knownTerms: [term])
        XCTAssertTrue(results.isEmpty, "\(results.map(\.phrase))")
    }

    func testTheCodeIsNotClaudeCode() throws {
        let term = VocabularyTerm(text: "Claude Code")
        let results = try VocabularySuggestions.find(for: term,
            in: [entry("The code review is done. Send the code.", 0)], knownTerms: [term])
        XCTAssertTrue(results.isEmpty, "\(results.map(\.phrase))")
    }

    /// "Code" inside a phrase that belongs to Claude Code — spelled right or misheard — is not
    /// a suggestion for Codex; alone it would be too far from Codex anyway.
    func testWordsAreAttributedToTheClosestTermOnly() throws {
        let codex = VocabularyTerm(text: "Codex")
        let claude = VocabularyTerm(text: "Claude Code")
        let history = [entry("Claude Code e Cloud Code. Poi Codeks.", 0)]
        let forCodex = try VocabularySuggestions.find(for: codex, in: history, knownTerms: [codex, claude])
        XCTAssertEqual(forCodex.map(\.phrase), ["Codeks"])
        let all = try VocabularySuggestions.scan(terms: [codex, claude], in: history, knownTerms: [codex, claude])
        XCTAssertEqual(all.map { $0.suggestions.map(\.phrase) }, [["Codeks"], ["Cloud Code"]])
    }

    func testShortWordIsKeptOnlyWhenTheSoundNeedsIt() throws {
        let term = VocabularyTerm(text: "Dictari")
        let split = try VocabularySuggestions.find(for: term,
            in: [entry("Apri le impostazioni. Di Tari controlla il vocabolario.", 0)], knownTerms: [term])
        XCTAssertEqual(split.map(\.phrase), ["Di Tari"])
        let article = try VocabularySuggestions.find(for: term,
            in: [entry("Uso il dettari e la dettari.", 0)], knownTerms: [term])
        XCTAssertEqual(article.map(\.phrase), ["dettari"], "the article is context, not part of the name")
        XCTAssertEqual(article.first?.occurrences, 2)
    }

    func testCommonWordsAloneAreNeverCandidates() throws {
        let term = VocabularyTerm(text: "Dove")
        let results = try VocabularySuggestions.find(for: term, in: [entry("Dove sei? dove vai", 0)], knownTerms: [])
        XCTAssertTrue(results.isEmpty)
    }

    func testRanksCloserSoundsFirst() throws {
        let term = VocabularyTerm(text: "Deepseek")
        let history = [entry("Dipsick. Dipsick. dipsi. DeepSick.", 0)]
        let results = try VocabularySuggestions.find(for: term, in: history, knownTerms: [term])
        XCTAssertEqual(results.map(\.phrase), ["DeepSick", "Dipsick", "dipsi"])
        XCTAssertEqual(results.map(\.occurrences), [1, 2, 1])
    }

    func testFilteredKeepsStrongMatchesEvenWhenTheyAreDictionaryWords() {
        let strong = VocabularySuggestion(id: "cloud code", phrase: "Cloud Code", context: "", date: .distantPast,
                                          occurrences: 1, distance: 2, soundDistance: 0.05, score: 0.07)
        let moderate = VocabularySuggestion(id: "mattina", phrase: "mattina", context: "", date: .distantPast,
                                            occurrences: 5, distance: 2, soundDistance: 0.2, score: 0.2)
        let unknown = VocabularySuggestion(id: "dettari", phrase: "dettari", context: "", date: .distantPast,
                                           occurrences: 1, distance: 2, soundDistance: 0.2, score: 0.2)
        let split = VocabularySuggestion(id: "di tari", phrase: "di Tari", context: "", date: .distantPast,
                                         occurrences: 1, distance: 1, soundDistance: 0.15, score: 0.15)
        let known: Set<String> = ["cloud", "code", "mattina", "tari"]
        let kept = VocabularySuggestions.filtered([strong, moderate, unknown, split], limit: 12) { known.contains($0) }
        XCTAssertEqual(kept.map(\.id), ["cloud code", "dettari", "di tari"],
                       "a split spelling is judged joined: \"ditari\" is not a word even though \"tari\" is")
        XCTAssertEqual(VocabularySuggestions.filtered([strong, moderate, unknown], limit: 1) { known.contains($0) }.map(\.id),
                       ["cloud code"])
    }

    @MainActor func testScanNeverChangesVocabularyOrHistory() throws {
        let store = VocabularyStore(terms: Self.terms)
        let saved = history
        let results = try VocabularySuggestions.scan(terms: store.terms, in: saved, knownTerms: store.terms)
        XCTAssertFalse(results.allSatisfy { $0.suggestions.isEmpty })
        // Proposals only: nothing is learned, and dictated text is still left as it was.
        XCTAssertEqual(store.terms, Self.terms)
        XCTAssertEqual(store.corrector.correct("Uso Dipsick e cloth code."), "Uso Dipsick e cloth code.")
    }

    @MainActor func testApprovingASuggestionLearnsItAsHeardAs() throws {
        let store = VocabularyStore(terms: [VocabularyTerm(text: "Deepseek")])
        let results = try VocabularySuggestions.scan(terms: store.terms,
            in: [entry("Dipsick risponde in fretta.", 0)], knownTerms: store.terms)
        let suggestion = try XCTUnwrap(results.first?.suggestions.first)
        XCTAssertEqual(store.learn(heard: suggestion.phrase, written: results[0].term.text), .addedAlternative)
        XCTAssertEqual(store.terms[0].alternatives, ["Dipsick"])
        XCTAssertEqual(store.corrector.correct("Chiedi a Dipsick."), "Chiedi a Deepseek.")
        // Once learned it is handled, so a new scan no longer proposes it.
        let again = try VocabularySuggestions.scan(terms: store.terms,
            in: [entry("Dipsick risponde in fretta.", 0)], knownTerms: store.terms)
        XCTAssertTrue(again[0].suggestions.isEmpty)
    }

    func testScanOfManyTermsIsCancellable() async {
        let terms = Self.terms
        let history = (0..<500).map { entry(String(repeating: "Cloud Code e Dipsick ", count: 60), Double($0)) }
        let task = Task.detached {
            try VocabularySuggestions.scan(terms: terms, in: history, knownTerms: terms)
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled scan completed")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    /// Informational timing of a realistic full scan (500 entries, eight terms).
    func testFullScanTiming() throws {
        let texts = Self.mishearings.map(\.text) + Self.correct + Self.negatives
        let history = (0..<VocabularySuggestions.historyLimit).map {
            entry(Array(repeating: texts[$0 % texts.count], count: 4).joined(separator: " "), Double($0))
        }
        let start = Date()
        _ = try VocabularySuggestions.scan(terms: Self.terms, in: history, knownTerms: Self.terms)
        print(String(format: "[phonetic-scan] full scan of %d entries × %d terms: %.0f ms",
                     history.count, Self.terms.count, Date().timeIntervalSince(start) * 1000))
    }
}
