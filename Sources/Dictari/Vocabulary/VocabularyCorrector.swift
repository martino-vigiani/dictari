// VocabularyCorrector.swift
// Dictari — the custom-vocabulary term type and the pure post-processing corrector.
//
// Why post-processing rather than only biasing the model: of the two engines Dictari ships,
// only WhisperKit exposes a conditioning prompt (`DecodingOptions.promptTokens`), and even
// there a prompt is a *hint* — the decoder is free to ignore it. FluidAudio's batch
// `AsrManager` (the Parakeet path) has no vocabulary hook at all; its context-biasing lives
// on `SlidingWindowAsrManager`, a different manager that also needs a separate CTC model.
// So the transcript has to be repairable after the fact, for both engines, or the feature
// simply does not exist on Parakeet. `VocabularyPrompt` below covers the biasing half.
//
// The whole file is pure and synchronous on purpose: it runs on the stop→inject path, where
// latency is a product requirement, and it must be unit-testable without a host app.
//
// Design stance: **a dictation app that corrupts words the model got right is unusable.**
// Every rule below is written to fail closed. When in doubt, leave the transcript alone.

import Foundation

// MARK: - Term

/// One entry in the user's custom vocabulary.
///
/// `text` is the canonical spelling ("Martino", "Dictari", "kubectl"). `alternatives` are
/// mishearings the user has actually seen; they are matched exactly and are the precise,
/// zero-guesswork path when the fuzzy rules below are deliberately too strict to fire.
struct VocabularyTerm: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var text: String
    var enabled: Bool
    var alternatives: [String]
    /// Spellings the user dismissed in a history scan for this term. Never used for
    /// correction; only keeps the scan from proposing them again.
    var dismissed: [String]

    init(id: UUID = UUID(), text: String, enabled: Bool = true, alternatives: [String] = [],
         dismissed: [String] = []) {
        self.id = id
        self.text = text
        self.enabled = enabled
        self.alternatives = alternatives
        self.dismissed = dismissed
    }

    /// Hand-written so a file produced by an older or newer build still decodes. The
    /// synthesized `Decodable` throws `keyNotFound` for a missing non-optional property,
    /// which for a whole-list store means silently losing every term the user typed —
    /// the same trap `SettingsPersistenceTests` exists to guard.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.alternatives = try c.decodeIfPresent([String].self, forKey: .alternatives) ?? []
        self.dismissed = try c.decodeIfPresent([String].self, forKey: .dismissed) ?? []
    }
}

// MARK: - Correction record

/// One rewrite the corrector performed — what the model produced, and what replaced it.
/// Drives the "try it" preview in settings, and makes the tests read as prose.
struct VocabularyCorrection: Sendable, Hashable {
    let original: String
    let replacement: String
}

/// The confidence-aware corrector's answer: the corrected text, the words the engine was unsure
/// of as they now read in it (a corrected word appears under its replacement), in order, and
/// the rewrites made.
struct ConfidenceCorrection: Sendable, Equatable {
    let text: String
    let uncertainWords: [UncertainWord]
    let corrections: [VocabularyCorrection]
}

// MARK: - Corrector

/// Repairs a transcript against the user's vocabulary. Pure, synchronous, `Sendable`.
///
/// ```swift
/// let corrector = VocabularyCorrector(terms: store.terms)
/// let fixed = corrector.correct("Ciao, sono Martina.")   // "Ciao, sono Martino."
/// ```
struct VocabularyCorrector: Sendable {

    // MARK: Prepared pattern

    /// One spelling the matcher compares transcript words against — a term's canonical form
    /// or one of its alternatives — compiled up front so `correct` normalises nothing per
    /// transcript word. Alternatives carry their own word count, so a one-word term can be
    /// restored from a two-word mishearing ("cube cuddle" → "kubectl").
    private struct Pattern: Sendable {
        /// What replaces a match.
        let replacement: String
        /// The pattern's words, normalised (folded + lowercased).
        let words: [String]
        /// Consonant skeletons of `words`, one per word.
        let skeletons: [String]
        /// Vowel sequences of `words`, one per word.
        let vowelSeqs: [String]
        /// Sound-class consonant keys of `words` (see `phonetic`), used only for words the
        /// engine was unsure of. Empty for alternatives, which are never stretched.
        var looseKeys: [String] = []
        /// Vowels of `words` after the same digraph handling as `looseKeys`.
        var looseVowels: [String] = []

