import Foundation

/// Evidence from saved text, never a generated spelling or an automatic replacement rule.
struct VocabularySuggestion: Identifiable, Sendable, Equatable {
    /// How the phrase was linked to the term. Shown to the user, so a "sounds like" match —
    /// spelled very differently — is not mistaken for a typo-level one.
    enum Match: Sendable, Equatable {
        /// Same first letter and a few letters apart ("Claud Code").
        case spelling
        /// Spelled differently but sounds alike ("Dipsick", "Asense calibrator").
        case sound
    }

    let id: String
    let phrase: String
    let context: String
    let date: Date
    var occurrences: Int
    /// Letter edit distance between the compact spellings.
    let distance: Int
    /// Normalised phonetic distance (`PhoneticSimilarity.normalizedDistance`), 0 = same sound.
    var soundDistance: Double = 0
    /// Ranking key: sound first, spelling second. Lower is closer.
    var score: Double = 0
    var match: Match = .spelling
}

/// Suggestions for one term from the "Scan history" pass over every term.
struct VocabularyScanResult: Identifiable, Sendable, Equatable {
    let term: VocabularyTerm
    var suggestions: [VocabularySuggestion]
    var id: UUID { term.id }
}

enum VocabularySuggestions {
    static let historyLimit = 500

    /// How many candidates per term the UI asks for before the main-actor lexicon pass
    /// (`filtered`) drops ordinary words, so dropping some still leaves a full list.
    static let candidatePool = 60

    /// A sound match at or below this is kept even when every word in it is a dictionary
    /// word ("Cloud Code", "Martina"): the evidence is the sound, not the spelling.
    static let strongSoundMatch = 0.12

    private struct Word {
        let range: Range<String.Index>
        let normalized: String
    }

    /// Same letter/number boundaries as VocabularyCorrector; retain ranges for real excerpts.
    private static func words(_ text: String) -> [Word] {
        var result: [Word] = []
        var start: String.Index?
        for index in text.indices {
            if text[index].isLetter || text[index].isNumber {
                if start == nil { start = index }
            } else if let lower = start {
                result.append(Word(range: lower..<index,
                                   normalized: VocabularyCorrector.normalize(String(text[lower..<index]))))
                start = nil
            }
        }
        if let start {
            result.append(Word(range: start..<text.endIndex,
                               normalized: VocabularyCorrector.normalize(String(text[start...]))))
        }
        return result
    }

    static func key(_ phrase: String) -> String {
        words(phrase).map(\.normalized).joined(separator: " ")
    }

    /// The existing corrector matches multiword aliases across a single space or hyphen.
    /// Do not propose a window crossing punctuation or a sentence boundary it cannot repair.
    private static func joinable(_ words: ArraySlice<Word>, in text: String) -> Bool {
        for pair in zip(words, words.dropFirst()) {
            if !joinable(pair.0, pair.1, in: text) { return false }
        }
        return true
    }

    private static func joinable(_ lhs: Word, _ rhs: Word, in text: String) -> Bool {
        let gap = text[lhs.range.upperBound..<rhs.range.lowerBound]
        return gap == " " || gap == "-"
    }

    static func validationMessage(for phrase: String, term: VocabularyTerm, knownTerms: [VocabularyTerm]) -> String? {
        let tokens = words(phrase)
        guard !tokens.isEmpty else {
            return String(localized: "Select the word or phrase that was transcribed incorrectly.",
                          comment: "Vocabulary: hint while picking a misheard phrase")
        }
        guard phrase.count <= 80, tokens.count <= 8 else {
            return String(localized: "Choose a shorter phrase (up to 8 words).",
                          comment: "Vocabulary: misheard phrase is too long")
        }
        guard joinable(tokens[...], in: phrase),
              tokens.first?.range.lowerBound == phrase.startIndex,
              tokens.last?.range.upperBound == phrase.endIndex else {
            return String(localized: "Select words within one phrase, without surrounding punctuation.",
                          comment: "Vocabulary: invalid misheard-phrase selection")
        }
        let candidate = key(phrase)
        if candidate == key(term.text) {
            return String(localized: "This is already the correct spelling.",
                          comment: "Vocabulary: why a correction could not be learned")
        }
        if term.alternatives.contains(where: { key($0) == candidate }) {
            return String(localized: "Already in Heard as.",
                          comment: "Vocabulary: phrase is already listed; \"Heard as\" is the name of the alternatives field")
        }
        // "Claude che" for Claude Code: the term's own word spelled right plus a common word
        // is ordinary speech ("uso Claude che è ottimo"), not a mishearing. Mapping it would
        // rewrite every such sentence.
        let termWords = Set(key(term.text).split(separator: " "))
        let phraseWords = candidate.split(separator: " ")
        if phraseWords.count > 1, phraseWords.contains(where: termWords.contains),
           phraseWords.filter({ !termWords.contains($0) }).allSatisfy({ CorrectionDiff.isCommon(String($0)) }) {
            return String(localized: "Too close to normal speech: \(term.text)'s own word plus a common word.",
                          comment: "Vocabulary: %@ is the user's vocabulary word")
        }
        for other in knownTerms where other.id != term.id {
            if ([other.text] + other.alternatives).contains(where: { key($0) == candidate }) {
                return String(localized: "Already used by \(other.text).",
                              comment: "Vocabulary: %@ is another vocabulary word that already owns this phrase")
            }
        }
        return nil
    }

