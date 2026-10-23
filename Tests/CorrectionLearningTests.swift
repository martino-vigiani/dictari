// CorrectionLearningTests.swift
// Dictari — learning vocabulary from a hand correction in History.
//
// As with VocabularyTests, the "nothing is proposed" cases matter as much as the positive one:
// a learned mapping rewrites every future dictation, so grammar fixes, punctuation tidying and
// common words must never become rules.

import XCTest

final class CorrectionDiffTests: XCTestCase {

    private func pairs(_ original: String, _ edited: String) -> [String] {
        CorrectionDiff.substitutions(original: original, edited: edited).map { "\($0.heard) → \($0.written)" }
    }

    // MARK: - The case the feature exists for

    /// Documented choice: adjacent changed words form ONE multiword substitution. The phrase
    /// alternative only fires on the full misheard name, never on a lone "Martina".
    func testAdjacentMisheardWordsBecomeOneTwoWordSubstitution() {
        XCTAssertEqual(pairs("ho parlato con Martina Viggiani", "ho parlato con Martino Vigiani"),
                       ["Martina Viggiani → Martino Vigiani"])
    }

    func testSeparatedMisheardWordsBecomeSeparateSubstitutions() {
        XCTAssertEqual(
            pairs("Martina ha aperto il ticket su dictari ieri sera.",
                  "Martino ha aperto il ticket su Dictari ieri sera."),
            ["Martina → Martino"]   // "dictari" → "Dictari" is case-only: no proposal
        )
        XCTAssertEqual(
            pairs("domani chiamo Martina e poi apro cubo cuddle", "domani chiamo Martino e poi apro kubectl"),
            ["Martina → Martino", "cubo cuddle → kubectl"]
        )
    }

    func testOuterPunctuationIsTrimmedAndCapitalisationOfTheEditIsKept() {
        XCTAssertEqual(pairs("Ciao, sono Martina.", "Ciao, sono Martino."), ["Martina → Martino"])
        XCTAssertEqual(pairs("usa «whisper kit», va bene", "usa «WhisperKit», va bene"),
                       ["whisper kit → WhisperKit"])
    }

    func testGermanAndEnglishNames() {
        XCTAssertEqual(pairs("Ich treffe heute Frau Schmitt in München", "Ich treffe heute Frau Schmidt in München"),
                       ["Schmitt → Schmidt"])
        XCTAssertEqual(pairs("then deploy it with cube control today", "then deploy it with kubectl today"),
                       ["cube control → kubectl"])
    }

    // MARK: - Nothing to learn

    func testPunctuationCaseAndAccentOnlyEditsProposeNothing() {
        XCTAssertTrue(pairs("ciao come stai", "Ciao, come stai?").isEmpty)
        XCTAssertTrue(pairs("perche no", "perché no!").isEmpty)
        XCTAssertTrue(pairs("allora — vediamo", "Allora... vediamo.").isEmpty)
        XCTAssertTrue(pairs("same text", "same text").isEmpty)
    }

    func testPureInsertionsAndDeletionsProposeNothing() {
        XCTAssertTrue(pairs("ho parlato con Martino", "ho parlato ieri con Martino Vigiani").isEmpty)
        XCTAssertTrue(pairs("ho parlato ieri con Martino", "ho parlato con Martino").isEmpty)
    }

    func testCommonWordsAreNeverMapped() {
        XCTAssertTrue(pairs("lui a detto di sì", "lui ha detto di sì").isEmpty)       // grammar fix
        XCTAssertTrue(pairs("it is the best", "it is a best").isEmpty)
        XCTAssertTrue(pairs("ich habe das gesehen", "ich habe die gesehen").isEmpty)
        XCTAssertTrue(pairs("vado con Martina", "vado da Martina").isEmpty)
        // Common on one side is enough to refuse.
        XCTAssertTrue(pairs("parlo con Dictari", "parlo con the").isEmpty)
        XCTAssertTrue(pairs("parlo con Dictari", "parlo con di").isEmpty)
        XCTAssertTrue(CorrectionDiff.isCommon("di la"))
        XCTAssertFalse(CorrectionDiff.isCommon("con Martina"))
    }

