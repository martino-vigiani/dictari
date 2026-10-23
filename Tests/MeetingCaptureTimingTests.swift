import AVFoundation
import CoreMedia
import XCTest

/// Exercises the real conversion/sealing path with in-memory PCM, without creating SCStream,
/// opening a microphone, requesting permission, synthesizing speech, or playing audio.
@available(macOS 15.0, *)
final class MeetingCaptureTimingTests: XCTestCase {
    func testTimestampGapSealsSeparateChunksWithoutCompressingMeetingTime() throws {
        // Regression: appending discontinuous buffers attributed later words to an earlier time.
        let fixture = try CaptureTimingFixture()
        defer { fixture.remove() }
        let capture = fixture.makeCapture()
        let first = try makePCMSample(start: 0, seconds: 1, value: 0.125)
        let second = try makePCMSample(start: 10, seconds: 1, value: 0.25)

        capture.consume(first, source: "App audio")
        capture.consume(second, source: "App audio")
        let segments = capture.finishSegments()

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments.map(\.start), [0, 10])
        XCTAssertEqual(segments.map(\.duration), [1, 1])
        XCTAssertEqual(fixture.events.errors, [])
        XCTAssertEqual(fixture.events.segments.map(\.id), segments.map(\.id))
        for (index, segment) in segments.enumerated() {
            let saved = try fixture.archive.samples(segment, documentID: fixture.document.id)
            XCTAssertEqual(saved, [Float](repeating: index == 0 ? 0.125 : 0.25, count: 16_000))
        }
    }

    func testBackwardTimestampRetainsFirstAudioAndRejectsSecondBuffer() throws {
        let fixture = try CaptureTimingFixture()
        defer { fixture.remove() }
        let capture = fixture.makeCapture()
        let first = try makePCMSample(start: 10, seconds: 1, value: 0.125)
        let backward = try makePCMSample(start: 0, seconds: 1, value: 0.25)

        capture.consume(first, source: "App audio")
        capture.consume(backward, source: "App audio")
        let segments = capture.finishSegments()

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments.first?.start, 10)
        XCTAssertEqual(segments.first?.duration, 1)
        XCTAssertEqual(fixture.events.errors,
                       ["Audio timing changed unexpectedly. Recording stopped; captured audio is saved."],
                       "Out-of-order audio must report its cause, not a conversion failure")
        let retained = try XCTUnwrap(segments.first)
        XCTAssertEqual(try fixture.archive.samples(retained, documentID: fixture.document.id),
                       [Float](repeating: 0.125, count: 16_000))
    }

    func testFiveSecondsOfDigitalSilenceLeaveNoAudioOrSegmentSidecars() throws {
        let fixture = try CaptureTimingFixture()
        defer { fixture.remove() }
        let capture = fixture.makeCapture()
        let silence = try makePCMSample(start: 0, seconds: 5, value: 0)

        capture.consume(silence, source: "App audio")
        let segments = capture.finishSegments()

        XCTAssertEqual(segments, [])
        XCTAssertEqual(fixture.events.segments, [])
        XCTAssertEqual(fixture.events.errors, [])
        let files = try FileManager.default.contentsOfDirectory(
            at: fixture.archive.directory(fixture.document.id), includingPropertiesForKeys: nil)
        XCTAssertEqual(files.map(\.lastPathComponent).sorted(), ["document.json"])
    }

    func testQuietNonzeroCaptureRetainsEverySample() throws {
        // Regression boundary: only digital zero can be discarded, never quiet speech.
        let fixture = try CaptureTimingFixture()
        defer { fixture.remove() }
        let capture = fixture.makeCapture()
        let quietValue: Float = 0.000_001
        let quiet = try makePCMSample(start: 0, seconds: 1, value: quietValue)

        capture.consume(quiet, source: "App audio")
        let segments = capture.finishSegments()

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(fixture.events.errors, [])
        let retained = try XCTUnwrap(segments.first)
        XCTAssertEqual(retained.duration, 1)
        XCTAssertEqual(try fixture.archive.samples(retained, documentID: fixture.document.id),
                       [Float](repeating: quietValue, count: 16_000))
    }
}

private func makePCMSample(start: Double, seconds: Int, value: Float) throws -> CMSampleBuffer {
    let sampleRate: CMTimeScale = 16_000
    let frameCount = Int(sampleRate) * seconds
    let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: Double(sampleRate), channels: 1, interleaved: false))
    let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)))
    pcm.frameLength = AVAudioFrameCount(frameCount)
    let channel = try XCTUnwrap(pcm.floatChannelData?[0])
    channel.update(repeating: value, count: frameCount)
    var description: CMAudioFormatDescription?
    let formatStatus = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,
        asbd: format.streamDescription, layoutSize: 0, layout: nil, magicCookieSize: 0,
        magicCookie: nil, extensions: nil, formatDescriptionOut: &description)
    XCTAssertEqual(formatStatus, noErr)
    let audioDescription = try XCTUnwrap(description)
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: sampleRate),
        presentationTimeStamp: CMTime(seconds: start, preferredTimescale: sampleRate), decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    let createStatus = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: nil,
        formatDescription: audioDescription, sampleCount: frameCount, sampleTimingEntryCount: 1,
        sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample)
    XCTAssertEqual(createStatus, noErr)
    let result = try XCTUnwrap(sample)
    let dataStatus = CMSampleBufferSetDataBufferFromAudioBufferList(result,
        blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
        flags: 0, bufferList: pcm.audioBufferList)
    XCTAssertEqual(dataStatus, noErr)
    return result
}

private struct CaptureTimingFixture {
    let archive: MediaArchive
    let document: MediaDocument
    let events = CaptureTimingEvents()

    init() throws {
        archive = MediaArchive(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        document = MediaDocument(title: "Synthetic capture timing", language: "en")
        try archive.save(document)
    }

    @available(macOS 15.0, *)
    func makeCapture() -> MeetingCapture {
        let events = events
        return MeetingCapture(archive: archive, documentID: document.id,
                              onSegment: { events.record(segment: $0) },
                              onError: { events.record(error: $0) })
    }

    func remove() { try? FileManager.default.removeItem(at: archive.root) }
}

private final class CaptureTimingEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedSegments: [MediaSegment] = []
    private var recordedErrors: [String] = []
    var segments: [MediaSegment] { lock.withLock { recordedSegments } }
    var errors: [String] { lock.withLock { recordedErrors } }
    func record(segment: MediaSegment) { lock.withLock { recordedSegments.append(segment) } }
    func record(error: String) { lock.withLock { recordedErrors.append(error) } }
}
