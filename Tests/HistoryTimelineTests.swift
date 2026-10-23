import Foundation
import XCTest

final class HistoryTimelineTests: XCTestCase {
    private let origin = Date(timeIntervalSinceReferenceDate: 10_000)

    func testMergeInterleavesHistoryAndStandaloneRecoveriesNewestFirst() {
        let newestRecovery = recovery(
            id: id(1),
            seconds: 30,
            transcript: "unmatched recovery",
            appName: "Notes",
            bundleID: "com.apple.Notes"
        )
        let middleHistory = history(id: id(2), seconds: 20, text: "middle")
        let oldestHistory = history(id: id(3), seconds: 10, text: "oldest")

        let timeline = HistoryTimeline.merge(
            history: [oldestHistory, middleHistory],
            recoveries: [newestRecovery]
        )

        XCTAssertEqual(timeline.map(\.id), [
            .recovery(newestRecovery.id),
            .history(middleHistory.id),
            .history(oldestHistory.id)
        ])
    }

    func testExactSessionMatchCollapsesRecoveryOntoHistoryItem() throws {
        let entry = history(
            id: id(10),
            seconds: 20,
            text: "Ship the release",
            appName: "Xcode",
            bundleID: "com.apple.dt.Xcode"
        )
        let saved = recovery(
            id: id(11),
            seconds: 20,
            transcript: "Ship the release",
            appName: "Xcode",
            bundleID: "com.apple.dt.Xcode"
        )

        let item = try XCTUnwrap(HistoryTimeline.merge(history: [entry], recoveries: [saved]).only)

        XCTAssertEqual(item.id, .history(entry.id))
        XCTAssertEqual(item.history, entry)
        XCTAssertEqual(item.recovery, saved)
    }

    /// Regression: observed persisted pairs can differ by just over five seconds, so the merge
    /// window must not regress to the speculative two-second threshold.
    func testFiveSecondSessionSkewStillCollapsesMatchingRecovery() throws {
        let entry = history(
            id: id(20),
            seconds: 40,
            text: "Five second match",
            appName: "Safari",
            bundleID: "com.apple.Safari"
        )
        let saved = recovery(
            id: id(21),
            seconds: 45,
            transcript: entry.text,
            appName: entry.appName,
            bundleID: entry.appBundleID
        )

        let item = try XCTUnwrap(HistoryTimeline.merge(history: [entry], recoveries: [saved]).only)

        XCTAssertEqual(item.id, .history(entry.id))
        XCTAssertEqual(item.recovery?.id, saved.id)
    }

    func testMatchingTextAndAppBeyondTenSecondsRemainSeparate() {
        let entry = history(
            id: id(30),
            seconds: 20,
            text: "Same words",
            appName: "Mail",
            bundleID: "com.apple.mail"
        )
        let saved = recovery(
            id: id(31),
            seconds: 30.001,
            transcript: entry.text,
            appName: entry.appName,
            bundleID: entry.appBundleID
        )

        let timeline = HistoryTimeline.merge(history: [entry], recoveries: [saved])

        XCTAssertEqual(Set(timeline.map(\.id)), [.history(entry.id), .recovery(saved.id)])
        XCTAssertEqual(timeline.count, 2)
    }

    func testDifferentTranscriptDoesNotMatchAtTheSameTimeAndApp() {
        let entry = history(
            id: id(40),
            seconds: 20,
            text: "First dictation",
            appName: "Mail",
            bundleID: "com.apple.mail"
        )
        let saved = recovery(
            id: id(41),
            seconds: 20,
            transcript: "Different dictation",
            appName: entry.appName,
            bundleID: entry.appBundleID
        )

        let timeline = HistoryTimeline.merge(history: [entry], recoveries: [saved])

        XCTAssertEqual(timeline.count, 2)
        XCTAssertEqual(Set(timeline.map(\.id)), [.history(entry.id), .recovery(saved.id)])
    }

    func testDifferentApplicationDoesNotMatchAtTheSameTimeAndText() {
        let entry = history(
            id: id(50),
            seconds: 20,
            text: "Same dictation",
            appName: "Mail",
            bundleID: "com.apple.mail"
        )
        let saved = recovery(
            id: id(51),
            seconds: 20,
            transcript: entry.text,
            appName: "Notes",
            bundleID: "com.apple.Notes"
        )

        let timeline = HistoryTimeline.merge(history: [entry], recoveries: [saved])

        XCTAssertEqual(timeline.count, 2)
        XCTAssertEqual(Set(timeline.map(\.id)), [.history(entry.id), .recovery(saved.id)])
    }

