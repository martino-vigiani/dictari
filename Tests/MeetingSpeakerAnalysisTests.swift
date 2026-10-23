import Observation
import XCTest

final class MeetingSpeakerLabelTests: XCTestCase {
    func testLegacySegmentWithoutSpeakerIndicesDecodesWithOriginalSourceLabel() throws {
        let legacy = Data(#"{"id":"00000000-0000-0000-0000-000000000001","start":0,"duration":1,"source":"App audio","text":"Existing transcript"}"#.utf8)

        let segment = try JSONDecoder().decode(MediaSegment.self, from: legacy)

        XCTAssertNil(segment.speakerIndices)
        XCTAssertEqual(segment.speakerLabel, "App audio")
        XCTAssertEqual(segment.text, "Existing transcript")
    }

    func testSingleAnonymousSpeakerUsesOneBasedDisplayLabel() {
        var segment = MediaSegment(start: 0, duration: 1, source: "App audio")
        segment.speakerIndices = [0]

        let label = segment.speakerLabel

        XCTAssertEqual(label, "Speaker 1")
    }

    func testMixedSpeakersAreDeduplicatedSortedAndBothShown() {
        var segment = MediaSegment(start: 0, duration: 1, source: "App audio")
        segment.speakerIndices = [1, 0, 1]

        let label = segment.speakerLabel

        XCTAssertEqual(label, "Speakers 1, 2")
    }

    func testUnknownSpeakersKeepAppAudioSourceLabel() {
        var segment = MediaSegment(start: 0, duration: 1, source: "App audio")
        segment.speakerIndices = []

        let label = segment.speakerLabel

        XCTAssertEqual(label, "App audio")
    }

    func testMicrophoneAndOtherSourcesAreNeverRelabeledAsRemoteSpeakers() {
        let sources = ["Microphone", "File", "Unknown"]
        let segments = sources.map { source in
            var segment = MediaSegment(start: 0, duration: 1, source: source)
            segment.speakerIndices = [0, 1]
            return segment
        }

        let labels = segments.map(\.speakerLabel)

        XCTAssertEqual(labels, sources)
    }
}

@MainActor
final class MeetingSpeakerAnalysisTests: XCTestCase {
    func testInitializationAndArchiveLoadNeverStartSpeakerAnalysis() async throws {
        let fixture = try SpeakerArchiveFixture()
        defer { fixture.remove() }
        let analyzer = ControlledSpeakerAnalyzer()
        let library = MediaLibrary(archive: fixture.archive, speakerAnalyzer: analyzer)
        let loaded = expectation(description: "Existing archive loaded")
        withObservationTracking { _ = library.documents } onChange: { loaded.fulfill() }

        library.load()
        await fulfillment(of: [loaded], timeout: 2)

        let calls = await analyzer.callCount
        XCTAssertEqual(calls, 0)
        XCTAssertFalse(library.isBusy)
        XCTAssertFalse(library.isAnalyzingSpeakers)
        XCTAssertEqual(library.documents.map(\.id), [fixture.document.id])
    }

    func testSuccessfulSpeakerAnalysisPersistsIDsAndPreservesTranscriptAndAudio() async throws {
        let fixture = try SpeakerArchiveFixture()
        defer { fixture.remove() }
        let analyzer = ControlledSpeakerAnalyzer()
        let library = MediaLibrary(archive: fixture.archive, speakerAnalyzer: analyzer)
        let completed = expectation(description: "Speaker analysis saved")
        library.onFinished = { completed.fulfill() }
        let appSegment = fixture.document.segments[0]

        library.analyzeSpeakers(fixture.document)
        await analyzer.waitUntilStarted()
        await analyzer.finish([appSegment.id: [0, 1]])
        await fulfillment(of: [completed], timeout: 2)

        let saved = try XCTUnwrap(fixture.archive.list().first)
        XCTAssertEqual(saved.segments[0].speakerIndices, [0, 1])
        XCTAssertEqual(saved.segments[0].speakerLabel, "Speakers 1, 2")
        XCTAssertEqual(saved.segments.map(\.text), fixture.document.segments.map(\.text))
        XCTAssertEqual(saved.segments.map(\.id), fixture.document.segments.map(\.id))
        XCTAssertTrue(saved.transcript.contains("Speakers 1, 2\nRemote words"))
        try fixture.assertAudioUnchanged()
        XCTAssertFalse(library.isBusy)
        XCTAssertFalse(library.isAnalyzingSpeakers)
    }