    /// Selection is an NSTextView UTF-16 range. Expand partial words and trim surrounding
    /// punctuation, without losing accents, emoji offsets or the original spelling.
    static func selectedPhrase(in text: String, range: NSRange) -> String {
        guard range.location != NSNotFound, range.length > 0,
              range.location <= text.utf16.count,
              range.length <= text.utf16.count - range.location,
              let selected = Range(range, in: text) else { return "" }
        let hits = words(text).filter { $0.range.overlaps(selected) }
        guard let first = hits.first, let last = hits.last else { return "" }
        return String(text[first.range.lowerBound..<last.range.upperBound])
    }

    // MARK: - Search

    /// Run on a utility task, only when the user opens the history picker. It never runs on
    /// the dictation path. Cancellation bounds work after the picker is dismissed.
    ///
    /// `knownTerms` compete for the same words (see `scan`), so a phrase that belongs to
    /// another term — "Code" inside "Cloud Code" — is not offered for "Codex".
    static func find(for term: VocabularyTerm, in history: [HistoryEntry],
                     knownTerms: [VocabularyTerm], limit: Int = 12) throws -> [VocabularySuggestion] {
        try scan(terms: [term], in: history, knownTerms: knownTerms, limit: limit).first?.suggestions ?? []
    }

    /// "Scan history": suggestions for every term in `terms` in one pass over history.
    ///
    /// Every term in `terms` and `knownTerms` (enabled or not) takes part, and each stretch of
    /// words is attributed to at most one of them — the closest — so the same words are never
    /// proposed for two terms. Words already spelled as some term or one of its "Heard as"
    /// alternatives are not candidates at all: they are already handled.
    ///
    /// A window of saved words is proposed for a term when it *sounds* like it
    /// (`PhoneticSimilarity`) — not merely when it is spelled alike — because the engine
    /// mishears rather than misspells: "Dipsick" for Deepseek, "di Tari" for Dictari. The rules
    /// that keep ordinary words out:
    /// - a different first sound needs a near-identical rest (`differentOnsetThreshold`);
    /// - short phrases get a stricter bar (`soundThreshold`): more real words sit near them;
    /// - a multiword window is compared word by word too, so "the code" is not Claude Code;
    /// - a window of common words only (`CorrectionDiff.isCommon`) is never a candidate;
    /// - an article or other short word next to a match is context, unless the sound needs
    ///   it ("di Tari" is closer to Dictari than "Tari" alone).
    ///
    /// Results are unfiltered by dictionary; see `filtered` for the main-actor lexicon pass.
    static func scan(terms: [VocabularyTerm], in history: [HistoryEntry],
                     knownTerms: [VocabularyTerm], limit: Int = 12) throws -> [VocabularyScanResult] {
        try Task.checkCancellation()

        // Subjects first, so their (possibly edited, unsaved) spelling wins over the stored copy
        // with the same id; indices below `subjectCount` are the terms results are wanted for.
        var competitors: [VocabularyTerm] = []
        var seenIDs: Set<UUID> = []
        for term in terms where seenIDs.insert(term.id).inserted { competitors.append(term) }
        let subjectCount = competitors.count
        for term in knownTerms where seenIDs.insert(term.id).inserted { competitors.append(term) }

        let blocked = Set(competitors.flatMap { [$0.text] + $0.alternatives }.map(key).filter { !$0.isEmpty })
        let longestBlocked = blocked.map { $0.split(separator: " ").count }.max() ?? 0
        let targets = competitors.enumerated().compactMap { Target(index: $0.offset, term: $0.element) }
        let subjects = competitors.prefix(subjectCount)
        guard limit > 0, targets.contains(where: { $0.index < subjectCount }) else {
            return subjects.map { VocabularyScanResult(term: $0, suggestions: []) }
        }
        let longestWindow = targets.map(\.windows.upperBound).max() ?? 1

        var soundCache: [String: [Character]] = [:]
        func sounds(_ compact: String) -> [Character] {
            if let cached = soundCache[compact] { return cached }
            let encoded = PhoneticSimilarity.encode(compact)
            soundCache[compact] = encoded
            return encoded
        }
        var verdicts: [VerdictKey: Verdict?] = [:]
        var candidates = [[String: VocabularySuggestion]](repeating: [:], count: competitors.count)
        var visited: Set<UUID> = []

        // Sort a snapshot; the source history and vocabulary are never mutated.
        let entries = history.filter { !$0.isFailure && !$0.text.isEmpty }
            .sorted { $0.date > $1.date }.prefix(historyLimit)
        for entry in entries {
            try Task.checkCancellation()
            guard visited.insert(entry.id).inserted else { continue }
            let tokens = words(entry.text)
            guard !tokens.isEmpty else { continue }

            // Words already written as a term or a known alternative are handled; a window
            // touching them is either that phrase plus context ("Claude Code today") or a
            // fragment of it ("Code" for Codex).
            var claimed = [Bool](repeating: false, count: tokens.count)
            if longestBlocked > 0 {
                for start in tokens.indices {
                    var phrase = ""
                    for end in start..<min(tokens.count, start + longestBlocked) {
                        if end > start {
                            guard joinable(tokens[end - 1], tokens[end], in: entry.text) else { break }
                            phrase += " "
                        }
                        phrase += tokens[end].normalized
                        if blocked.contains(phrase) {
                            for index in start...end { claimed[index] = true }
                        }
                    }
                }
            }

            var spans: [Span] = []
            for start in tokens.indices {
                if start.isMultiple(of: 64) { try Task.checkCancellation() }
                var normalized: [String] = []
                for end in start..<min(tokens.count, start + longestWindow) {
                    if claimed[end] { break }
                    if end > start, !joinable(tokens[end - 1], tokens[end], in: entry.text) { break }
                    normalized.append(tokens[end].normalized)
                    let candidateKey = normalized.joined(separator: " ")
                    let compact = normalized.joined()
                    let windowSounds = sounds(compact)
                    for target in targets where target.windows.contains(normalized.count) {
                        let verdictKey = VerdictKey(target: target.index, key: candidateKey)
                        let verdict: Verdict?
                        if let cached = verdicts[verdictKey] {
                            verdict = cached
                        } else {
                            verdict = evaluate(normalized, compact: compact, sounds: windowSounds,
                                               against: target, soundsOf: sounds)
                            verdicts[verdictKey] = verdict
                        }
                        guard let verdict else { continue }
                        spans.append(Span(target: target.index, start: start, count: normalized.count,
                                          key: candidateKey, verdict: verdict))
                    }
                }
            }

            // Each word goes to the closest match only. Ties go to the longer window (it
            // explains more of what was said), then to vocabulary order.
            spans.sort {
                if $0.verdict.score != $1.verdict.score { return $0.verdict.score < $1.verdict.score }
                if $0.count != $1.count { return $0.count > $1.count }
                if $0.target != $1.target { return $0.target < $1.target }
                return $0.start < $1.start
            }
            var used = [Bool](repeating: false, count: tokens.count)
            for span in spans {
                let indices = span.start..<(span.start + span.count)
                guard !indices.contains(where: { used[$0] }) else { continue }
                if span.target >= subjectCount {
                    // A competitor wins these words; nothing to record for it.
                    for index in indices { used[index] = true }
                    continue
                }
                if var existing = candidates[span.target][span.key] {
                    existing.occurrences += 1
                    candidates[span.target][span.key] = existing
                    for index in indices { used[index] = true }
                    continue
                }
                let range = tokens[span.start].range.lowerBound..<tokens[indices.upperBound - 1].range.upperBound
                let phrase = String(entry.text[range])
                // Same rules as a phrase picked by hand; `knownTerms` is the stored vocabulary.
                guard validationMessage(for: phrase, term: competitors[span.target], knownTerms: knownTerms) == nil else { continue }
                for index in indices { used[index] = true }
                let lower = entry.text.index(range.lowerBound, offsetBy: -65, limitedBy: entry.text.startIndex) ?? entry.text.startIndex
                let upper = entry.text.index(range.upperBound, offsetBy: 65, limitedBy: entry.text.endIndex) ?? entry.text.endIndex
                let context = (lower == entry.text.startIndex ? "" : "…") + String(entry.text[lower..<upper])
                    + (upper == entry.text.endIndex ? "" : "…")
                candidates[span.target][span.key] = VocabularySuggestion(
                    id: span.key, phrase: phrase, context: context, date: entry.date, occurrences: 1,
                    distance: span.verdict.letters, soundDistance: span.verdict.sound,
                    score: span.verdict.score, match: span.verdict.match)
            }
        }

        return (0..<subjectCount).map { index in
            let dismissed = Set(competitors[index].dismissed.map(key))
            let ranked = candidates[index].values.filter { !dismissed.contains(key($0.phrase)) }.sorted {
                if $0.score != $1.score { return $0.score < $1.score }
                if $0.occurrences != $1.occurrences { return $0.occurrences > $1.occurrences }
                if $0.date != $1.date { return $0.date > $1.date }
                return $0.id < $1.id
            }
            return VocabularyScanResult(term: competitors[index], suggestions: Array(ranked.prefix(limit)))
        }
    }

