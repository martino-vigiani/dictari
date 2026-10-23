import XCTest

final class HistorySearchTests: XCTestCase {
    func testSearchFindsFullTranscriptBeyondFirstFiftyEntries() {
        // Regression: the displayed page must not limit archive search or truncate long text.
        var archive = (0..<75).map { historyEntry(text: "Unrelated \($0)") }
        archive[62].text = String(repeating: "Long transcript. ", count: 1000) + "hidden needle"

        let matches = HistorySearch.matches(in: archive, query: "hidden needle")

        XCTAssertEqual(matches.map(\.id), [archive[62].id])
        XCTAssertEqual(matches.first?.text, archive[62].text)
    }

    func testSearchMatchesAppNameAndTextIgnoringCaseAndPreservesArchiveOrder() {
        let archive = [historyEntry(text: "First", app: "MAIL"),
                       historyEntry(text: "Unrelated"), historyEntry(text: "Email draft")]

        let matches = HistorySearch.matches(in: archive, query: "  mail\n")

        XCTAssertEqual(matches.map(\.id), [archive[0].id, archive[2].id])
    }

    func testWhitespaceQueryReturnsTheCompleteArchiveUnchanged() {
        let archive = [historyEntry(text: "One"), historyEntry(text: "Two")]

        let matches = HistorySearch.matches(in: archive, query: " \n\t")

        XCTAssertEqual(matches, archive)
    }

    func testNoMatchesReturnsEmptyResults() {
        let archive = [historyEntry(text: "Unrelated", app: nil)]

        let matches = HistorySearch.matches(in: archive, query: "absent")

        XCTAssertEqual(matches, [])
    }
}

@MainActor
final class HistoryContentRevisionTests: XCTestCase {
    func testAddInvalidatesSearchResults() async throws {
        try await withHistoryStore { store in
            let before = store.contentRevision
            let entry = historyEntry(text: "Added")

            store.add(entry)

            XCTAssertNotEqual(store.contentRevision, before)
            XCTAssertEqual(store.entries, [entry])
        }
    }

    func testDeleteInvalidatesSearchResults() async throws {
        try await withHistoryStore { store in
            let entry = historyEntry(text: "Deleted")
            store.add(entry)
            let before = store.contentRevision

            store.delete(entry)

            XCTAssertNotEqual(store.contentRevision, before)
            XCTAssertEqual(store.entries, [])
        }
    }

    func testClearInvalidatesSearchResults() async throws {
        try await withHistoryStore { store in
            store.add(historyEntry(text: "Cleared"))
            let before = store.contentRevision

            store.clear()

            XCTAssertNotEqual(store.contentRevision, before)
            XCTAssertEqual(store.entries, [])
        }
    }

    func testRetentionPurgeInvalidatesSearchResults() async throws {
        try await withHistoryStore { store in
            // Distant dates avoid a clock seam: neither fixture can cross the cutoff during a run.
            store.add(historyEntry(text: "Expired", date: .distantPast))
            let retained = historyEntry(text: "Retained", date: .distantFuture)
            store.add(retained)
            let before = store.contentRevision

            store.purge(retentionMinutes: 60)

            XCTAssertNotEqual(store.contentRevision, before)
            XCTAssertEqual(store.entries, [retained])
        }
    }

    private func withHistoryStore(_ body: (HistoryStore) throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HistoryStore(fileURL: directory.appendingPathComponent("history.json"), saveDebounce: .zero)
        try body(store)
        try await store.flushPendingWrites()
    }
}

private func historyEntry(text: String, app: String? = nil, date: Date = .distantPast) -> HistoryEntry {
    HistoryEntry(date: date, text: text, durationSeconds: 1, wordCount: 1,
                 latencyMs: 0, appName: app)
}