    func testRunningAnalysisRejectsSecondAnalysisAndTranscriptionResume() async throws {
        let fixture = try SpeakerArchiveFixture()
        defer { fixture.remove() }
        let analyzer = ControlledSpeakerAnalyzer()
        let library = MediaLibrary(archive: fixture.archive, speakerAnalyzer: analyzer)
        let engine = SpeakerGuardTestEngine()
        let completed = expectation(description: "First analysis finished")
        library.onFinished = { completed.fulfill() }
        library.analyzeSpeakers(fixture.document)
        await analyzer.waitUntilStarted()

        library.analyzeSpeakers(fixture.document)
        var pendingTranscription = fixture.document
        pendingTranscription.segments[0].text = nil
        library.resume(pendingTranscription, engine: engine, corrector: VocabularyCorrector(terms: []))

        let calls = await analyzer.callCount
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(engine.calls, 0)
        XCTAssertTrue(library.isBusy)
        XCTAssertTrue(library.isAnalyzingSpeakers)
        await analyzer.finish([:])
        await fulfillment(of: [completed], timeout: 2)
        let finalCalls = await analyzer.callCount
        XCTAssertEqual(finalCalls, 1)
        XCTAssertEqual(engine.calls, 0, "Rejected resume must never run after the analysis releases its slot")
    }

    func testCancellationKeepsBusyUntilAnalyzerReturnsAndDiscardsLateLabels() async throws {
        // Regression: cancellation must not free the shared model slot or apply late diarization.
        let fixture = try SpeakerArchiveFixture()
        defer { fixture.remove() }
        let analyzer = ControlledSpeakerAnalyzer()
        let library = MediaLibrary(archive: fixture.archive, speakerAnalyzer: analyzer)
        let completed = expectation(description: "Cancelled analyzer actually returned")
        library.onFinished = { completed.fulfill() }
        library.analyzeSpeakers(fixture.document)
        await analyzer.waitUntilStarted()

        library.cancel()

        XCTAssertTrue(library.isBusy)
        library.analyzeSpeakers(fixture.document)
        let calls = await analyzer.callCount
        XCTAssertEqual(calls, 1)
        await analyzer.finish([fixture.document.segments[0].id: [0]])
        await fulfillment(of: [completed], timeout: 2)
        let saved = try XCTUnwrap(fixture.archive.list().first)
        XCTAssertNil(saved.segments[0].speakerIndices)
        XCTAssertEqual(saved.segments.map(\.text), fixture.document.segments.map(\.text))
        try fixture.assertAudioUnchanged()
        XCTAssertFalse(library.isBusy)
        XCTAssertFalse(library.isAnalyzingSpeakers)
    }

    func testAnalyzerFailurePreservesExistingSpeakerIDsTranscriptAndAudio() async throws {
        let fixture = try SpeakerArchiveFixture(existingSpeakers: [1])
        defer { fixture.remove() }
        let analyzer = ControlledSpeakerAnalyzer()
        let library = MediaLibrary(archive: fixture.archive, speakerAnalyzer: analyzer)
        let completed = expectation(description: "Failed analyzer released slot")
        library.onFinished = { completed.fulfill() }

        library.analyzeSpeakers(fixture.document)
        await analyzer.waitUntilStarted()
        await analyzer.fail()
        await fulfillment(of: [completed], timeout: 2)

        let saved = try XCTUnwrap(fixture.archive.list().first)
        XCTAssertEqual(saved.segments, fixture.document.segments)
        try fixture.assertAudioUnchanged()
        XCTAssertFalse(library.isBusy)
        XCTAssertFalse(library.isAnalyzingSpeakers)
        XCTAssertTrue(library.message?.contains("Synthetic analysis failure") == true)
    }
}

private struct SpeakerArchiveFixture {
    let archive: MediaArchive
    let document: MediaDocument
    let samples = [Float](repeating: 0.125, count: 16_000) // One second of synthetic PCM.

    init(existingSpeakers: [Int]? = nil) throws {
        archive = MediaArchive(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        var document = MediaDocument(title: "Saved meeting", language: "en")
        document.status = "Completed"
        var remote = MediaSegment(start: 0, duration: 1, source: "App audio")
        remote.text = "Remote words"
        remote.speakerIndices = existingSpeakers
        var microphone = MediaSegment(start: 1, duration: 1, source: "Microphone")
        microphone.text = "Local words"
        document.segments = [remote, microphone]
        try archive.save(document)
        for segment in document.segments { try archive.write(samples, segment: segment, documentID: document.id) }
        self.document = document
    }

    func assertAudioUnchanged(file: StaticString = #filePath, line: UInt = #line) throws {
        for segment in document.segments {
            XCTAssertEqual(try archive.samples(segment, documentID: document.id), samples, file: file, line: line)
        }
    }

    func remove() { try? FileManager.default.removeItem(at: archive.root) }
}

private actor ControlledSpeakerAnalyzer: MeetingSpeakerAnalyzing {
    private(set) var callCount = 0
    private var pending: CheckedContinuation<[UUID: [Int]], Error>?
    private var started: CheckedContinuation<Void, Never>?

    func analyze(archive: MediaArchive, document: MediaDocument,
                 progress: @escaping @Sendable (Double) -> Void) async throws -> [UUID: [Int]] {
        callCount += 1
        progress(0.5)
        return try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            started?.resume()
            started = nil
        }
    }

