// CorrectionDiff.swift
// Dictari — turn a user's hand correction of a transcript into vocabulary proposals.
//
// When the model mishears a name or a term, the user fixes the history entry once. This file
// compares the original transcript with the edited one word by word and proposes
// "heard as X → write Y" mappings. It never writes anything itself: the History sheet shows
// the proposals as a checklist and only the ones the user keeps reach `VocabularyStore`.
//
// Same stance as `VocabularyCorrector`: a wrong mapping rewrites correct words in every future
// dictation, so every rule here fails closed. Anything that looks like grammar editing,
// rewording or punctuation tidying produces no proposal.

import Foundation

/// One learnable replacement: the transcript said `heard`, the user wrote `written`.
struct Substitution: Hashable, Identifiable, Sendable {
    /// The misheard phrase, as it appeared in the original transcript (outer punctuation trimmed).
    let heard: String
    /// The user's spelling, as typed in the correction (outer punctuation trimmed). Becomes the
    /// canonical vocabulary spelling, so its capitalisation is preserved.
    let written: String

    var id: String { VocabularySuggestions.key(heard) + "→" + VocabularySuggestions.key(written) }
}

enum CorrectionDiff {

    /// Longest phrase on either side of a proposal. Longer edits are rewording, not mishearing.
    static let maximumPhraseWords = 4

    /// Bound on the LCS table after the common prefix/suffix are trimmed. A history entry is a
    /// dictation, not a book; a correction that rewrites this much is not a vocabulary fix.
    private static let maximumTableCells = 1_000_000

    /// Word-level diff of `original` against `edited`.
    ///
    /// Words are compared by `VocabularySuggestions.key` — case, accents and surrounding
    /// punctuation folded — which is exactly how the corrector matches, so a case-only,
    /// accent-only or punctuation-only change is no change at all and proposes nothing.
    ///
    /// A run of consecutive changed words is **one** substitution, not several: "Martina
    /// Viggiani" → "Martino Vigiani" yields a single two-word proposal. The multiword alternative
    /// is the safer rule — it only fires on the full misheard phrase, never on a lone "Martina"
    /// that might be a different person — and a user who wants the single-word mapping can add
    /// it in Vocabulary. Pure insertions and deletions are ignored (they are edits of content,
    /// not of hearing), as is any run longer than `maximumPhraseWords` on either side.
    static func substitutions(original: String, edited: String) -> [Substitution] {
        let a = tokens(original)
        let b = tokens(edited)
        guard !a.isEmpty, !b.isEmpty else { return [] }

        // Trim the shared prefix and suffix first: a typical correction touches one or two
        // words, and this keeps the quadratic table down to the edited region.
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix].key == b[prefix].key { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix,
              a[a.count - 1 - suffix].key == b[b.count - 1 - suffix].key { suffix += 1 }
        let midA = Array(a[prefix..<(a.count - suffix)])
        let midB = Array(b[prefix..<(b.count - suffix)])
        guard !midA.isEmpty, !midB.isEmpty else { return [] }
        guard (midA.count + 1) * (midB.count + 1) <= maximumTableCells else { return [] }

        var result: [Substitution] = []
        var seen: Set<String> = []
        for hunk in hunks(midA, midB) {
            guard let substitution = proposal(heard: hunk.0, written: hunk.1),
                  seen.insert(substitution.id).inserted else { continue }
            result.append(substitution)
        }
        return result
    }

    // MARK: - Tokens

    private struct Token {
        /// Whitespace-delimited text with outer punctuation removed ("Viggiani," → "Viggiani").
        let text: String
        /// Folded comparison key; may contain spaces for "l'app" → "l app".
        let key: String
    }

    private static func tokens(_ text: String) -> [Token] {
        text.split(whereSeparator: { $0.isWhitespace }).compactMap { raw in
            let trimmed = raw.drop(while: { !isWordCharacter($0) })
            guard let last = trimmed.lastIndex(where: isWordCharacter) else { return nil }
            let word = String(trimmed[...last])
            let key = VocabularySuggestions.key(word)
            return key.isEmpty ? nil : Token(text: word, key: key)
        }
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    // MARK: - Diff

    /// Maximal runs where both sides changed, from a classic LCS alignment.
    private static func hunks(_ a: [Token], _ b: [Token]) -> [([Token], [Token])] {
        let n = a.count, m = b.count
        // lengths[i][j] = LCS of a[i...] and b[j...]; flat storage, one allocation.
        var lengths = [Int](repeating: 0, count: (n + 1) * (m + 1))
        func at(_ i: Int, _ j: Int) -> Int { lengths[i * (m + 1) + j] }
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lengths[i * (m + 1) + j] = a[i].key == b[j].key
                    ? at(i + 1, j + 1) + 1
                    : max(at(i + 1, j), at(i, j + 1))
            }
        }

