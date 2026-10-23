import Foundation
import XCTest

/// Explicit opt-in native-model validation, excluded from silent/default selected suites.
/// This can initialize/download the speaker model and intentionally exceeds the unit-test
/// time budget. The fixture is prepared externally; this test never records or plays audio.
final class MeetingSpeakerRuntimeTests: XCTestCase {
    func testNativeAnalyzerDistinguishesTwoVoicesInExplicitPCMFixture() async throws {
        guard let path = ProcessInfo.processInfo.environment["DICTARI_SPEAKER_FIXTURE"],
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw XCTSkip("Set DICTARI_SPEAKER_FIXTURE to an explicit 16 kHz mono Float32 PCM fixture containing two voices")
        }
        let fixture = try Data(contentsOf: URL(fileURLWithPath: path))
        let sampleRate = 16_000
        let chunkSize = sampleRate * 5
        XCTAssertFalse(fixture.isEmpty, "Two-voice fixture must contain audio")
        guard !fixture.isEmpty, fixture.count.isMultiple(of: MemoryLayout<Float>.size) else {
            return XCTFail("Fixture must contain complete Float32 PCM samples")
        }
        let samples: [Float] = fixture.withUnsafeBytes { bytes in
            (0..<(fixture.count / MemoryLayout<Float>.size)).map {
                bytes.loadUnaligned(fromByteOffset: $0 * MemoryLayout<Float>.size, as: Float.self)
            }
        }
        guard samples.allSatisfy(\.isFinite) else { return XCTFail("Fixture contains non-finite PCM samples") }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dictari-speaker-runtime-" + UUID().uuidString, isDirectory: true)
        let archive = MediaArchive(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        var document = MediaDocument(title: "Explicit two-voice fixture", language: "en")
        try archive.save(document)
        for start in stride(from: 0, to: samples.count, by: chunkSize) {
            let end = min(start + chunkSize, samples.count)
            let segment = MediaSegment(start: Double(start) / Double(sampleRate),
                                       duration: Double(end - start) / Double(sampleRate), source: "App audio")
            try archive.write(Array(samples[start..<end]), segment: segment, documentID: document.id)
            document.segments.append(segment)
        }
        try archive.save(document)
        let analyzer = FluidMeetingSpeakerAnalyzer()
        let clock = ContinuousClock()
        let started = clock.now
        print("Speaker runtime start: \(Double(samples.count) / Double(sampleRate)) seconds, \(document.segments.count) chunks")

        let labels = try await analyzer.analyze(archive: archive, document: document, progress: { _ in })

        let elapsed = started.duration(to: clock.now)
        let orderedLabels = document.segments.map { labels[$0.id] ?? [] }
        let distinctIDs = Set(labels.values.flatMap { $0 })
        print("Speaker runtime finished in \(elapsed): labels=\(orderedLabels), distinctIDs=\(distinctIDs.sorted())")
        XCTAssertTrue(Set(labels.keys).isSubset(of: Set(document.segments.map(\.id))),
                      "Analyzer returned labels for unknown segment IDs")
        XCTAssertTrue(distinctIDs.allSatisfy { (0..<10).contains($0) },
                      "Stored speaker IDs must be zero-based slots in 0...9")
        XCTAssertGreaterThanOrEqual(distinctIDs.count, 2,
                                    "The explicit two-voice fixture must produce at least two distinct speaker slots")
    }
}