        var wordCount: Int { words.count }
    }

    /// Canonical spellings and alternatives alike, matched exactly. Bucketed by their first
    /// normalised word so a transcript word only ever meets the patterns that could possibly
    /// start with it — the flat scan was O(words × patterns) with an allocation per pair, and
    /// measured ~30 ms for a 120-word paragraph at 150 terms. Longest phrase first within a
    /// bucket, which is the only place candidates can still compete.
    private let exactByFirstWord: [String: [Pattern]]
    /// Canonical spellings only, and only those long enough to fuzzy-match safely; an
    /// alternative is a fact the user supplied and is never stretched. Bucketed by the first
    /// word's consonant skeleton: a fuzzy hit requires an identical skeleton and an exact hit
    /// implies one, so the bucket key covers both ways the first word can match.
    private let fuzzyByFirstSkeleton: [String: [Pattern]]
    /// The same canonical spellings as `fuzzyByFirstSkeleton`, bucketed by the first word's
    /// sound-class key. Consulted only for words below the confidence threshold.
    private let looseByFirstKey: [String: [Pattern]]
    private let hasMultiWordLoosePatterns: Bool
    private var hasPatterns: Bool { !exactByFirstWord.isEmpty }
    /// Every normalised spelling that is *itself* a vocabulary entry (canonical or
    /// alternative). A word the user has explicitly written down somewhere is a word they
    /// meant; it is never fuzzily rewritten into a different term.
    private let protectedSpellings: Set<String>

    // MARK: Init

    init(terms: [VocabularyTerm]) {
        var exact: [Pattern] = []
        var fuzzy: [Pattern] = []
        var protected: Set<String> = []

        for term in terms where term.enabled {
            let canonical = term.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let words = Self.words(in: canonical).map(Self.normalize)
            guard !words.isEmpty else { continue }

            var pattern = Pattern(
                replacement: canonical,
                words: words,
                skeletons: words.map(Self.skeleton),
                vowelSeqs: words.map(Self.vowels)
            )
            protected.insert(words.joined(separator: " "))
            exact.append(pattern)
            if words.allSatisfy({ $0.count >= Rules.minimumFuzzyLength }) {
                let phonetic = words.map(Self.phonetic)
                pattern.looseKeys = phonetic.map(\.key)
                pattern.looseVowels = phonetic.map(\.vowels)
                fuzzy.append(pattern)
            }

            for alt in term.alternatives {
                let altWords = Self.words(in: alt).map(Self.normalize)
                guard !altWords.isEmpty, altWords != words else { continue }
                protected.insert(altWords.joined(separator: " "))
                exact.append(
                    Pattern(
                        replacement: canonical,
                        words: altWords,
                        skeletons: altWords.map(Self.skeleton),
                        vowelSeqs: altWords.map(Self.vowels)
                    )
                )
            }
        }

        // Longest phrase first: "Martino Vigiani" must win over "Martino" at the same index.
        // Sorted before grouping so each bucket keeps that order.
        self.exactByFirstWord = Dictionary(
            grouping: exact.sorted { $0.wordCount > $1.wordCount },
            by: { $0.words[0] }
        )
        self.fuzzyByFirstSkeleton = Dictionary(
            grouping: fuzzy.sorted { $0.wordCount > $1.wordCount },
            by: { $0.skeletons[0] }
        )
        self.looseByFirstKey = Dictionary(
            grouping: fuzzy.sorted { $0.wordCount > $1.wordCount },
            by: { $0.looseKeys[0] }
        )
        self.hasMultiWordLoosePatterns = fuzzy.contains { $0.wordCount > 1 }
        self.protectedSpellings = protected
    }

