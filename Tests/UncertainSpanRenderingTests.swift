// UncertainSpanRenderingTests.swift
// Dictari — stored UTF-16 spans become safe, character-aligned ranges.
//
// Spans come from history.json, so they are treated as untrusted: every malformed case here
// must produce a sensible range or nothing, never a trap.

import SwiftUI
import XCTest

final class UncertainSpanRenderingTests: XCTestCase {

    private func span(_ location: Int, _ length: Int) -> UncertainSpan {
        UncertainSpan(location: location, length: length, confidence: 0.4)
    }

    private func words(_ text: String, _ spans: [UncertainSpan]?) -> [String] {
        UncertainSpanRendering.ranges(in: text, spans: spans).map { String(text[$0]) }
    }

    // MARK: - Ranges

    func testRoundTripsSpansProducedByLocate() {
        let text = "Uso Kubek ogni giorno con Diktar."
        let spans = UncertainSpan.locate(
            [UncertainWord(text: "Kubek", confidence: 0.6), UncertainWord(text: "Diktar", confidence: 0.49)],
            in: text
        )
        XCTAssertEqual(words(text, spans), ["Kubek", "Diktar"])
    }

    func testNilOrEmptyInputHasNoRanges() {
        XCTAssertTrue(words("ciao", nil).isEmpty)
        XCTAssertTrue(words("ciao", []).isEmpty)
        XCTAssertTrue(words("", [span(0, 3)]).isEmpty)
    }

    func testAccentsAndEmojiBeforeASpanShiftUTF16OffsetsCorrectly() {
        // "é" is one UTF-16 unit, "👍" two: offsets are UTF-16, not Characters.
        let text = "Perché 👍 Diktar funziona"
        let spans = UncertainSpan.locate([UncertainWord(text: "Diktar", confidence: 0.4)], in: text)
        XCTAssertEqual(spans.first?.location, 10)
        XCTAssertEqual(words(text, spans), ["Diktar"])
    }

    func testDecomposedAccentIsNeverSplitFromItsBaseLetter() {
        // "e" + COMBINING ACUTE ACCENT is one Character but two UTF-16 units.
        let text = "caffe\u{301} buono"
        XCTAssertEqual(words(text, [span(0, 5)]), ["caffe\u{301}"])
    }

    func testSpanInsideASurrogatePairWidensToTheWholeEmoji() {
        let text = "a 👍 b"                        // 👍 occupies UTF-16 offsets 2 and 3
        XCTAssertEqual(words(text, [span(3, 1)]), ["👍"])
        XCTAssertEqual(words(text, [span(2, 1)]), ["👍"])
        let family = "x 👨‍👩‍👧 y"                  // a multi-scalar grapheme
        XCTAssertEqual(words(family, [span(4, 2)]), ["👨‍👩‍👧"])
    }

    func testOutOfRangeSpansAreClampedOrDropped() {
        let text = "ciao mondo"                     // 10 UTF-16 units
        XCTAssertEqual(words(text, [span(5, 99)]), ["mondo"])
        XCTAssertEqual(words(text, [span(5, Int.max)]), ["mondo"])
        XCTAssertTrue(words(text, [span(10, 1)]).isEmpty)
        XCTAssertTrue(words(text, [span(42, 3)]).isEmpty)
        XCTAssertTrue(words(text, [span(-1, 3)]).isEmpty)
        XCTAssertTrue(words(text, [span(Int.min, 3)]).isEmpty)
        XCTAssertTrue(words(text, [span(2, 0)]).isEmpty)
        XCTAssertTrue(words(text, [span(2, -4)]).isEmpty)
    }

    func testOverlappingAndUnsortedSpansMergeIntoSortedDisjointRanges() {
        let text = "uno due tre quattro"
        let ranges = UncertainSpanRendering.ranges(in: text, spans: [
            span(12, 7), span(4, 3), span(5, 5), span(4, 3)
        ])
        XCTAssertEqual(ranges.map { String(text[$0]) }, ["due tr", "quattro"])
        for (a, b) in zip(ranges, ranges.dropFirst()) {
            XCTAssertLessThanOrEqual(a.upperBound, b.lowerBound)
        }
    }