    /// Drop ordinary words that merely sound close ("mattina" for Martino, "dettare" for
    /// Dictari), then apply `limit`.
    ///
    /// `isKnownWord` answers "is this a real word in a language the user dictates in?". The
    /// UI backs it with the system spelling dictionaries on the main actor (`SpellingLexicon`),
    /// which is why this is a separate step from the off-main `scan`. A suggestion is dropped
    /// only when its sound match is not strong *and* every word in it — common words aside —
    /// is a known word: a real mishearing is rarely a dictionary word, and when it is ("Cloud
    /// Code", "Martina") the sound match is close enough to keep.
    ///
    /// A phrase that contains an article or other short word ("di Tari") only matched because
    /// the scan found the sound needs that word, so it is a split spelling of one word: judge
    /// the joined form ("ditari"), not the fragments ("tari" is in the Italian dictionary).
    static func filtered(_ suggestions: [VocabularySuggestion], limit: Int,
                         isKnownWord: (String) -> Bool) -> [VocabularySuggestion] {
        var kept: [VocabularySuggestion] = []
        for suggestion in suggestions where kept.count < limit {
            if suggestion.soundDistance > strongSoundMatch {
                let words = key(suggestion.phrase).split(separator: " ").map(String.init)
                let content = words.contains(where: isContextWord) ? [words.joined()] : words
                if !content.isEmpty, content.allSatisfy(isKnownWord) { continue }
            }
            kept.append(suggestion)
        }
        return kept
    }