    // MARK: Public API

    /// The corrected transcript. Returns the input unchanged when nothing matched.
    func correct(_ transcript: String) -> String {
        run(transcript).text
    }

    /// The rewrites `correct` would make, in transcript order. Same work, different answer —
    /// used by the settings preview so the user can see the feature before trusting it.
    func corrections(in transcript: String) -> [VocabularyCorrection] {
        run(transcript).corrections
    }

    /// A settings preview needs both the final text and its explanation. Returning them from
    /// one pass avoids repeating tokenization and matching for every edited character.
    func result(for transcript: String) -> (text: String, corrections: [VocabularyCorrection]) {
        let result = run(transcript)
        return (result.text, result.corrections)
    }

    /// The confidence-aware pass used on the dictation path.
    ///
    /// Words the engine was sure of get exactly the strict rules `correct(_:)` applies, so the
    /// text is identical to `correct(output.text)` whenever no word is below `threshold`. A word
    /// below it may additionally match a vocabulary term through sound-class equivalence (see
    /// `looseMatches`). The result also lists the uncertain words as they read in the corrected
    /// text — replacements included — so History can point at them.
    func correct(
        _ output: TranscriptionOutput,
        threshold: Float = TranscriptConfidence.uncertainThreshold
    ) -> ConfidenceCorrection {
        var uncertain: [(range: Range<String.Index>, confidence: Float)] = []
        if output.hasConfidence {
            let ranges = TranscriptConfidence.align(output.words, in: output.text)
            for (word, range) in zip(output.words, ranges) {
                guard let range, let confidence = word.confidence, confidence < threshold else { continue }
                uncertain.append((range, confidence))
            }
        }
        let result = run(output.text, uncertain: uncertain, threshold: threshold)
        return ConfidenceCorrection(
            text: result.text, uncertainWords: result.uncertain, corrections: result.corrections
        )
    }

    // MARK: Core

    private struct RunResult {
        var text: String
        var corrections: [VocabularyCorrection]
        var uncertain: [UncertainWord] = []
    }

