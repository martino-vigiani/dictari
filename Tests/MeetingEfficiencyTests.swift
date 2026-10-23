import XCTest

@MainActor
final class MeetingEfficiencyTests: XCTestCase {
    func testExactDigitalSilenceCompletesWithoutCallingTranscriptionEngine() async throws {
        // Regression: muted meeting chunks consumed model inference and could hallucinate text.
        let samples: [Float] = [0, -0.0, 0, -0.0]
        let fixture = try EfficiencyArchiveFixture(samples: samples)
        defer { fixture.remove() }
        let engine = EfficiencyTestEngine()
        let library = MediaLibrary(archive: fixture.archive)
        let completed = expectation(description: "Silent chunk processed")
        library.onFinished = { completed.fulfill() }

        library.resume(fixture.document, engine: engine, corrector: VocabularyCorrector(terms: []))
        await fulfillment(of: [completed], timeout: 2)

        XCTAssertEqual(engine.receivedSamples, [])
        XCTAssertFalse(library.isBusy)
        let saved = try XCTUnwrap(fixture.archive.list().first)
        XCTAssertEqual(saved.segments[0].text, "", "Silence must be marked processed so resume does not retry it")
        XCTAssertEqual(saved.status, "Completed")
        XCTAssertEqual(try fixture.archive.samples(fixture.document.segments[0], documentID: saved.id), samples)
    }

    func testQuietNonzeroAudioStillReachesTranscriptionEngineUnchanged() async throws {
        // Regression boundary: silence optimization must not become an amplitude/VAD cutoff.
        let quietSample = Float.leastNormalMagnitude
        let samples: [Float] = [0, quietSample, -quietSample, 0]
        let fixture = try EfficiencyArchiveFixture(samples: samples)
        defer { fixture.remove() }
        let engine = EfficiencyTestEngine()
        let library = MediaLibrary(archive: fixture.archive)
        let completed = expectation(description: "Quiet chunk transcribed")
        library.onFinished = { completed.fulfill() }

        library.resume(fixture.document, engine: engine, corrector: VocabularyCorrector(terms: []))
        await fulfillment(of: [completed], timeout: 2)

        XCTAssertEqual(engine.receivedSamples, [samples])
        XCTAssertEqual(try fixture.archive.list().first?.segments[0].text, "Quiet speech")
        XCTAssertFalse(library.isBusy)
    }
}

private struct EfficiencyArchiveFixture {
    let archive: MediaArchive
    let document: MediaDocument

    init(samples: [Float]) throws {
        archive = MediaArchive(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        var document = MediaDocument(title: "Synthetic meeting", language: "en")
        let segment = MediaSegment(start: 0, duration: Double(samples.count) / 16_000, source: "App audio")
        document.segments = [segment]
        try archive.save(document)
        try archive.write(samples, segment: segment, documentID: document.id)
        self.document = document
    }

    func remove() { try? FileManager.default.removeItem(at: archive.root) }
}

@MainActor
private final class EfficiencyTestEngine: TranscriptionEngine {
    var receivedSamples: [[Float]] = []
    func warmUp(progress: @escaping @Sendable (Double) -> Void) async throws {}
    func currentModelName() async -> String { "Deterministic test engine" }
    func transcribe(samples: [Float], language: String) async throws -> String {
        receivedSamples.append(samples)
        return "Quiet speech"
    }
}
