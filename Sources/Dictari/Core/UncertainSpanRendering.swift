// UncertainSpanRendering.swift
// Dictari — turns stored `UncertainSpan`s into safe string ranges and underlined text.
//
// Spans are UTF-16 offsets persisted in history.json, so they are untrusted input: an older
// build, a hand-edited file or a text that changed after the spans were computed can all
// produce offsets past the end, negative lengths, overlaps, or a boundary inside a surrogate
// pair or a composed character. Everything here clamps, drops or widens instead of trapping —
// a History row must never crash because of stale confidence data.

import Foundation
import SwiftUI

enum UncertainSpanRendering {

    /// Character-aligned, sorted, non-overlapping ranges of `text` covered by `spans`.
    ///
    /// Out-of-range spans are clamped to the text (or dropped when they start past it), and a
    /// boundary that falls inside a grapheme (half an emoji, a base letter without its
    /// combining accent) widens outward to the whole character so no range ever splits one.
    static func ranges(in text: String, spans: [UncertainSpan]?) -> [Range<String.Index>] {
        guard let spans, !spans.isEmpty, !text.isEmpty else { return [] }
        let utf16 = text.utf16
        let count = utf16.count
        var offsets: [(lower: Int, upper: Int)] = []
        offsets.reserveCapacity(spans.count)
        for span in spans {
            guard span.location >= 0, span.length > 0, span.location < count else { continue }
            let (end, overflow) = span.location.addingReportingOverflow(span.length)
            offsets.append((span.location, overflow ? count : min(end, count)))
        }
        guard !offsets.isEmpty else { return [] }
        offsets.sort { $0.lower < $1.lower || ($0.lower == $1.lower && $0.upper < $1.upper) }

        // Offsets are sorted, so one forward walk converts them all: linear in the text rather
        // than re-walking it from the start for every span.
        var cursor = utf16.startIndex
        var cursorOffset = 0
        func index(at offset: Int) -> String.Index {
            if offset < cursorOffset {
                cursor = utf16.startIndex
                cursorOffset = 0
            }
            cursor = utf16.index(cursor, offsetBy: offset - cursorOffset)
            cursorOffset = offset
            return cursor
        }

        var result: [Range<String.Index>] = []
        for (lowerOffset, upperOffset) in offsets {
            var lower = index(at: lowerOffset)
            var upper = index(at: upperOffset)
            while lower > text.startIndex, lower.samePosition(in: text) == nil {
                lower = utf16.index(before: lower)
            }
            while upper < text.endIndex, upper.samePosition(in: text) == nil {
                upper = utf16.index(after: upper)
            }
            guard lower < upper else { continue }
            if let last = result.last, lower < last.upperBound {
                result[result.count - 1] = last.lowerBound..<max(last.upperBound, upper)
            } else {
                result.append(lower..<upper)
            }
        }
        return result
    }

    /// `text` with each uncertain range carrying a dotted underline in `color`. Only the
    /// underline is set, so the caller's font and foreground style still apply to every run.
    static func attributed(text: String, spans: [UncertainSpan]?, underline color: Color) -> AttributedString {
        var attributed = AttributedString(text)
        for range in ranges(in: text, spans: spans) {
            guard let target = Range<AttributedString.Index>(range, in: attributed) else { continue }
            attributed[target].swiftUI.underlineStyle = Text.LineStyle(pattern: .dot, color: color)
        }
        return attributed
    }

    /// The same word in `draft` as `range` covers in `original`: its nth whole-word occurrence
    /// when the draft still has as many, otherwise the first. nil when the draft no longer
    /// contains the word at all (the user already rewrote it).
    static func matchingRange(
        of range: Range<String.Index>, in original: String, draft: String
    ) -> Range<String.Index>? {
        guard range.lowerBound >= original.startIndex, range.upperBound <= original.endIndex,
              !range.isEmpty else { return nil }
        let word = original[range]
        var occurrence = 0
        var cursor = original.startIndex
        while let hit = TranscriptConfidence.findWord(word, in: original, from: cursor, options: [.literal]),
              hit.lowerBound < range.lowerBound {
            occurrence += 1
            cursor = hit.upperBound
        }
        var first: Range<String.Index>?
        var seen = 0
        cursor = draft.startIndex
        while let hit = TranscriptConfidence.findWord(word, in: draft, from: cursor, options: [.literal]) {
            if seen == occurrence { return hit }
            if first == nil { first = hit }
            seen += 1
            cursor = hit.upperBound
        }
        return first
    }
}

extension HistoryEntry {
    /// Spans for what History *displays*: nil when a correction is shown, because spans index
    /// the original `text` and would underline the wrong characters of the edited one.
    var displayedUncertainSpans: [UncertainSpan]? {
        displayText == text ? uncertainSpans : nil
    }

    /// Number of distinct uncertain stretches in the original text (after dropping bad data).
    var uncertainWordCount: Int {
        UncertainSpanRendering.ranges(in: text, spans: uncertainSpans).count
    }
}

/// The spans of one specific transcript. The pill checks `text` against what it is about to
/// show, so spans can never be painted onto a different (revised, recovered, cleared) text.
struct UncertainTranscript: Equatable, Sendable {
    let text: String
    let spans: [UncertainSpan]

    func spans(for shown: String) -> [UncertainSpan]? {
        shown == text ? spans : nil
    }
}