    /// `uncertain` must be sorted and non-overlapping (alignment guarantees both). It is empty
    /// on every path that has no confidence, and then nothing below differs from the strict,
    /// confidence-blind corrector.
    private func run(
        _ transcript: String,
        uncertain: [(range: Range<String.Index>, confidence: Float)] = [],
        threshold: Float = TranscriptConfidence.uncertainThreshold
    ) -> RunResult {
        guard !transcript.isEmpty else { return RunResult(text: transcript, corrections: []) }
        // No vocabulary: the text is untouched, but unsure words are still worth reporting.
        guard hasPatterns else {
            return RunResult(
                text: transcript, corrections: [],
                uncertain: uncertain.map { UncertainWord(text: String(transcript[$0.range]),
                                                         confidence: $0.confidence) }
            )
        }

        let tracking = !uncertain.isEmpty
        let scan = Self.split(transcript, recordingRanges: tracking)
        guard !scan.words.isEmpty else { return RunResult(text: transcript, corrections: []) }

        // One skeleton/vowel pass per transcript word, up front. The fuzzy matcher used to
        // recompute both once per candidate pattern for the same word.
        let skeletons = fuzzyByFirstSkeleton.isEmpty ? [] : scan.normalized.map(Self.skeleton)
        let vowelSeqs = fuzzyByFirstSkeleton.isEmpty ? [] : scan.normalized.map(Self.vowels)

        // Confidence per transcript word: the weakest engine word overlapping it. Only
        // uncertain words are recorded; nil means "use the strict rules only".
        var wordConfidence: [Float?] = []
        var loose: [(key: String, vowels: String)] = []
        if tracking {
            wordConfidence = Array(repeating: nil, count: scan.words.count)
            var u = 0
            for i in scan.words.indices {
                let r = scan.ranges[i]
                while u < uncertain.count, uncertain[u].range.upperBound <= r.lowerBound { u += 1 }
                var k = u
                while k < uncertain.count, uncertain[k].range.lowerBound < r.upperBound {
                    let c = uncertain[k].confidence
                    wordConfidence[i] = min(wordConfidence[i] ?? c, c)
                    k += 1
                }
            }
            // A phrase's confident first word still has to find the bucket for a loose match on
            // a later word, so with multi-word terms every word gets a key. Otherwise only the
            // uncertain ones need one — a confident single word can never match loosely.
            if !looseByFirstKey.isEmpty, wordConfidence.contains(where: { $0 != nil }) {
                loose = scan.normalized.indices.map { i in
                    hasMultiWordLoosePatterns || wordConfidence[i] != nil
                        ? Self.phonetic(scan.normalized[i]) : ("", "")
                }
            }
        }

        var out = scan.separators[0]
        var corrections: [VocabularyCorrection] = []
        // Per emitted unit: first/last transcript word and its UTF-8 span in `out`.
        var units: [(first: Int, last: Int, start: Int, end: Int)] = []
        var index = 0

        while index < scan.words.count {
            let start = out.utf8.count
            let length: Int
            if let hit = match(at: index, in: scan, skeletons: skeletons, vowelSeqs: vowelSeqs,
                               confidence: wordConfidence, loose: loose) {
                let original = Self.join(scan, from: index, count: hit.length)
                if hit.text != original {
                    corrections.append(VocabularyCorrection(original: original, replacement: hit.text))
                }
                out += hit.text
                length = hit.length
            } else {
                out += scan.words[index]
                length = 1
            }
            if tracking { units.append((index, index + length - 1, start, out.utf8.count)) }
            index += length
            if index < scan.words.count { out += scan.separators[index] }
        }

        out += scan.separators[scan.words.count]
        guard tracking else { return RunResult(text: out, corrections: corrections) }
        return RunResult(
            text: out, corrections: corrections,
            uncertain: Self.project(uncertain, through: units, scan: scan, output: out)
        )
    }

    /// Where each uncertain input range ended up in the output: the span from the first to the
    /// last emitted unit it overlaps. A replacement that swallowed two uncertain words yields one
    /// span carrying the weaker confidence.
    private static func project(
        _ uncertain: [(range: Range<String.Index>, confidence: Float)],
        through units: [(first: Int, last: Int, start: Int, end: Int)],
        scan: Scan, output: String
    ) -> [UncertainWord] {
        var spans: [(start: Int, end: Int, confidence: Float)] = []
        var u = 0
        for item in uncertain {
            while u < units.count,
                  scan.ranges[units[u].last].upperBound <= item.range.lowerBound { u += 1 }
            var k = u
            var start: Int?
            var end = 0
            while k < units.count, scan.ranges[units[k].first].lowerBound < item.range.upperBound {
                start = start ?? units[k].start
                end = units[k].end
                k += 1
            }
            guard let start else { continue }
            if let last = spans.last, start < last.end {
                spans[spans.count - 1] = (last.start, max(last.end, end), min(last.confidence, item.confidence))
            } else {
                spans.append((start, end, item.confidence))
            }
        }
        let utf8 = output.utf8
        return spans.map { span in
            let lower = utf8.index(utf8.startIndex, offsetBy: span.start)
            let upper = utf8.index(lower, offsetBy: span.end - span.start)
            return UncertainWord(text: String(output[lower..<upper]), confidence: span.confidence)
        }
    }