    func testLongRewritesAndNumbersProposeNothing() {
        XCTAssertTrue(pairs("uno due tre quattro cinque sei sette",
                            "alfa beta gamma delta epsilon zeta eta").isEmpty)
        XCTAssertTrue(pairs("ne voglio 3 ancora", "ne voglio tre ancora").isEmpty)
        XCTAssertTrue(pairs("", "Martino").isEmpty)
        XCTAssertTrue(pairs("Martina", "").isEmpty)
    }

    func testDuplicateSubstitutionsAreReportedOnce() {
        XCTAssertEqual(pairs("Martina dice Martina", "Martino dice Martino"), ["Martina → Martino"])
    }
}

// MARK: - History entry

final class HistoryCorrectionTests: XCTestCase {

    func testOldHistoryJSONWithoutCorrectedTextDecodes() throws {
        let json = """
        [{"id":"7B0E6A2C-3C51-4F37-9C57-2B1E0C8A1D11","date":0,"text":"ho parlato con Martina",
          "durationSeconds":2.5,"wordCount":4,"latencyMs":120,"appName":"Mail","language":"it"}]
        """
        let entries = try JSONDecoder().decode([HistoryEntry].self, from: Data(json.utf8))
        XCTAssertEqual(entries.count, 1)
        XCTAssertNil(entries[0].correctedText)
        XCTAssertEqual(entries[0].displayText, "ho parlato con Martina")
    }

    func testCorrectedTextRoundTripsAndDrivesDisplayText() throws {
        var entry = HistoryEntry(date: Date(timeIntervalSince1970: 0), text: "Martina", durationSeconds: 1,
                                 wordCount: 1, latencyMs: 0)
        entry.correctedText = "Martino"
        let decoded = try JSONDecoder().decode(HistoryEntry.self, from: JSONEncoder().encode(entry))
        XCTAssertEqual(decoded.correctedText, "Martino")
        XCTAssertEqual(decoded.text, "Martina")
        XCTAssertEqual(decoded.displayText, "Martino")
        entry.correctedText = "  "
        XCTAssertEqual(entry.displayText, "Martina")
    }

    @MainActor func testStoreKeepsOriginalAndSearchFindsTheCorrection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.json")
        let store = HistoryStore(fileURL: url, saveDebounce: .zero)
        let entry = HistoryEntry(date: Date(), text: "ho parlato con Martina", durationSeconds: 1,
                                 wordCount: 4, latencyMs: 0)
        store.add(entry)

        store.setCorrectedText("ho parlato con Martino", for: entry.id)
        XCTAssertEqual(store.entries[0].text, "ho parlato con Martina")
        XCTAssertEqual(store.entries[0].displayText, "ho parlato con Martino")
        XCTAssertEqual(HistorySearch.matches(in: store.entries, query: "Martino").count, 1)
        XCTAssertEqual(HistorySearch.matches(in: store.entries, query: "Martina").count, 1)

        try await store.flushPendingWrites()
        let persisted = try JSONDecoder().decode([HistoryEntry].self, from: Data(contentsOf: url))
        XCTAssertEqual(persisted.first?.correctedText, "ho parlato con Martino")

        // Saving the original text back is no correction at all.
        store.setCorrectedText(" ho parlato con Martina ", for: entry.id)
        XCTAssertNil(store.entries[0].correctedText)
        store.setCorrectedText("ho parlato con Martino", for: entry.id)
        store.setCorrectedText(nil, for: entry.id)
        XCTAssertNil(store.entries[0].correctedText)
        try await store.flushPendingWrites()
    }
}

// MARK: - Vocabulary integration

