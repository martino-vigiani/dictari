import XCTest

final class VocabularySuggestionsTests: XCTestCase {
    private let claude = VocabularyTerm(text: "Claude Code")

    private func entry(_ text: String, date: Date = Date(timeIntervalSince1970: 100), tag: String? = nil) -> HistoryEntry {
        HistoryEntry(date: date, text: text, durationSeconds: 1, wordCount: 4, latencyMs: 10, tag: tag)
    }

    func testReturnsOnlyObservedSpellingWithFrequencyAndOriginalContext() throws {
        let text = "🙂 Oggi uso Cloud Code, poi Cloud Code per il progetto."
        let history = [entry(text), entry("Yesterday: CLOUD CODE worked.", date: Date(timeIntervalSince1970: 10))]
        let results = try VocabularySuggestions.find(for: claude, in: history, knownTerms: [])
        let found = try XCTUnwrap(results.first { $0.id == "cloud code" })
        XCTAssertEqual(found.phrase, "Cloud Code")
        XCTAssertEqual(found.occurrences, 3)
        XCTAssertTrue(found.context.contains(text))
        XCTAssertEqual(found.date, history[0].date)
        XCTAssertTrue(results.allSatisfy { suggestion in history.contains { $0.text.contains(suggestion.phrase) } })
    }

    func testNeverSuggestsCanonicalSpellingOrItsSurroundingWords() throws {
        let results = try VocabularySuggestions.find(for: claude,
            in: [entry("Claude Code today. Claude Code a. CLAUDE-CODE.")], knownTerms: [])
        XCTAssertTrue(results.isEmpty)
    }

    func testExcludesAlreadyConfiguredAlternativesAndOtherTermsEvenWhenDisabled() throws {
        var term = claude
        term.alternatives = ["CLOUD CODE"]
        let other = VocabularyTerm(text: "Cloude Code", enabled: false, alternatives: ["Claud Code"])
        let results = try VocabularySuggestions.find(for: term,
            in: [entry("Cloud Code. Cloude Code. Claud Code.")], knownTerms: [term, other])
        XCTAssertTrue(results.isEmpty)
    }

    func testIgnoresFailuresEmptyEntriesAndUnrelatedPhrases() throws {
        let results = try VocabularySuggestions.find(for: claude,
            in: [entry("Cloud Code", tag: "failed"), entry("", tag: "no speech"), entry("The weather is sunny.")], knownTerms: [])
        XCTAssertTrue(results.isEmpty)
    }

    func testDoesNotJoinAcrossSentencesNewlinesOrUnsupportedSpacing() throws {
        for text in ["Cloud. Code", "Cloud\nCode", "Cloud, Code", "Cloud  Code"] {
            let result = try VocabularySuggestions.find(for: claude, in: [entry(text)], knownTerms: [])
            XCTAssertFalse(result.contains { $0.id == "cloud code" }, text)
        }
    }

    func testDoesNotAttachSmallContextWordsToSingleWordName() throws {
        let results = try VocabularySuggestions.find(for: VocabularyTerm(text: "Codexx"),
            in: [entry("Codex i. Codex e. Codex.")], knownTerms: [])
        XCTAssertEqual(results.map(\.id), ["codex"])
        XCTAssertEqual(results.first?.occurrences, 3)
    }

    func testFindsJoinedAndHyphenatedObservedSpellings() throws {
        let results = try VocabularySuggestions.find(for: claude,
            in: [entry("Cloud-Code and ClaudeCode")], knownTerms: [])
        XCTAssertTrue(results.contains { $0.phrase == "Cloud-Code" })
        XCTAssertTrue(results.contains { $0.phrase == "ClaudeCode" })
    }

    func testDeduplicatesHistoryIDsAndCountsMultipleOccurrencesWithinOneEntry() throws {
        let repeated = entry("Cloud Code and Cloud Code")
        let results = try VocabularySuggestions.find(for: claude, in: [repeated, repeated], knownTerms: [])
        XCTAssertEqual(results.first { $0.id == "cloud code" }?.occurrences, 2)
    }

