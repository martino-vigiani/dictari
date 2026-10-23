// TranscriptConfidence.swift
// Dictari — per-word confidence carried from the engine to History.
//
// Engines report how sure they were of each word; the vocabulary corrector uses that to allow
// a looser match *only* where the model itself was unsure, and History keeps the unsure spans
// so a UI can point at them. Everything here is pure, synchronous and allocation-light: it runs
// on the stop→inject path.
//
// Kept free of engine and UI imports so the host-less test bundle can build it without
// WhisperKit/FluidAudio.

import Foundation

/// One word as the engine produced it. `text` is the engine's own spelling, possibly with
/// punctuation attached ("ciao,"). `confidence` is 0...1, or nil when the engine gave no score.
struct TranscribedWord: Equatable, Sendable {
    var text: String
    var confidence: Float?

    init(text: String, confidence: Float? = nil) {
        self.text = text
        self.confidence = confidence
    }
}

/// The detailed result of one inference: the exact text `transcribe` returns, plus the words it
/// was built from. `words` is advisory — consumers align it to `text` and skip what they cannot
/// find, so an engine whose tokens do not round-trip to its text still degrades safely.
struct TranscriptionOutput: Equatable, Sendable {
    var text: String
    var words: [TranscribedWord]

    init(text: String, words: [TranscribedWord]) {
        self.text = text
        self.words = words
    }

    /// Text with no scores: whitespace-separated words, each with a nil confidence.
    static func unscored(_ text: String) -> TranscriptionOutput {
        TranscriptionOutput(
            text: text,
            words: text.split(whereSeparator: \.isWhitespace).map { TranscribedWord(text: String($0)) }
        )
    }

    /// Whether any word carries a score. `false` means "no information", not "all confident".
    var hasConfidence: Bool { words.contains { $0.confidence != nil } }

    /// Stitches phrases decoded separately. The text is exactly
    /// `parts.map(\.text).joined(separator: " ")` — the rule the phrase stitching always used —
    /// so carrying words through changes nothing about what gets inserted.
    static func joined(_ parts: [TranscriptionOutput]) -> TranscriptionOutput {
        TranscriptionOutput(
            text: parts.map(\.text).joined(separator: " "),
            words: parts.flatMap(\.words)
        )
    }
}

/// A word below the confidence threshold, spelled as it reads in the text it was located in.
struct UncertainWord: Equatable, Sendable {
    let text: String
    let confidence: Float
}

/// An unsure stretch of a History entry's text, in UTF-16 units (NSRange-compatible, which is
/// what AppKit/SwiftUI attributed text wants). Offsets index the entry's final `text`.
struct UncertainSpan: Codable, Equatable, Sendable {
    var location: Int
    var length: Int
    var confidence: Float

    /// Finds each word, in order, in `text` and returns its UTF-16 span. Words that cannot be
    /// found (formatting may have rewritten them) are skipped rather than guessed at.
    /// Case-insensitive because delivery formatting may capitalise the first letter.
    static func locate(_ words: [UncertainWord], in text: String) -> [UncertainSpan] {
        guard !words.isEmpty, !text.isEmpty else { return [] }
        var spans: [UncertainSpan] = []
        var cursor = text.startIndex
        // UTF-16 distances are computed incrementally from the previous hit, so the whole pass
        // stays linear in the text instead of re-walking it from the start for every word.
        var measuredIndex = text.startIndex
        var measuredOffset = 0
        for word in words {
            guard let range = TranscriptConfidence.findWord(
                Substring(word.text), in: text, from: cursor, options: [.caseInsensitive]
            ) else { continue }
            measuredOffset += text.utf16.distance(from: measuredIndex, to: range.lowerBound)
            measuredIndex = range.lowerBound
            let length = text.utf16.distance(from: range.lowerBound, to: range.upperBound)
            spans.append(UncertainSpan(location: measuredOffset, length: length,
                                       confidence: word.confidence))
            cursor = range.upperBound
        }
        return spans
    }
}

enum TranscriptConfidence {

    /// Below this a word counts as uncertain.
    ///
    /// Parakeet's per-token confidence is the softmax probability of the emitted token, and a
    /// word takes its weakest sub-token. Measured on Parakeet v3 with `say` fixtures (it/de/en,
    /// September 2026): ordinary words that were transcribed correctly scored 0.82–1.00, with
    /// one exception (a bare "e" at 0.62). The words it got *wrong* scored 0.48–0.60:
    /// "Dictari" → "Diktar" 0.49, "kubectl" → "Kubek" 0.60 / "tu" 0.51, "Terraform" →
    /// "terra" 0.57 / "forma" 0.48. Correct-but-unfamiliar names landed low too ("Siobhan"
    /// 0.43, "Jira" 0.22) — rightly flagged, and harmless: the loose match needs a vocabulary
    /// term that sounds the same.
    ///
    /// 0.6 is the top of that error band and still below every correctly heard word of four
    /// letters or more (the loose pass's minimum length). Lower (0.5) would have missed half
    /// the mishearings above; higher (0.7+) starts reaching into correctly heard words for no
    /// measured gain. For Whisper the value is compared against exp(avgLogprob), i.e.
    /// avgLogprob < -0.51, inside the range Whisper's own decoder treats as a weak segment.
    static let uncertainThreshold: Float = 0.6

    /// Whisper reports a mean log-probability per segment; its exponential is the geometric
    /// mean token probability, which lives on the same 0...1 scale as Parakeet's scores.
    static func confidence(fromAverageLogProbability logprob: Float) -> Float? {
        guard logprob.isFinite else { return nil }
        return min(max(Float(exp(Double(logprob))), 0), 1)
    }

    /// The word without leading/trailing punctuation: "«Kubernetes»," → "Kubernetes".
    static func core(of word: String) -> Substring {
        let isWordChar: (Character) -> Bool = { $0.isLetter || $0.isNumber }
        guard let first = word.firstIndex(where: isWordChar),
              let last = word.lastIndex(where: isWordChar) else { return "" }
        return word[first...last]
    }

    /// Places each word's core in `text`, in order. A word that cannot be found gets nil and
    /// does not move the cursor, so one mismatch never shifts every later word.
    static func align(_ words: [TranscribedWord], in text: String) -> [Range<String.Index>?] {
        var cursor = text.startIndex
        var result: [Range<String.Index>?] = []
        result.reserveCapacity(words.count)
        for word in words {
            let core = core(of: word.text)
            guard !core.isEmpty,
                  let range = findWord(core, in: text, from: cursor, options: [.literal]) else {
                result.append(nil)
                continue
            }
            result.append(range)
            cursor = range.upperBound
        }
        return result
    }

    /// First whole-word occurrence of `needle` at or after `start`: a hit inside a longer word
    /// ("a" inside "casa") would misplace every word after it, so it is skipped.
    static func findWord(
        _ needle: Substring, in text: String, from start: String.Index,
        options: String.CompareOptions
    ) -> Range<String.Index>? {
        guard !needle.isEmpty else { return nil }
        var from = start
        while from < text.endIndex,
              let hit = text.range(of: needle, options: options, range: from..<text.endIndex) {
            let beforeOK = hit.lowerBound == text.startIndex
                || !isWordCharacter(text[text.index(before: hit.lowerBound)])
            let afterOK = hit.upperBound == text.endIndex || !isWordCharacter(text[hit.upperBound])
            if beforeOK && afterOK { return hit }
            from = text.index(after: hit.lowerBound)
        }
        return nil
    }

    private static func isWordCharacter(_ ch: Character) -> Bool {
        ch.isLetter || ch.isNumber
    }
}
