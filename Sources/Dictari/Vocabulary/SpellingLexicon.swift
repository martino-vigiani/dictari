// SpellingLexicon.swift
// Dictari — "is this an ordinary word?", answered by the Mac's own spelling dictionaries.
//
// The history scan finds phrases that *sound* like a vocabulary term. Some of those are simply
// everyday words that happen to sound close — "mattina" next to Martino, "dettare" next to
// Dictari — and a sound model alone cannot tell them from a real mishearing. The system
// spelling dictionaries can, on device and for the languages the user already has installed.
//
// Main actor only: NSSpellChecker makes no thread-safety promise, and the scan itself stays
// pure and off the main actor. The UI runs this over the few dozen candidates the scan
// returns (`VocabularySuggestions.filtered`), which costs milliseconds.

import AppKit

@MainActor
final class SpellingLexicon {

    /// The languages Dictari dictates in. Only those the system has a dictionary for are used.
    private static let preferredLanguages = ["it", "en", "de"]

    private let checker: NSSpellChecker
    private let languages: [String]
    private var cache: [String: Bool] = [:]

    init(checker: NSSpellChecker = .shared) {
        self.checker = checker
        let available = checker.availableLanguages
        // "en" may be installed as "en_US"/"en_GB": take the first dictionary per language.
        languages = Self.preferredLanguages.compactMap { language in
            available.first { $0 == language || $0.hasPrefix(language + "_") }
        }
    }

    /// True when no dictionary is available at all: then nothing can be judged and
    /// `isKnownWord` answers false, so no suggestion is dropped.
    var isEmpty: Bool { languages.isEmpty }

    /// Whether `word` (a folded, lowercase word) is spelled correctly in any of the languages.
    func isKnownWord(_ word: String) -> Bool {
        if let cached = cache[word] { return cached }
        let known = languages.contains { language in
            checker.checkSpelling(of: word, startingAt: 0, language: language, wrap: false,
                                  inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
        }
        cache[word] = known
        return known
    }
}
