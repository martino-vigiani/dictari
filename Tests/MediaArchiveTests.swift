import XCTest
import AVFoundation

final class MediaArchiveTests: XCTestCase {
    private func fixture() throws -> (URL, MediaArchive, MediaDocument) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let archive = MediaArchive(root: root)
        let document = MediaDocument(title: "Test", language: "de")
        try archive.save(document)
        return (root, archive, document)
    }

    func testChunkAndMetadataRoundTripIncludingCrashSidecar() throws {
        let (root, archive, document) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let segment = MediaSegment(start: 12.5, duration: 0.001, source: "Microphone")
        let samples: [Float] = [0, -0.5, 0.25, 1]
        try archive.write(samples, segment: segment, documentID: document.id)
        XCTAssertEqual(try archive.samples(segment, documentID: document.id), samples)
        let restored = try archive.recoverSegments(archive.list()[0])
        XCTAssertEqual(restored.segments.map(\.id), [segment.id])
        XCTAssertEqual(try archive.recoverSegments(restored).segments.count, 1)
        try archive.delete(document.id)
        XCTAssertTrue(try archive.list().isEmpty)
    }

    func testIncompleteMeetingChunkRecoversDurationFromActualBytes() throws {
        let (root, archive, document) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let segment = MediaSegment(start: 7, duration: 0, source: "App audio")
        try archive.write([Float](repeating: 0.2, count: 8000), segment: segment, documentID: document.id)
        let restored = try archive.recoverSegments(document)
        XCTAssertEqual(restored.segments[0].duration, 0.5)
        XCTAssertEqual(restored.segments[0].start, 7)
    }

    func testTranscriptSortsChannelsAndOmitsUnfinishedSegments() {
        var document = MediaDocument(title: "Meeting", language: "en")
        var later = MediaSegment(start: 65, duration: 2, source: "Microphone")
        later.text = "My answer"
        var earlier = MediaSegment(start: 3, duration: 2, source: "App audio")
        earlier.text = "Their question"
        document.segments = [later, earlier, MediaSegment(start: 70, duration: 3, source: "Microphone")]
        XCTAssertEqual(document.transcript, "[00:00:03] App audio\nTheir question\n\n[00:01:05] Microphone\nMy answer")
    }

    func testAudioFileDecodesInBoundedChunksWithoutLosingSamples() async throws {
        let (root, archive, document) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("fixture.wav")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        do {
            let file = try AVAudioFile(forWriting: fileURL, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000)!
            buffer.frameLength = 16000
            for i in 0..<16000 { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 0.03)) * 0.25 }
            for _ in 0..<25 { try file.write(from: buffer) }
        }
        let decoded = try await MediaFileDecoder.decode(url: fileURL, document: document, archive: archive)
        XCTAssertEqual(decoded.segments.count, 2)
        XCTAssertEqual(decoded.segments[0].duration, 20)
        XCTAssertEqual(decoded.segments[1].start, 20)
        XCTAssertEqual(decoded.segments[1].duration, 5)
        let chunks = try decoded.segments.map { try archive.samples($0, documentID: document.id) }
        XCTAssertEqual(chunks.map(\.count), [320000, 80000])
        XCTAssertEqual(chunks[0][100], Float(sin(Double(3))) * 0.25, accuracy: 0.0001)
    }

    func testCorruptFileDoesNotDestroyExistingDocument() async throws {
        let (root, archive, document) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("broken.mp4")
        try Data("invalid".utf8).write(to: fileURL)
        do {
            _ = try await MediaFileDecoder.decode(url: fileURL, document: document, archive: archive)
            XCTFail("Expected rejection")
        } catch { }
        XCTAssertEqual(try archive.list().map(\.id), [document.id])
    }
}