    func testStaleSpansForADifferentTextNeverTrap() {
        // Spans computed for a longer text, applied to a shorter one (e.g. a truncated preview).
        let full = "Uso Kubek ogni giorno con Diktar."
        let spans = UncertainSpan.locate(
            [UncertainWord(text: "Kubek", confidence: 0.5), UncertainWord(text: "Diktar", confidence: 0.5)],
            in: full
        )
        XCTAssertEqual(words(String(full.prefix(12)), spans), ["Kubek"])
        XCTAssertEqual(words("🎉🎉", spans).count, 0)
    }

    // MARK: - Attributed output

    func testAttributedStringUnderlinesOnlyTheUncertainRuns() {
        let text = "Perché 👍 Diktar funziona"
        let spans = UncertainSpan.locate([UncertainWord(text: "Diktar", confidence: 0.4)], in: text)
        let attributed = UncertainSpanRendering.attributed(text: text, spans: spans, underline: .gray)
        XCTAssertEqual(String(attributed.characters), text)
        let underlined = attributed.runs
            .filter { $0.swiftUI.underlineStyle != nil }
            .map { String(attributed[$0.range].characters) }
        XCTAssertEqual(underlined, ["Diktar"])
    }

    func testAttributedStringWithGarbageSpansIsJustTheText() {
        let attributed = UncertainSpanRendering.attributed(
            text: "ciao", spans: [span(-3, 2), span(40, 1)], underline: .gray
        )
        XCTAssertEqual(String(attributed.characters), "ciao")
        XCTAssertTrue(attributed.runs.allSatisfy { $0.swiftUI.underlineStyle == nil })
    }

    // MARK: - Correction sheet word matching

    func testMatchingRangePicksTheSameOccurrenceInTheDraft() {
        let original = "Diktar apre Diktar"
        let ranges = UncertainSpanRendering.ranges(in: original, spans: [span(12, 6)])
        let draft = "Ora Diktar apre Diktar"
        let match = UncertainSpanRendering.matchingRange(of: ranges[0], in: original, draft: draft)
        XCTAssertEqual(match.map { draft.distance(from: draft.startIndex, to: $0.lowerBound) }, 16)
    }

    func testMatchingRangeFallsBackToFirstOccurrenceAndNilWhenGone() {
        let original = "Diktar apre Diktar"
        let second = UncertainSpanRendering.ranges(in: original, spans: [span(12, 6)])[0]
        let draft = "Diktar funziona"
        let match = UncertainSpanRendering.matchingRange(of: second, in: original, draft: draft)
        XCTAssertEqual(match.map { String(draft[$0]) }, "Diktar")
        XCTAssertNil(UncertainSpanRendering.matchingRange(of: second, in: original, draft: "Dictari apre"))
    }

    // MARK: - History and pill helpers

    func testDisplayedSpansAreHiddenWhileACorrectionIsShown() {
        var entry = HistoryEntry(date: .now, text: "Uso Kubek", durationSeconds: 1, wordCount: 2,
                                 latencyMs: 0, uncertainSpans: [span(4, 5)])
        XCTAssertEqual(entry.displayedUncertainSpans, [span(4, 5)])
        XCTAssertEqual(entry.uncertainWordCount, 1)
        entry.correctedText = "Uso kubectl"
        XCTAssertNil(entry.displayedUncertainSpans)
        entry.correctedText = "   "                  // whitespace-only correction shows the original
        XCTAssertEqual(entry.displayedUncertainSpans, [span(4, 5)])
        entry.uncertainSpans = [span(90, 2)]
        XCTAssertEqual(entry.uncertainWordCount, 0)
    }

    func testPillSpansApplyOnlyToTheTranscriptTheyWereComputedFor() {
        let uncertainty = UncertainTranscript(text: "Uso Kubek", spans: [span(4, 5)])
        XCTAssertEqual(uncertainty.spans(for: "Uso Kubek"), [span(4, 5)])
        XCTAssertNil(uncertainty.spans(for: "Uso kubectl, rivisto"))
    }
}