    /// Best match starting at `index`, or nil.
    ///
    /// Exact wins over fuzzy across the *whole* vocabulary, not just within one term — a word
    /// that is spelled exactly like some term must never be swallowed by a fuzzy neighbour.
    /// Within each pass the longest phrase wins. The loose pass runs last and only for words
    /// the engine flagged as uncertain.
    private func match(
        at index: Int, in scan: Scan, skeletons: [String], vowelSeqs: [String],
        confidence: [Float?], loose: [(key: String, vowels: String)]
    ) -> (text: String, length: Int)? {
        // Pass 1 — exact, ignoring case and diacritics. Covers both the canonical spelling
        // ("dictari" → "Dictari", "pero" → "però") and the mishearings the user recorded.
        // An alternative is a fact; facts do not need to be guessed at.
        if let candidates = exactByFirstWord[scan.normalized[index]] {
            for pattern in candidates where windowExists(scan, at: index, count: pattern.wordCount) {
                var equal = true
                for k in 0..<pattern.wordCount where scan.normalized[index + k] != pattern.words[k] {
                    equal = false
                    break
                }
                if equal {
                    return (cased(pattern.replacement, like: scan, from: index, count: pattern.wordCount),
                            pattern.wordCount)
                }
            }
        }

        // Pass 2 — fuzzy. Everything here is a reason *not* to fire.
        if !skeletons.isEmpty, let candidates = fuzzyByFirstSkeleton[skeletons[index]] {
            for pattern in candidates where windowExists(scan, at: index, count: pattern.wordCount) {
                // The joined form only exists to consult `protectedSpellings`, so the
                // allocation is paid per surviving candidate, not per (word, pattern) pair.
                let joined = scan.normalized[index..<(index + pattern.wordCount)]
                    .joined(separator: " ")
                guard !protectedSpellings.contains(joined) else { continue }
                guard fuzzyMatches(scan, at: index, pattern: pattern,
                                   skeletons: skeletons, vowelSeqs: vowelSeqs) else { continue }
                return (cased(pattern.replacement, like: scan, from: index, count: pattern.wordCount),
                        pattern.wordCount)
            }
        }

        // Pass 3 — loose, for uncertain words only. Same fail-closed stance, wider net.
        if !loose.isEmpty, !loose[index].key.isEmpty, let candidates = looseByFirstKey[loose[index].key] {
            for pattern in candidates where windowExists(scan, at: index, count: pattern.wordCount) {
                let joined = scan.normalized[index..<(index + pattern.wordCount)]
                    .joined(separator: " ")
                guard !protectedSpellings.contains(joined) else { continue }
                guard looseMatches(scan, at: index, pattern: pattern,
                                   confidence: confidence, loose: loose) else { continue }
                return (cased(pattern.replacement, like: scan, from: index, count: pattern.wordCount),
                        pattern.wordCount)
            }
        }
        return nil
    }

    /// The loose rule, for a word the engine itself was unsure of:
    ///
    /// - the word must be **below the confidence threshold** — a confident word never reaches
    ///   this pass, so everything the strict rules protect stays protected;
    /// - the **sound-class key must be identical**: spellings of the same consonant sound in
    ///   Italian, English and German collapse together (`c/k/q/ch`, `g/gh`, `z/ts/tz`, `v/w`,
    ///   `f/ph`, `sc(e/i)/sh/sch`, `gn/ny`, silent `h`, doubled letters). "Chubernetis" and
    ///   "Kubernetes" are both `kbrnts`; "cabernet" is `kbrnt` and is not;
    /// - the key needs at least three consonant classes: a two-class key ("dura" / "Dora")
    ///   is shared by too many real words to be evidence of anything;
    /// - the vowels may differ by **one edit** (substitution, insertion or deletion) — the
    ///   uncertainty is what licenses going beyond the confusable `a e o` / `i y` classes;
    /// - words shorter than four letters and anything the user wrote down as a spelling
    ///   (`protectedSpellings`) are never touched; alternatives are never stretched;
    /// - in a multi-word phrase at most one word may be loose, and the rest must be exact.
    private func looseMatches(
        _ scan: Scan, at index: Int, pattern: Pattern,
        confidence: [Float?], loose: [(key: String, vowels: String)]
    ) -> Bool {
        var looseWords = 0
        for i in 0..<pattern.wordCount {
            let position = index + i
            if scan.normalized[position] == pattern.words[i] { continue }
            looseWords += 1
            guard looseWords <= 1 else { return false }
            guard confidence[position] != nil else { return false }
            guard scan.normalized[position].count >= Rules.minimumFuzzyLength else { return false }
            guard loose[position].key == pattern.looseKeys[i],
                  loose[position].key.count >= Rules.minimumLooseKeyLength else { return false }
            guard Self.withinOneEdit(loose[position].vowels, pattern.looseVowels[i]) else { return false }
        }
        return looseWords == 1
    }