        var result: [([Token], [Token])] = []
        var pendingA: [Token] = [], pendingB: [Token] = []
        func flush() {
            if !pendingA.isEmpty || !pendingB.isEmpty { result.append((pendingA, pendingB)) }
            pendingA = []; pendingB = []
        }
        var i = 0, j = 0
        while i < n || j < m {
            if i < n, j < m, a[i].key == b[j].key {
                flush()
                i += 1; j += 1
            } else if j < m, i == n || at(i, j + 1) >= at(i + 1, j) {
                pendingB.append(b[j]); j += 1
            } else {
                pendingA.append(a[i]); i += 1
            }
        }
        flush()
        return result
    }

    // MARK: - Filtering

    private static func proposal(heard: [Token], written: [Token]) -> Substitution? {
        // Pure insertion or deletion: the user added or removed content, the model heard fine.
        guard !heard.isEmpty, !written.isEmpty,
              heard.count <= maximumPhraseWords, written.count <= maximumPhraseWords else { return nil }
        let heardKey = heard.map(\.key).joined(separator: " ")
        let writtenKey = written.map(\.key).joined(separator: " ")
        guard heardKey != writtenKey else { return nil }
        // A mapping from or to everyday words ("a" → "ha", "the" → "a") is grammar editing,
        // and as a vocabulary rule it would rewrite correct text everywhere.
        guard !isCommon(heardKey), !isCommon(writtenKey) else { return nil }
        // "3" → "tre" is formatting, not vocabulary; a canonical spelling must contain a letter.
        guard writtenKey.contains(where: \.isLetter), heardKey.contains(where: \.isLetter) else { return nil }
        return Substitution(heard: heard.map(\.text).joined(separator: " "),
                            written: written.map(\.text).joined(separator: " "))
    }

    /// A phrase is common when every word in it is: "con Martina" is still learnable, "di la" is not.
    static func isCommon(_ phrase: String) -> Bool {
        let words = VocabularySuggestions.key(phrase).split(separator: " ")
        return !words.isEmpty && words.allSatisfy { $0.count <= 1 || commonWords.contains(String($0)) }
    }

    /// Function words and very frequent words in the three dictation languages Dictari targets.
    /// Keys are folded (lowercase, no accents), matching `VocabularySuggestions.key`. Built from
    /// an array so a word shared by two languages ("so", "da") is not a duplicate set literal.
    static let commonWords: Set<String> = Set([
        // Italian
        "il", "lo", "la", "i", "gli", "le", "un", "uno", "una", "di", "del", "dello", "della", "dei",
        "degli", "delle", "da", "dal", "dallo", "dalla", "dai", "dagli", "dalle", "in", "nel", "nello",
        "nella", "nei", "negli", "nelle", "con", "su", "sul", "sullo", "sulla", "sui", "sugli", "sulle",
        "per", "tra", "fra", "a", "al", "allo", "alla", "ai", "agli", "alle", "e", "ed", "o", "od", "ma",
        "che", "chi", "cui", "non", "si", "no", "se", "anche", "come", "piu", "meno", "molto", "poco",
        "perche", "quando", "dove", "cosa", "questo", "questa", "questi", "queste", "quello", "quella",
        "quelli", "quelle", "io", "tu", "lui", "lei", "noi", "voi", "loro", "mi", "ti", "ci", "vi", "ne",
        "mio", "mia", "tuo", "tua", "suo", "sua", "sono", "sei", "siamo", "siete", "ho", "hai", "ha",
        "abbiamo", "avete", "hanno", "era", "ero", "essere", "avere", "fare", "fa", "fatto", "gia",
        "ancora", "poi", "ora", "allora", "cosi", "tutto", "tutti", "tutta", "tutte", "bene", "ok",
        "anno", "anni", "giorno", "oggi", "ieri", "domani", "c", "l", "d", "un", "po", "gia", "qui", "li",
        // English
        "the", "an", "and", "or", "but", "of", "to", "at", "on", "by", "for", "from", "with", "as",
        "is", "are", "was", "were", "be", "been", "am", "it", "its", "this", "that", "these", "those",
        "he", "she", "we", "they", "you", "me", "him", "her", "us", "them", "my", "your", "his", "our",
        "their", "not", "do", "does", "did", "have", "has", "had", "will", "would", "can", "could",
        "should", "if", "then", "so", "than", "there", "here", "what", "which", "who", "when", "where",
        "why", "how", "all", "some", "any", "no", "yes", "one", "two", "new", "just", "also", "very",
        "up", "out", "about", "into", "over", "now", "well", "get", "got", "go", "s", "t", "ll", "re",
        "ve", "m", "don", "okay", "right", "like",
        // German
        "der", "die", "das", "den", "dem", "des", "ein", "eine", "einen", "einem", "einer", "eines",
        "und", "oder", "aber", "nicht", "kein", "keine", "ist", "sind", "war", "waren", "bin", "bist",
        "sein", "hat", "habe", "haben", "wird", "werden", "ich", "du", "er", "sie", "es", "wir", "ihr",
        "mich", "dich", "sich", "uns", "euch", "mit", "von", "zu", "zum", "zur", "auf", "aus", "bei",
        "nach", "vor", "fur", "uber", "unter", "im", "am", "um", "an", "als", "wie", "wenn", "dass",
        "so", "auch", "noch", "schon", "nur", "ja", "nein", "doch", "mal", "hier", "da", "was", "wer",
        "wo", "denn", "dann", "sehr", "gut", "heute", "morgen",
    ])
}