    func testTranscriptlessRecoveriesMatchOnlyTheirCompatibleFailureKinds() throws {
        let cases: [(description: String, tag: String, number: Int)] = [
            ("No speech detected", "no speech", 60),
            ("No audio captured", "no audio", 70),
            ("Voice was too quiet", "too far", 80),
            ("The model stopped responding", "failed", 90)
        ]
        let entries = cases.map {
            history(
                id: id($0.number),
                seconds: Double($0.number),
                text: "",
                appName: "Dictari",
                bundleID: "com.subralabs.Dictari",
                tag: $0.tag
            )
        }
        let recoveries = cases.map {
            recovery(
                id: id($0.number + 1),
                seconds: Double($0.number + 3),
                state: .transcriptionFailed,
                failureDescription: $0.description,
                transcript: nil,
                appName: "Dictari",
                bundleID: "com.subralabs.Dictari"
            )
        }

        let timeline = HistoryTimeline.merge(history: entries, recoveries: recoveries)

        XCTAssertEqual(timeline.count, cases.count)
        for (entry, saved) in zip(entries, recoveries) {
            let item = try XCTUnwrap(timeline.first { $0.id == .history(entry.id) })
            XCTAssertEqual(item.recovery?.id, saved.id, "Failure tag \(entry.tag ?? "nil")")
        }
    }

    /// Regression: proximity alone must not hide an independently recoverable failure behind a
    /// history row that describes a different failure mode.
    func testNearbyTranscriptlessRecoveryWithWrongFailureTagRemainsStandalone() {
        let entry = history(
            id: id(100),
            seconds: 20,
            text: "",
            appName: "Dictari",
            bundleID: "com.subralabs.Dictari",
            tag: "no speech"
        )
        let saved = recovery(
            id: id(101),
            seconds: 21,
            state: .transcriptionFailed,
            failureDescription: "No audio captured",
            transcript: nil,
            appName: entry.appName,
            bundleID: entry.appBundleID
        )

        let timeline = HistoryTimeline.merge(history: [entry], recoveries: [saved])

        XCTAssertEqual(timeline.count, 2)
        XCTAssertEqual(Set(timeline.map(\.id)), [.history(entry.id), .recovery(saved.id)])
    }

    func testTranscriptlessFailureDoesNotCollapseOntoSuccessfulHistory() {
        let entry = history(
            id: id(110),
            seconds: 20,
            text: "Successful transcription",
            appName: "Notes",
            bundleID: "com.apple.Notes",
            tag: nil
        )
        let saved = recovery(
            id: id(111),
            seconds: 21,
            state: .transcriptionFailed,
            failureDescription: "The model stopped responding",
            transcript: nil,
            appName: entry.appName,
            bundleID: entry.appBundleID
        )

        let timeline = HistoryTimeline.merge(history: [entry], recoveries: [saved])

        XCTAssertEqual(timeline.count, 2)
        XCTAssertEqual(Set(timeline.map(\.id)), [.history(entry.id), .recovery(saved.id)])
    }

    func testUnmatchedRecoveryRemainsAStandaloneTimelineItem() throws {
        let saved = recovery(
            id: id(120),
            seconds: 20,
            transcript: "Recover me",
            appName: "Notes",
            bundleID: "com.apple.Notes"
        )

        let item = try XCTUnwrap(HistoryTimeline.merge(history: [], recoveries: [saved]).only)

        XCTAssertEqual(item.id, .recovery(saved.id))
        XCTAssertNil(item.history)
        XCTAssertEqual(item.recovery, saved)
    }

    func testSearchFilteredInputsAreStillSortedNewestFirst() {
        let olderHistory = history(id: id(130), seconds: 10, text: "needle old")
        let newestHistory = history(id: id(131), seconds: 30, text: "needle new")
        let middleRecovery = recovery(
            id: id(132),
            seconds: 20,
            transcript: "needle recovery",
            appName: "Safari",
            bundleID: "com.apple.Safari"
        )

        let timeline = HistoryTimeline.merge(
            history: [olderHistory, newestHistory],
            recoveries: [middleRecovery]
        )

        XCTAssertEqual(timeline.map(\.id), [
            .history(newestHistory.id),
            .recovery(middleRecovery.id),
            .history(olderHistory.id)
        ])
    }