    /// Whether a `count`-word window starting at `index` fits in the transcript and its words
    /// are joinable into a phrase. Pure bounds/separator checks — no copies.
    private func windowExists(_ scan: Scan, at index: Int, count: Int) -> Bool {
        index + count <= scan.words.count && Self.gapsAreJoinable(scan, from: index, count: count)
    }

    /// The fuzzy rule, stated plainly:
    ///
    /// - the **consonant skeleton must be identical** (after folding accents and collapsing
    ///   doubled letters). "Martina" and "Martino" are both `mrtn`; "marina" is `mrn`, so a
    ///   genuinely different word is rejected before any distance is computed;
    /// - the vowel sequences must have the **same length** and differ in **at most one**
    ///   position — a dropped or added syllable is a different word;
    /// - the one differing vowel pair must be **confusable**: any two of `a e o`, or `i`/`y`.
    ///   This is the actual failure mode being fixed. An unstressed final mid/low vowel is
    ///   what the model flips ("Martino" → "Martina"); `/i/` and `/u/` are high vowels and
    ///   perceptually distinct, which is exactly why "Martini" (the drink) survives untouched
    ///   even with "Martino" in the vocabulary;
    /// - in a multi-word phrase **at most one word may be fuzzy**; the rest must match exactly.
    ///
    /// A zero-vowel-difference match is still possible and means the words differ only by a
    /// doubled letter ("Dictarri" → "Dictari").
    private func fuzzyMatches(
        _ scan: Scan, at index: Int, pattern: Pattern, skeletons: [String], vowelSeqs: [String]
    ) -> Bool {
        var fuzzyWords = 0
        for i in 0..<pattern.wordCount {
            let word = scan.normalized[index + i]
            if word == pattern.words[i] { continue }
            fuzzyWords += 1
            guard fuzzyWords <= 1 else { return false }
            guard word.count >= Rules.minimumFuzzyLength else { return false }
            guard skeletons[index + i] == pattern.skeletons[i] else { return false }

            let a = Array(vowelSeqs[index + i])
            let b = Array(pattern.vowelSeqs[i])
            guard a.count == b.count else { return false }

            var differing: (Character, Character)?
            for (x, y) in zip(a, b) where x != y {
                if differing != nil { return false }   // more than one vowel differs
                differing = (x, y)
            }
            if let (x, y) = differing, !Rules.confusable(x, y) { return false }
        }
        return true
    }

    // MARK: Casing

    /// Keeps the transcript's own casing intent rather than stamping the stored spelling on
    /// it: SHOUTING stays shouting, a sentence-initial capital stays capitalised, and a
    /// proper name stored as "Martino" capitalises itself even when dictated mid-sentence.
    private func cased(_ replacement: String, like scan: Scan, from index: Int, count: Int) -> String {
        let original = Self.join(scan, from: index, count: count)
        let letters = original.filter(\.isLetter)

        if letters.count > 1, letters.allSatisfy(\.isUppercase) {
            return replacement.uppercased()
        }
        if let first = original.first, first.isUppercase,
           let head = replacement.first, head.isLowercase {
            return head.uppercased() + replacement.dropFirst()
        }
        return replacement
    }

    // MARK: - Scanning

    /// A transcript split into words and the verbatim text between them.
    /// `separators.count == words.count + 1`, so the original string is
    /// `separators[0] + words[0] + separators[1] + …` — punctuation and spacing round-trip
    /// exactly, which is why "Martina." keeps its full stop and "«Martina»" its quotes.
    private struct Scan {
        var words: [String] = []
        var normalized: [String] = []
        var separators: [String] = []
        /// Each word's range in the scanned text. Filled only when confidence is being
        /// tracked, so the plain path pays nothing for it.
        var ranges: [Range<String.Index>] = []
    }