@MainActor
final class CorrectionVocabularyLearningTests: XCTestCase {

    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var url: URL { directory.appendingPathComponent("vocabulary.json") }

    func testConfirmedCorrectionCreatesATermThatFixesTheNextDictationAndPersists() async throws {
        let store = VocabularyStore(url: url)
        let proposals = CorrectionDiff.substitutions(original: "ho parlato con Martina Viggiani",
                                                     edited: "ho parlato con Martino Vigiani")
        let proposal = try XCTUnwrap(proposals.first)
        XCTAssertEqual(store.learningOutcome(heard: proposal.heard, written: proposal.written), .addedTerm)
        XCTAssertTrue(store.terms.isEmpty, "Checking an outcome must not change the vocabulary")

        XCTAssertEqual(store.learn(heard: proposal.heard, written: proposal.written), .addedTerm)
        XCTAssertEqual(store.terms.map(\.text), ["Martino Vigiani"])
        XCTAssertEqual(store.terms[0].alternatives, ["Martina Viggiani"])
        XCTAssertEqual(store.corrector.correct("domani vedo Martina Viggiani."), "domani vedo Martino Vigiani.")

        try await store.flushPendingSaves()
        let reloaded = VocabularyStore(url: url)
        XCTAssertEqual(reloaded.terms.first?.alternatives, ["Martina Viggiani"])

        // Learning the same mapping again is a no-op.
        XCTAssertEqual(reloaded.learningOutcome(heard: "martina viggiani", written: "Martino Vigiani"), .alreadyKnown)
        XCTAssertEqual(reloaded.learn(heard: "Martina Viggiani", written: "martino vigiani"), .alreadyKnown)
        XCTAssertEqual(reloaded.terms.count, 1)
        XCTAssertEqual(reloaded.terms[0].alternatives.count, 1)
    }

    func testCorrectionAddsHeardAsToAnExistingTermAndReenablesIt() {
        let store = VocabularyStore(url: url)
        store.add(VocabularyTerm(text: "kubectl", enabled: false, alternatives: ["cube cuddle"]))
        XCTAssertEqual(store.learn(heard: "cubo cuddle", written: "Kubectl"), .addedAlternative)
        XCTAssertEqual(store.terms.count, 1)
        XCTAssertEqual(store.terms[0].text, "kubectl", "The existing spelling wins")
        XCTAssertEqual(store.terms[0].alternatives, ["cube cuddle", "cubo cuddle"])
        XCTAssertTrue(store.terms[0].enabled)
        XCTAssertEqual(store.corrector.correct("run cubo cuddle now"), "run kubectl now")
    }

    func testRefusesCommonWordsIdenticalWordsAndConflicts() {
        let store = VocabularyStore(url: url)
        store.add(VocabularyTerm(text: "Martino", alternatives: ["Martina"]))
        store.add(VocabularyTerm(text: "Marina"))
        let before = store.terms

        func isRejected(_ outcome: VocabularyStore.LearnOutcome) -> Bool {
            if case .rejected = outcome { return true }
            return false
        }
        XCTAssertTrue(isRejected(store.learn(heard: "a", written: "ha")))
        XCTAssertTrue(isRejected(store.learn(heard: "the", written: "Dictari")))
        XCTAssertTrue(isRejected(store.learn(heard: "Dictari", written: "und")))
        XCTAssertTrue(isRejected(store.learn(heard: "Dictari", written: "dictàri")))
        // "Martina" already belongs to Martino: it cannot also mean Martinez.
        XCTAssertTrue(isRejected(store.learn(heard: "Martina", written: "Martinez")))
        // A spelling the user wrote down as a term is never rewritten into another one.
        XCTAssertTrue(isRejected(store.learn(heard: "Marina", written: "Martino")))
        // "Martina" is rewritten to Martino, so it cannot become a canonical spelling.
        XCTAssertTrue(isRejected(store.learn(heard: "Martine", written: "Martina")))
        XCTAssertEqual(store.terms, before)
    }
}