    // MARK: - Scoring

    private struct Target {
        let index: Int
        let words: [String]
        let compact: String
        let sounds: [Character]
        let weight: Double
        /// The pre-phonetic rule, kept to label a match as `.spelling` and as a tiebreak.
        let spellingThreshold: Int
        let windows: ClosedRange<Int>
        /// Per-word sounds, for the word-by-word check of same-length windows.
        let wordSounds: [[Character]]

        init?(index: Int, term: VocabularyTerm) {
            let words = VocabularySuggestions.words(term.text).map(\.normalized)
            let compact = words.joined()
            guard compact.count >= 4, compact.count <= 80, !words.isEmpty, words.count <= 8 else { return nil }
            self.index = index
            self.words = words
            self.compact = compact
            self.sounds = PhoneticSimilarity.encode(compact)
            self.weight = PhoneticSimilarity.weight(sounds)
            self.spellingThreshold = min(3, max(1, compact.count / 4))
            self.windows = max(1, words.count - 1)...min(8, words.count + 1)
            self.wordSounds = words.map(PhoneticSimilarity.encode)
        }
    }

    private struct Verdict: Hashable {
        let sound: Double
        let letters: Int
        let score: Double
        let match: VocabularySuggestion.Match
    }

    private struct VerdictKey: Hashable {
        let target: Int
        let key: String
    }