    func testSortsBySimilarityThenFrequencyAndHonorsLimit() throws {
        let history = [entry("Claud Code. Cloud Code. Cloud Code.")]
        let result = try VocabularySuggestions.find(for: claude, in: history, knownTerms: [], limit: 1)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.phrase, "Claud Code")
        XCTAssertTrue(try VocabularySuggestions.find(for: claude, in: history, knownTerms: [], limit: 0).isEmpty)
    }

    func testOnlySearchesTheMostRecentSuccessfulEntriesRegardlessOfInputOrder() throws {
        let history = [entry("Cloud Code", date: .distantPast)] + (0..<VocabularySuggestions.historyLimit).map {
            entry("No matching words here.", date: Date(timeIntervalSince1970: Double($0)))
        }
        XCTAssertTrue(try VocabularySuggestions.find(for: claude, in: history, knownTerms: []).isEmpty)
    }

    func testEmptyShortAndVeryLongTermsDoNotProduceGuesses() throws {
        for name in ["", "AI", String(repeating: "a", count: 81)] {
            XCTAssertTrue(try VocabularySuggestions.find(for: VocabularyTerm(text: name),
                in: [entry("Cloud Code")], knownTerms: []).isEmpty)
        }
    }

    func testSelectionPreservesUnicodeOffsetsAndExpandsPartialWords() {
        let text = "🙂 Uso Clöud Code, oggi."
        let range = (text as NSString).range(of: "öud Co")
        XCTAssertEqual(VocabularySuggestions.selectedPhrase(in: text, range: range), "Clöud Code")
        XCTAssertEqual(VocabularySuggestions.selectedPhrase(in: text, range: NSRange(location: 0, length: 0)), "")
        XCTAssertEqual(VocabularySuggestions.selectedPhrase(in: text, range: (text as NSString).range(of: ",")), "")
        XCTAssertEqual(VocabularySuggestions.selectedPhrase(in: text, range: NSRange(location: 900, length: 2)), "")
        XCTAssertEqual(VocabularySuggestions.selectedPhrase(in: text, range: NSRange(location: NSNotFound, length: 1)), "")
    }

    func testManualVariantValidationRejectsDuplicatesConflictsAndUnmatchableSelections() {
        var term = claude
        term.alternatives = ["Cloud Code"]
        for phrase in ["", "CLAUDE CODE", "Clöud Code", "Cloud, Code", "Cloud\nCode", "Cloud  Code", "Cloud Code,", String(repeating: "a", count: 81)] {
            XCTAssertNotNil(VocabularySuggestions.validationMessage(for: phrase, term: term, knownTerms: []), phrase)
        }
        let other = VocabularyTerm(text: "Different", alternatives: ["Klaud Code"])
        XCTAssertNotNil(VocabularySuggestions.validationMessage(for: "Klaud Code", term: term, knownTerms: [other]))
        XCTAssertNil(VocabularySuggestions.validationMessage(for: "Claud Code", term: term, knownTerms: []))
    }

    @MainActor func testFindingSuggestionsDoesNotApplyThemAndConfirmedVariantPersists() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("vocabulary.json")
        try JSONEncoder().encode([claude]).write(to: url)
        let store = VocabularyStore(url: url)
        let original = "I use Cloud Code."
        let history = [entry(original)]
        let result = try VocabularySuggestions.find(for: claude, in: history, knownTerms: store.terms)
        XCTAssertTrue(store.terms[0].alternatives.isEmpty)
        XCTAssertEqual(store.corrector.correct(original), original)
        var confirmed = store.terms[0]
        confirmed.alternatives.append(try XCTUnwrap(result.first { $0.id == "cloud code" }).phrase)
        store.update(confirmed)
        XCTAssertEqual(store.corrector.correct(original), "I use Claude Code.")
        XCTAssertEqual(history[0].text, original)
        for _ in 0..<100 {
            let loaded = VocabularyStore(url: url)
            if loaded.terms.first?.alternatives == ["Cloud Code"] {
                XCTAssertEqual(loaded.corrector.correct(original), "I use Claude Code.")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Confirmed variant was not persisted")
    }

    func testCancelledSearchStopsWithoutReturningResults() async {
        let term = claude
        let history = (0..<500).map { _ in entry(String(repeating: "Cloud Code ", count: 100)) }
        let task = Task.detached {
            try VocabularySuggestions.find(for: term, in: history, knownTerms: [])
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled search completed")
        } catch { XCTAssertTrue(error is CancellationError) }
    }
}

/// A spelling dismissed in "Scan history" must not come back on the next scan.
final class DismissedSuggestionTests: XCTestCase {
    private func entry(_ text: String) -> HistoryEntry {
        HistoryEntry(date: Date(), text: text, durationSeconds: 1, wordCount: 4, latencyMs: 10, tag: nil)
    }

    func testDismissedSpellingIsNotProposedAgain() throws {
        let history = (0..<3).map { _ in entry("ho aperto Dictary e ho dettato una nota") }
        let term = VocabularyTerm(text: "Dictari")
        let before = try VocabularySuggestions.find(for: term, in: history, knownTerms: [term])
        XCTAssertTrue(before.contains { VocabularySuggestions.key($0.phrase) == "dictary" })

        let dismissedTerm = VocabularyTerm(id: term.id, text: "Dictari", dismissed: ["Dictary"])
        let after = try VocabularySuggestions.find(for: dismissedTerm, in: history, knownTerms: [dismissedTerm])
        XCTAssertFalse(after.contains { VocabularySuggestions.key($0.phrase) == "dictary" })
    }

    func testOldVocabularyWithoutDismissedDecodes() throws {
        let json = #"[{"id":"6F1B0B0E-8D1C-4E63-9D2B-0B1B0B0E8D1C","text":"Dictari","enabled":true,"alternatives":["dettari"]}]"#
        let terms = try JSONDecoder().decode([VocabularyTerm].self, from: Data(json.utf8))
        XCTAssertEqual(terms.first?.dismissed, [])
        XCTAssertEqual(terms.first?.alternatives, ["dettari"])
    }
}

/// "utilizza Claude che è ottimo" must never become "Claude Code è ottimo".
final class TermWordPlusCommonWordTests: XCTestCase {
    func testTermWordPlusCommonWordIsRejected() {
        let term = VocabularyTerm(text: "Claude Code")
        XCTAssertNotNil(VocabularySuggestions.validationMessage(for: "Claude che", term: term, knownTerms: [term]))
        XCTAssertNotNil(VocabularySuggestions.validationMessage(for: "Claude e", term: term, knownTerms: [term]))
    }

    func testRealMishearingsStillPass() {
        let term = VocabularyTerm(text: "Claude Code")
        XCTAssertNil(VocabularySuggestions.validationMessage(for: "Clude Code", term: term, knownTerms: [term]))
        XCTAssertNil(VocabularySuggestions.validationMessage(for: "cloth code", term: term, knownTerms: [term]))
    }
}