    func testOneRecoveryMatchesOnlyTheNearestCompatibleHistoryEntry() throws {
        let farther = history(
            id: id(140),
            seconds: 20,
            text: "Duplicate transcript",
            appName: "Mail",
            bundleID: "com.apple.mail"
        )
        let nearer = history(
            id: id(141),
            seconds: 25,
            text: farther.text,
            appName: farther.appName,
            bundleID: farther.appBundleID
        )
        let saved = recovery(
            id: id(142),
            seconds: 26,
            transcript: farther.text,
            appName: farther.appName,
            bundleID: farther.appBundleID
        )

        let timeline = HistoryTimeline.merge(history: [farther, nearer], recoveries: [saved])

        XCTAssertEqual(timeline.count, 2)
        XCTAssertEqual(timeline.first { $0.id == .history(nearer.id) }?.recovery?.id, saved.id)
        XCTAssertNil(try XCTUnwrap(timeline.first { $0.id == .history(farther.id) }).recovery)
    }

    func testStableIDsDoNotDependOnInputOrdering() {
        let matchedHistory = history(
            id: id(150),
            seconds: 30,
            text: "Matched",
            appName: "Mail",
            bundleID: "com.apple.mail"
        )
        let unmatchedHistory = history(id: id(151), seconds: 30, text: "History only")
        let matchedRecovery = recovery(
            id: id(152),
            seconds: 31,
            transcript: matchedHistory.text,
            appName: matchedHistory.appName,
            bundleID: matchedHistory.appBundleID
        )
        let unmatchedRecovery = recovery(
            id: id(153),
            seconds: 30,
            transcript: "Recovery only",
            appName: "Notes",
            bundleID: "com.apple.Notes"
        )

        let first = HistoryTimeline.merge(
            history: [matchedHistory, unmatchedHistory],
            recoveries: [matchedRecovery, unmatchedRecovery]
        )
        let second = HistoryTimeline.merge(
            history: [unmatchedHistory, matchedHistory],
            recoveries: [unmatchedRecovery, matchedRecovery]
        )

        XCTAssertEqual(first.map(\.id), second.map(\.id))
        XCTAssertTrue(first.contains { $0.id == .history(matchedHistory.id) && $0.recovery?.id == matchedRecovery.id })
        XCTAssertTrue(first.contains { $0.id == .recovery(unmatchedRecovery.id) })
    }

    func testStableIDSurvivesRecoveryMetadataUpdates() throws {
        let entry = history(
            id: id(160),
            seconds: 20,
            text: "Stable identity",
            appName: "Mail",
            bundleID: "com.apple.mail"
        )
        var saved = recovery(
            id: id(161),
            seconds: 21,
            transcript: entry.text,
            appName: entry.appName,
            bundleID: entry.appBundleID
        )
        let before = try XCTUnwrap(HistoryTimeline.merge(history: [entry], recoveries: [saved]).only)

        saved.state = .transcribed
        saved.failureDescription = "Transcribed"
        let after = try XCTUnwrap(HistoryTimeline.merge(history: [entry], recoveries: [saved]).only)

        XCTAssertEqual(before.id, .history(entry.id))
        XCTAssertEqual(after.id, before.id)
    }

    // MARK: - Fixtures

    private func history(
        id: UUID,
        seconds: TimeInterval,
        text: String,
        appName: String? = nil,
        bundleID: String? = nil,
        tag: String? = nil
    ) -> HistoryEntry {
        HistoryEntry(
            id: id,
            date: origin.addingTimeInterval(seconds),
            text: text,
            durationSeconds: 2,
            wordCount: text.split(whereSeparator: \.isWhitespace).count,
            latencyMs: 100,
            appName: appName,
            appBundleID: bundleID,
            language: "en",
            tag: tag,
            speechLevel: nil
        )
    }

    private func recovery(
        id: UUID,
        seconds: TimeInterval,
        state: DictationRecoveryState = .injectionFailed,
        failureDescription: String = "Paste was not confirmed",
        transcript: String?,
        appName: String?,
        bundleID: String?
    ) -> DictationRecovery {
        DictationRecovery(
            id: id,
            createdAt: origin.addingTimeInterval(seconds),
            durationSeconds: 2,
            language: "en",
            modelID: "parakeet-v3",
            appName: appName,
            appBundleID: bundleID,
            state: state,
            failureDescription: failureDescription,
            transcript: transcript
        )
    }

    private func id(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }
}

private extension Collection {
    var only: Element? {
        count == 1 ? first : nil
    }
}