    private struct Span {
        let target: Int
        let start: Int
        let count: Int
        let key: String
        let verdict: Verdict
    }

    /// Phrases of this weight or more (about six consonants) get the looser bar.
    private static let longPhraseWeight = 6.0
    /// Short phrases: a single consonant slip in a five-letter word is already a large
    /// fraction of it, and far more ordinary words sit that close ("mattino" / "Martino").
    private static let shortPhraseThreshold = 0.22
    /// Word-by-word bar for multiword windows: loose, only there to stop one strong word
    /// carrying an unrelated one ("the code" for Claude Code).
    private static let perWordThreshold = 0.5
    /// A window that adds context words must beat the bare window by this much to keep them.
    private static let contextMargin = 0.1

    static func soundThreshold(forWeight weight: Double) -> Double {
        weight >= longPhraseWeight ? PhoneticSimilarity.acceptThreshold : shortPhraseThreshold
    }

    private static func isContextWord(_ word: String) -> Bool {
        word.count <= 2 || CorrectionDiff.commonWords.contains(word)
    }

    private static func evaluate(_ normalized: [String], compact: String, sounds: [Character],
                                 against target: Target,
                                 soundsOf: (String) -> [Character]) -> Verdict? {
        // Articles, prepositions and pronouns alone are grammar, never a mishearing to learn.
        if normalized.allSatisfy({ $0.count <= 1 || CorrectionDiff.commonWords.contains($0) }) { return nil }

        let heavier = max(PhoneticSimilarity.weight(sounds), target.weight)
        let threshold = soundThreshold(forWeight: heavier)
        // Lower bound: every sound costs at least its weight difference to insert or delete,
        // so a window much longer or shorter than the term cannot pass. Skips the DP.
        let lengthGap = abs(PhoneticSimilarity.weight(sounds) - target.weight) * 0.8
        guard heavier > 0, lengthGap / heavier <= threshold else { return nil }

        let sound = PhoneticSimilarity.normalizedDistance(sounds, target.sounds)
        let sameOnset = PhoneticSimilarity.sameOnset(sounds, target.sounds)
        guard sound <= (sameOnset ? threshold : min(threshold, PhoneticSimilarity.differentOnsetThreshold)) else {
            return nil
        }

        // Added articles/pronouns are context, not a plausible split spelling. Still allow
        // exact split forms ("co dex" for "Codex") and a short word the sound needs
        // ("di Tari" for Dictari: "Tari" alone is much further away).
        if normalized.count > target.words.count, compact != target.compact,
           normalized.contains(where: isContextWord) {
            var core = normalized[...]
            while let first = core.first, isContextWord(first) { core = core.dropFirst() }
            while let last = core.last, isContextWord(last) { core = core.dropLast() }
            guard !core.isEmpty, !core.contains(where: { $0.count <= 2 }) else { return nil }
            let bare = PhoneticSimilarity.normalizedDistance(soundsOf(core.joined()), target.sounds)
            guard sound + contextMargin < bare else { return nil }
        }

        // Same number of words: each word must resemble its counterpart, not just the whole.
        if normalized.count == target.words.count, normalized.count > 1 {
            for (word, targetWord) in zip(normalized, target.wordSounds) {
                let distance = PhoneticSimilarity.normalizedDistance(soundsOf(word), targetWord)
                guard distance <= perWordThreshold else { return nil }
            }
        }

        let letters = editDistance(compact, target.compact)
        let spelling = compact.first == target.compact.first
            && letters <= target.spellingThreshold
            && abs(compact.count - target.compact.count) <= target.spellingThreshold
        let letterRatio = Double(letters) / Double(max(compact.count, target.compact.count))
        // Sound decides; spelling breaks near-ties ("Claud Code" before "Cloud Code").
        let score = 0.7 * sound + 0.3 * letterRatio
        return Verdict(sound: sound, letters: letters, score: score, match: spelling ? .spelling : .sound)
    }

    private static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let a = Array(lhs), b = Array(rhs)
        var previous = Array(0...b.count)
        for (i, character) in a.enumerated() {
            var current = [i + 1] + Array(repeating: 0, count: b.count)
            for j in b.indices {
                current[j + 1] = min(current[j] + 1, previous[j + 1] + 1,
                                     previous[j] + (character == b[j] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }
}
