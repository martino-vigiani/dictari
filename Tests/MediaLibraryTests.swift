import XCTest

@MainActor
final class MediaLibraryTests: XCTestCase {
    func testResumeProcessesSequentiallyAndPersistsResultsWithoutLaunchingModel() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = MediaArchive(root: root)
        var document = MediaDocument(title: "Resume", language: "it")
        try archive.save(document)
        for offset in [0.0, 5.0] {
            let segment = MediaSegment(start: offset, duration: 0.01, source: "File")
            try archive.write([Float](repeating: 0.1, count: 160), segment: segment, documentID: document.id)
            document.segments.append(segment)
        }
        try archive.save(document)
        let library = MediaLibrary(archive: archive)
        let engine = MediaTestEngine()
        library.resume(document, engine: engine, corrector: VocabularyCorrector(terms: []))
        XCTAssertTrue(library.isBusy)
        // A second request must not run against the same engine.
        library.resume(document, engine: engine, corrector: VocabularyCorrector(terms: []))
        for _ in 0..<500 where library.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(library.isBusy)
        XCTAssertEqual(engine.calls, 2)
        XCTAssertEqual(engine.languages, ["it", "it"])
        XCTAssertEqual(try archive.list()[0].segments.compactMap(\.text), ["Test 1", "Test 2"])
        XCTAssertEqual(try archive.list()[0].status, "Completed")
    }
}

@MainActor
private final class MediaTestEngine: TranscriptionEngine {
    var calls = 0
    var languages: [String] = []
    func warmUp(progress: @escaping @Sendable (Double) -> Void) async throws { }
    func currentModelName() async -> String { "Test" }
    func transcribe(samples: [Float], language: String) async throws -> String {
        calls += 1
        languages.append(language)
        return "Test \(calls)"
    }
}

extension MediaLibraryTests {
    func testCancellationKeepsEngineBusyUntilInferenceActuallyReturns() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = MediaArchive(root: root)
        var document = MediaDocument(title: "Cancel", language: "en")
        try archive.save(document)
        let segment = MediaSegment(start: 0, duration: 0.01, source: "File")
        try archive.write([Float](repeating: 0.1, count: 160), segment: segment, documentID: document.id)
        document.segments = [segment]
        try archive.save(document)
        let library = MediaLibrary(archive: archive)
        let engine = PendingMediaTestEngine()
        library.resume(document, engine: engine, corrector: VocabularyCorrector(terms: []))
        for _ in 0..<500 where engine.pending == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(engine.pending)
        library.cancel()
        XCTAssertTrue(library.isBusy)
        engine.pending?.resume(returning: "Finished after cancellation")
        engine.pending = nil
        for _ in 0..<500 where library.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(library.isBusy)
        let saved = try archive.list()[0]
        XCTAssertNil(saved.segments[0].text)
        XCTAssertTrue(saved.status.contains("Interrupted"))
        XCTAssertEqual(try archive.samples(segment, documentID: document.id).count, 160)
    }
}

@MainActor
private final class PendingMediaTestEngine: TranscriptionEngine {
    var pending: CheckedContinuation<String, Never>?
    func warmUp(progress: @escaping @Sendable (Double) -> Void) async throws { }
    func currentModelName() async -> String { "Pending test" }
    func transcribe(samples: [Float], language: String) async throws -> String {
        await withCheckedContinuation { pending = $0 }
    }
}

extension MediaLibraryTests {
    func testDeadlineRetainsAudioAndQuarantinesUntilBackendReturns() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = MediaArchive(root: root)
        var document = MediaDocument(title: "Timeout", language: "en")
        try archive.save(document)
        let segment = MediaSegment(start: 0, duration: 0.01, source: "File")
        try archive.write([Float](repeating: 0.1, count: 160), segment: segment, documentID: document.id)
        document.segments = [segment]
        try archive.save(document)
        let library = MediaLibrary(archive: archive, inferenceTimeout: .milliseconds(40))
        let engine = PendingMediaTestEngine()
        defer { engine.pending?.resume(returning: "cleanup"); engine.pending = nil }
        library.resume(document, engine: engine, corrector: VocabularyCorrector(terms: []))
        for _ in 0..<500 where !library.waitingForEngine { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(library.waitingForEngine)
        XCTAssertTrue(library.isBusy)
        XCTAssertTrue(library.message?.contains("timed out") == true)
        XCTAssertTrue(try archive.list()[0].status.contains("Interrupted"))
        XCTAssertEqual(try archive.samples(segment, documentID: document.id).count, 160)
        library.resume(document, engine: engine, corrector: VocabularyCorrector(terms: []))
        engine.pending?.resume(returning: "late result must not be saved")
        engine.pending = nil
        for _ in 0..<500 where library.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(library.isBusy)
        XCTAssertFalse(library.waitingForEngine)
        XCTAssertNil(try archive.list()[0].segments[0].text)
    }
}