    private static func split(_ text: String, recordingRanges: Bool = false) -> Scan {
        var scan = Scan()
        var word = ""
        var separator = ""
        var wordStart = text.startIndex

        var position = text.startIndex
        while position < text.endIndex {
            let ch = text[position]
            let next = text.index(after: position)
            defer { position = next }
            // Apostrophes are separators, not word characters: it makes "Martina's" match
            // "Martina" and hand back "Martino's" with the possessive intact.
            if ch.isLetter || ch.isNumber {
                if word.isEmpty {
                    scan.separators.append(separator)
                    separator = ""
                    wordStart = position
                }
                word.append(ch)
            } else {
                if !word.isEmpty {
                    scan.words.append(word)
                    scan.normalized.append(normalize(word))
                    if recordingRanges { scan.ranges.append(wordStart..<position) }
                    word = ""
                }
                separator.append(ch)
            }
        }
        if !word.isEmpty {
            scan.words.append(word)
            scan.normalized.append(normalize(word))
            if recordingRanges { scan.ranges.append(wordStart..<text.endIndex) }
        }
        scan.separators.append(separator)
        return scan
    }

    /// The words of a phrase, using the same rules as `split`.
    private static func words(in text: String) -> [String] {
        split(text).words
    }

    /// Only a single space or hyphen may sit between the words of a matched phrase, so
    /// "custom vocabulary" does not match across a full stop or a line break.
    private static func gapsAreJoinable(_ scan: Scan, from index: Int, count: Int) -> Bool {
        guard count > 1 else { return true }
        for k in 1..<count {
            let gap = scan.separators[index + k]
            guard gap == " " || gap == "-" else { return false }
        }
        return true
    }

    /// The original text of a window, separators included.
    private static func join(_ scan: Scan, from index: Int, count: Int) -> String {
        var out = scan.words[index]
        guard count > 1 else { return out }
        for k in 1..<count {
            out += scan.separators[index + k] + scan.words[index + k]
        }
        return out
    }

    // MARK: - Normalisation primitives

    private static let posix = Locale(identifier: "en_US_POSIX")

