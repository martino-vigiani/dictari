import XCTest

@MainActor
final class TextRefinementTests: XCTestCase {
    func testDoesNotGenerateAtInitialization() {
        let backend = WritingTestBackend()
        let writing = TextRefinement(refiner: backend)
        XCTAssertEqual(backend.calls, 0)
        XCTAssertFalse(writing.isBusy)
        XCTAssertNil(writing.result)
    }

    func testRejectsEmptyAndOversizeWithoutCallingBackend() {
        let backend = WritingTestBackend()
        let writing = TextRefinement(refiner: backend)
        for text in [" \n", String(repeating: "a", count: 3001), String(repeating: "👨‍👩‍👧‍👦", count: 1000)] {
            writing.start(text, action: .correct)
            XCTAssertNotNil(writing.error)
            XCTAssertFalse(writing.isBusy)
            XCTAssertEqual(writing.original, text)
        }
        XCTAssertEqual(backend.calls, 0)
        XCTAssertNoThrow(try TextRefinement.validate(String(repeating: "a", count: 3000)))
    }

    func testUnavailableDoesNotCallBackendAndCanRefresh() {
        let backend = WritingTestBackend()
        backend.unavailableReason = "Model not ready"
        let writing = TextRefinement(refiner: backend)
        writing.start("Original", action: .correct)
        XCTAssertEqual(writing.error, "Model not ready")
        XCTAssertEqual(backend.calls, 0)
        backend.unavailableReason = nil
        writing.refreshAvailability()
        XCTAssertNil(writing.unavailableReason)
    }

    func testPreservesOriginalAndPassesSelectedAction() async throws {
        let backend = WritingTestBackend()
        let writing = TextRefinement(refiner: backend)
        writing.start("  non cambiare 42\n", action: .email)
        try await settle(writing)
        XCTAssertEqual(writing.original, "  non cambiare 42\n")
        XCTAssertEqual(backend.receivedText, writing.original)
        XCTAssertEqual(backend.receivedAction, .email)
        XCTAssertEqual(writing.result, "Revised")
    }

    func testPublishesWorkingDraftButOnlyCompletesWithFinalOutput() async throws {
        let backend = WritingTestBackend()
        backend.partials = ["First", "First working draft"]
        backend.suspend = true
        let writing = TextRefinement(refiner: backend)

        writing.start("Original", action: .correct)
        for _ in 0..<100 where backend.pending == nil { try await Task.sleep(for: .milliseconds(10)) }

        XCTAssertTrue(writing.isBusy)
        XCTAssertEqual(writing.partialResult, "First working draft")
        XCTAssertNil(writing.result, "a working draft must never be exposed as the final result")

        backend.pending?.resume(returning: "Final revision")
        backend.pending = nil
        try await settle(writing)

        XCTAssertNil(writing.partialResult)
        XCTAssertEqual(writing.result, "Final revision")
    }

    func testEmptyOutputAndBackendFailureKeepOriginal() async throws {
        let backend = WritingTestBackend()
        let writing = TextRefinement(refiner: backend)
        backend.output = " \n"
        writing.start("Original", action: .clarify)
        try await settle(writing)
        XCTAssertNil(writing.result)
        XCTAssertNotNil(writing.error)
        XCTAssertEqual(writing.original, "Original")
        backend.shouldFail = true
        writing.start("Original 2", action: .notes)
        try await settle(writing)
        XCTAssertNil(writing.result)
        XCTAssertNotNil(writing.error)
        XCTAssertEqual(writing.original, "Original 2")
    }

    func testCancellationRejectsLateOutputAndSerializesRequests() async throws {
        let backend = WritingTestBackend()
        backend.suspend = true
        let writing = TextRefinement(refiner: backend)
        writing.start("Original", action: .correct)
        for _ in 0..<100 where backend.pending == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(backend.pending)
        backend.onPartial?("Incomplete draft")
        XCTAssertEqual(writing.partialResult, "Incomplete draft")
        writing.cancel()
        XCTAssertTrue(writing.isBusy)
        XCTAssertNil(writing.partialResult)
        backend.onPartial?("Late incomplete draft")
        XCTAssertNil(writing.partialResult)
        writing.start("Another", action: .email)
        XCTAssertEqual(backend.calls, 1)
        backend.pending?.resume(returning: "Late revision")
        backend.pending = nil
        try await settle(writing)
        XCTAssertNil(writing.result)
        XCTAssertNil(writing.error)
        XCTAssertEqual(writing.original, "Original")
    }

    func testImmediateCancellationDoesNotStartGeneration() async throws {
        let backend = WritingTestBackend()
        let writing = TextRefinement(refiner: backend)
        writing.start("Original", action: .correct)
        writing.cancel()
        try await settle(writing)
        XCTAssertEqual(backend.calls, 0)
        XCTAssertNil(writing.result)
    }

    func testClearRemovesPreviousPreviewAndOriginal() async throws {
        let writing = TextRefinement(refiner: WritingTestBackend())
        writing.start("Original", action: .correct)
        try await settle(writing)
        XCTAssertNotNil(writing.result)
        writing.clear()
        XCTAssertNil(writing.result)
        XCTAssertEqual(writing.original, "")
    }

    private func settle(_ writing: TextRefinement) async throws {
        for _ in 0..<100 where writing.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(writing.isBusy)
    }
}

@MainActor
private final class WritingTestBackend: TextRefiner {
    var unavailableReason: String?
    var calls = 0
    var receivedText: String?
    var receivedAction: WritingAction?
    var output = " Revised \n"
    var partials: [String] = []
    var shouldFail = false
    var suspend = false
    var pending: CheckedContinuation<String, Never>?
    var onPartial: (@MainActor @Sendable (String) -> Void)?
    func refine(_ text: String, action: WritingAction) async throws -> String {
        try await run(text, action: action)
    }
    func refineStreaming(
        _ text: String,
        action: WritingAction,
        onPartial: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> String {
        self.onPartial = onPartial
        return try await run(text, action: action)
    }
    private func run(_ text: String, action: WritingAction) async throws -> String {
        calls += 1
        receivedText = text
        receivedAction = action
        if shouldFail { throw WritingError.invalidOutput }
        for partial in partials { onPartial?(partial) }
        if suspend { return await withCheckedContinuation { pending = $0 } }
        return output
    }
}

extension TextRefinementTests {
    func testLongPassagesKeepEveryCharacterAndRespectModelLimit() throws {
        let text = String(repeating: "Prima riga: sì, 123. 👨‍👩‍👧‍👦\nSeconda riga.\n\n", count: 400)
        let passages = WritingPassages.split(text)
        XCTAssertGreaterThan(passages.count, 1)
        XCTAssertEqual(passages.joined(), text)
        for passage in passages { XCTAssertNoThrow(try TextRefinement.validate(passage)) }
    }

    func testUnbrokenLongTextIsNotTruncated() throws {
        let text = String(repeating: "界", count: 9001)
        let passages = WritingPassages.split(text)
        XCTAssertEqual(passages.joined(), text)
        for passage in passages { XCTAssertNoThrow(try TextRefinement.validate(passage)) }
    }
}