    func waitUntilStarted() async {
        if pending != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func finish(_ speakers: [UUID: [Int]]) {
        let continuation = pending
        pending = nil
        continuation?.resume(returning: speakers)
    }

    func fail() {
        let continuation = pending
        pending = nil
        continuation?.resume(throwing: SpeakerTestFailure())
    }
}

private struct SpeakerTestFailure: LocalizedError {
    var errorDescription: String? { "Synthetic analysis failure" }
}

@MainActor
private final class SpeakerGuardTestEngine: TranscriptionEngine {
    var calls = 0
    func warmUp(progress: @escaping @Sendable (Double) -> Void) async throws {}
    func currentModelName() async -> String { "Guard test engine" }
    func transcribe(samples: [Float], language: String) async throws -> String {
        calls += 1
        return "Unexpected transcription"
    }
}

final class MeetingSpeakerEvidenceTests: XCTestCase {
    func testConfidentVoiceReturnsZeroBasedIDOnTheOriginalSegmentClock() throws {
        // Regression: adding one here and again in speakerLabel misidentified every voice.
        let segment = MediaSegment(start: 5, duration: 1, source: "App audio")
        var evidence = MeetingSpeakerEvidence(segments: [segment], frameDuration: 0.5,
                                              speakerCount: 2, origin: 5)

        try evidence.addFinalized(startFrame: 0, predictions: [0.9, 0.1, 0.9, 0.1])
        let labels = try evidence.finish(tentativeStartFrame: 2, tentativePredictions: [])

        XCTAssertEqual(labels[segment.id], [0])
    }

    func testSilentTimelineGapDoesNotShiftLabelsOntoTheWrongSegment() throws {
        let first = MediaSegment(start: 5, duration: 1, source: "App audio")
        let second = MediaSegment(start: 8, duration: 1, source: "App audio")
        var evidence = MeetingSpeakerEvidence(segments: [first, second], frameDuration: 0.5,
                                              speakerCount: 2, origin: 5)

        try evidence.addFinalized(startFrame: 0, predictions: [0.9, 0.1, 0.9, 0.1])
        try evidence.addFinalized(startFrame: 6, predictions: [0.1, 0.9, 0.1, 0.9])
        let labels = try evidence.finish(tentativeStartFrame: 8, tentativePredictions: [])

        XCTAssertEqual(labels[first.id], [0])
        XCTAssertEqual(labels[second.id], [1])
    }

    func testDifferentVoicesWithinOneAudioBlockRemainExplicitlyMixed() throws {
        let segment = MediaSegment(start: 0, duration: 1, source: "App audio")
        var evidence = MeetingSpeakerEvidence(segments: [segment], frameDuration: 0.5,
                                              speakerCount: 2, origin: 0)

        try evidence.addFinalized(startFrame: 0, predictions: [0.9, 0.1, 0.1, 0.9])
        let labels = try evidence.finish(tentativeStartFrame: 2, tentativePredictions: [])

        XCTAssertEqual(labels[segment.id], [0, 1])
    }

    func testShortSecondVoiceInFiveSecondBlockIsNotHiddenByDominantSpeaker() throws {
        // Regression: a relative 10% threshold dropped a real 0.4-second second voice
        // from a five-second block and attributed its words to the dominant voice.
        let segment = MediaSegment(start: 0, duration: 5, source: "App audio")
        var evidence = MeetingSpeakerEvidence(segments: [segment], frameDuration: 0.1,
                                              speakerCount: 2, origin: 0)
        let dominantFrames = Array(repeating: [Float(0.9), Float(0.1)], count: 46).flatMap { $0 }
        let secondVoiceFrames = Array(repeating: [Float(0.1), Float(0.9)], count: 4).flatMap { $0 }

        try evidence.addFinalized(startFrame: 0, predictions: dominantFrames + secondVoiceFrames)
        let labels = try evidence.finish(tentativeStartFrame: 50, tentativePredictions: [])

        XCTAssertEqual(labels[segment.id], [0, 1])
    }

    func testUncertainVoiceProbabilitiesDoNotInventSpeakerLabels() throws {
        let segment = MediaSegment(start: 0, duration: 1, source: "App audio")
        var evidence = MeetingSpeakerEvidence(segments: [segment], frameDuration: 0.5,
                                              speakerCount: 2, origin: 0)

        try evidence.addFinalized(startFrame: 0, predictions: [0.5, 0.4, 0.5, 0.4])
        let labels = try evidence.finish(tentativeStartFrame: 2, tentativePredictions: [])

        XCTAssertEqual(labels[segment.id], [])
    }

    func testTentativeTailDoesNotCountFramesAlreadyFinalizedTwice() throws {
        // Regression: the same finalized time interval must not introduce a second voice.
        let segment = MediaSegment(start: 0, duration: 0.5, source: "App audio")
        var evidence = MeetingSpeakerEvidence(segments: [segment], frameDuration: 0.5,
                                              speakerCount: 2, origin: 0)
        try evidence.addFinalized(startFrame: 0, predictions: [0.9, 0.1])

        let labels = try evidence.finish(tentativeStartFrame: 0, tentativePredictions: [0.1, 0.9])

        XCTAssertEqual(labels[segment.id], [0])
    }
}