    /// Lowercase, accent-free form used for every comparison.
    static func normalize(_ word: String) -> String {
        word.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: posix)
    }

    /// Consonants only, with runs of the same letter collapsed. Doubled consonants are a
    /// spelling difference, not a different word ("Dictarri" / "Dictari").
    static func skeleton(_ normalized: String) -> String {
        var out = ""
        for ch in normalized where !Rules.vowels.contains(ch) {
            if out.last != ch { out.append(ch) }
        }
        return out
    }

    /// The vowels of a word, in order.
    static func vowels(_ normalized: String) -> String {
        String(normalized.filter { Rules.vowels.contains($0) })
    }

    /// Sound-class key and vowels of a normalised word, for the loose (uncertain-only) pass.
    ///
    /// Letters that spell the same consonant sound across Italian, English and German map to
    /// one symbol, then runs collapse exactly like `skeleton` does:
    /// `c k q ch ck → k`, `gh → g`, `z ts tz → z`, `v w → v`, `f ph → f`,
    /// `sh sch sce/sci → ʃ`, `gn ny → ɲ`, `x → ks`, `ß → s`, and `h` elsewhere is silent.
    /// German `ch` is really /x/, not /k/; mapping it to `k` only ever matters for a word the
    /// engine was unsure of *and* that lines up with a term the user wrote down.
    ///
    /// The classes live in `SoundClasses`, shared with the history scan. This pass reads only
    /// the `.base` rules: the scan's extra readings (soft c/g, th, vowel digraphs) are fine
    /// for proposing a spelling to the user and too loose for rewriting dictated text.
    /// `SoundClassesTests` pins this output to the original, pre-extraction encoder.
    static func phonetic(_ normalized: String) -> (key: String, vowels: String) {
        var key = ""
        var vowels = ""
        for symbol in SoundClasses.sounds(normalized, rules: .base) {
            if SoundClasses.vowels.contains(symbol) {
                vowels.append(symbol)
            } else if key.last != symbol {
                key.append(symbol)
            }
        }
        return (key, vowels)
    }

    /// Whether two short strings are at most one insertion, deletion or substitution apart.
    static func withinOneEdit(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let x = Array(a), y = Array(b)
        guard abs(x.count - y.count) <= 1 else { return false }
        var i = 0, j = 0, edits = 0
        while i < x.count, j < y.count {
            if x[i] == y[j] { i += 1; j += 1; continue }
            edits += 1
            if edits > 1 { return false }
            if x.count > y.count { i += 1 } else if y.count > x.count { j += 1 } else { i += 1; j += 1 }
        }
        return edits + (x.count - i) + (y.count - j) <= 1
    }

    // MARK: - Rules

    private enum Rules {
        static let vowels: Set<Character> = ["a", "e", "i", "o", "u", "y"]

        /// Short words carry too little signal: at three letters a single vowel swap turns
        /// one real word into another ("ban" / "bon"). Below this length, only exact and
        /// explicit-alternative matches apply.
        static let minimumFuzzyLength = 4

        /// The loose pass needs at least this many consonant classes in the key. Two-class
        /// keys ("dr": dura, dire, Dora, odore) are shared by too many ordinary words.
        static let minimumLooseKeyLength = 3

        /// Vowels the model actually swaps for one another. `a e o` are mid/low and collapse
        /// in unstressed position; `i`/`y` are only ever a spelling choice. Anything else —
        /// notably `i` against `a`/`o` — is treated as a real distinction.
        private static let classes: [Set<Character>] = [["a", "e", "o"], ["i", "y"]]

        static func confusable(_ a: Character, _ b: Character) -> Bool {
            classes.contains { $0.contains(a) && $0.contains(b) }
        }
    }
}

// MARK: - Inference-time biasing

/// Builds the conditioning prompt for engines that accept one.
///
/// **WhisperKit does.** `DecodingOptions` exposes `promptTokens: [Int]?`, and
/// `TextDecoder.prefillDecoderInputs` prepends `<|startofprev|>` itself, so a caller passes
/// plain encoded text:
///
/// ```swift
/// options.promptTokens = pipe.tokenizer?.encode(text: " " + promptText)
/// ```
///
/// Two caveats for whoever wires it in: WhisperKit disables its prefill KV-cache whenever
/// `promptTokens != nil` (an acknowledged TODO in `TextDecoder.swift`), which costs some
/// latency on the transcription path; and a prompt only *tilts* the decoder — it is not a
/// guarantee, which is why `VocabularyCorrector` runs regardless.
///
/// **FluidAudio does not**, on the path Dictari uses. `AsrManager.transcribe` (v0.15.5) takes
/// only samples, decoder state and a language hint. Context biasing exists in the package but
/// hangs off `SlidingWindowAsrManager.configureVocabularyBoosting(vocabulary:ctcModels:)` —
/// the streaming manager, and it additionally requires a separate CTC model download. Nothing
/// on the batch manager accepts a vocabulary. Parakeet therefore relies on the corrector.
enum VocabularyPrompt {

    /// A comma-separated prompt naming the enabled terms, or nil when there is nothing to say.
    /// Whisper prompts behave best as short natural text, so the list is capped rather than
    /// letting a long vocabulary eat the decoder's context (and its latency budget).
    static func promptText(for terms: [VocabularyTerm], maxCharacters: Int = 180) -> String? {
        var kept: [String] = []
        var length = 0
        for term in terms where term.enabled {
            let text = term.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let cost = text.count + (kept.isEmpty ? 0 : 2)
            guard length + cost <= maxCharacters else { break }
            kept.append(text)
            length += cost
        }
        guard !kept.isEmpty else { return nil }
        return kept.joined(separator: ", ") + "."
    }
}
