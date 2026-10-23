import Foundation
@preconcurrency import FluidAudio

protocol MeetingSpeakerAnalyzing: Sendable {
    func analyze(
        archive: MediaArchive,
        document: MediaDocument,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [UUID: [Int]]
}

enum MeetingSpeakerAnalysisError: LocalizedError {
    case noAppAudio, tooLong, invalidAudio, invalidTimeline, busy, unsupportedModel

    var errorDescription: String? {
        switch self {
        case .noAppAudio: String(localized: "This recording has no saved meeting-app audio to analyze.")
        case .tooLong: String(localized: "Speaker analysis supports meetings up to one hour.")
        case .invalidAudio: String(localized: "Some saved audio is missing or damaged. Speaker labels were not changed.")
        case .invalidTimeline: String(localized: "This recording has inconsistent audio timing. Speaker labels were not changed.")
        case .busy: String(localized: "Speaker analysis is already running.")
        case .unsupportedModel: String(localized: "The speaker model has an unsupported audio format.")
        }
    }
}

/// A separate actor owns each native session. No model work happens at construction/startup.
/// Cancellation is checked between 500 ms inputs, never by abandoning a still-running native
/// call: the caller's busy state can safely end only after this method returns and cleanup runs.
actor FluidMeetingSpeakerAnalyzer: MeetingSpeakerAnalyzing {
    private var analyzing = false
    private static let sampleRate = 16_000
    private static let chunkSamples = 8_000
    private static let maximumSeconds: Double = 3_600

    func analyze(
        archive: MediaArchive,
        document: MediaDocument,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [UUID: [Int]] {
        guard !analyzing else { throw MeetingSpeakerAnalysisError.busy }
        analyzing = true
        defer { analyzing = false }
        try Task.checkCancellation()
        let segments = try Self.validatedSegments(archive: archive, document: document)
        let originSample = Int((segments[0].start * Double(Self.sampleRate)).rounded())
        let endSample = Int(((segments.last!.start + segments.last!.duration) * Double(Self.sampleRate)).rounded())
        let timeline = DiarizerTimelineConfig(maxStoredFrames: 0, storeSegments: false)
        let diarizer = LSEENDDiarizer(timelineConfig: timeline)
        defer { diarizer.cleanup() }
        // FluidAudio's loader currently does not forward download progress. Keep the caller's
        // progress indeterminate until initialization finishes instead of showing a false 0%.
        try await diarizer.initialize(variant: .dihard3, stepSize: .step500ms, computeUnits: .cpuOnly)
        try Task.checkCancellation()
        guard let nativeSampleRate = diarizer.targetSampleRate, nativeSampleRate > 0,
              let frameHz = diarizer.modelFrameHz, frameHz.isFinite, frameHz > 0,
              let speakers = diarizer.numSpeakers, (1...10).contains(speakers) else {
            throw MeetingSpeakerAnalysisError.unsupportedModel
        }
        var evidence = MeetingSpeakerEvidence(
            segments: segments, frameDuration: 1 / frameHz,
            speakerCount: speakers, origin: Double(originSample) / Double(Self.sampleRate)
        )
        var tentativeStart = 0
        var tentative: [Float] = []
        var cursor = originSample
        var lastProgress = 0.0
        progress(0)

        func accept(_ update: DiarizerTimelineUpdate?) throws {
            guard let chunk = update?.chunkResult else { return }
            try evidence.addFinalized(startFrame: chunk.startFrame, predictions: chunk.finalizedPredictions)
            // Tentative predictions replace the previous tail. Adding every update would count
            // the same interval repeatedly, including again when it becomes finalized.
            tentativeStart = chunk.tentativeStartFrame
            tentative = chunk.tentativePredictions
        }

        func reportProgress() {
            let fraction = min(0.99, Double(cursor - originSample) / Double(max(1, endSample - originSample)))
            if fraction - lastProgress >= 0.005 {
                lastProgress = fraction
                progress(fraction)
            }
        }

        let silence = [Float](repeating: 0, count: Self.chunkSamples)
        for segment in segments {
            try Task.checkCancellation()
            let start = Int((segment.start * Double(Self.sampleRate)).rounded())
            let count = Int((segment.duration * Double(Self.sampleRate)).rounded())
            // Omitted all-silent capture chunks still occupy time. Feed their gaps in small
            // pieces, retaining the original segment clock instead of concatenating speech.
            while cursor < start {
                try Task.checkCancellation()
                let amount = min(Self.chunkSamples, start - cursor)
                try accept(diarizer.process(samples: silence.prefix(amount), sourceSampleRate: Double(Self.sampleRate)))
                cursor += amount
                reportProgress()
            }
            let file = try FileHandle(forReadingFrom: archive.directory(document.id).appendingPathComponent(segment.audioFile))
            defer { try? file.close() }
            // Capture timestamps can overlap slightly at a resampling boundary. Do not feed
            // the overlap twice; validatedSegments rejects overlaps larger than one 100 ms frame.
            let skipped = max(0, cursor - start)
            try file.seek(toOffset: UInt64(skipped * MemoryLayout<Float>.size))
            var remaining = max(0, count - skipped)
            while remaining > 0 {
                try Task.checkCancellation()
                let amount = min(Self.chunkSamples, remaining)
                let byteCount = amount * MemoryLayout<Float>.size
                guard let data = try file.read(upToCount: byteCount), data.count == byteCount else {
                    throw MeetingSpeakerAnalysisError.invalidAudio
                }
                let samples = data.withUnsafeBytes { bytes in
                    (0..<amount).map { bytes.loadUnaligned(fromByteOffset: $0 * MemoryLayout<Float>.size, as: Float.self) }
                }
                guard samples.allSatisfy(\.isFinite) else { throw MeetingSpeakerAnalysisError.invalidAudio }
                try accept(diarizer.process(samples: samples, sourceSampleRate: Double(Self.sampleRate)))
                cursor += amount
                remaining -= amount
                reportProgress()
            }
        }
        try Task.checkCancellation()
        try accept(diarizer.finalizeSession())
        try Task.checkCancellation()
        let result = try evidence.finish(tentativeStartFrame: tentativeStart, tentativePredictions: tentative)
        progress(1)
        return result
    }

    private static func validatedSegments(archive: MediaArchive, document: MediaDocument) throws -> [MediaSegment] {
        let segments = document.segments.filter { $0.source == "App audio" }.sorted {
            $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start
        }
        guard !segments.isEmpty else { throw MeetingSpeakerAnalysisError.noAppAudio }
        guard document.segments.allSatisfy({ $0.start.isFinite && $0.duration.isFinite && $0.start >= 0 && $0.duration >= 0 }) else {
            throw MeetingSpeakerAnalysisError.invalidTimeline
        }
        guard document.segments.allSatisfy({ $0.start + $0.duration <= maximumSeconds }) else {
            throw MeetingSpeakerAnalysisError.tooLong
        }
        guard segments.count <= 36_000 else { throw MeetingSpeakerAnalysisError.invalidTimeline }
        var seen = Set<UUID>()
        var previousEnd = 0.0
        for segment in segments {
            try Task.checkCancellation()
            guard seen.insert(segment.id).inserted, segment.duration > 0, segment.duration <= 25,
                  segment.start >= previousEnd - 0.1,
                  segment.start + segment.duration > previousEnd else {
                throw MeetingSpeakerAnalysisError.invalidTimeline
            }
            previousEnd = segment.start + segment.duration
            let expectedSamples = Int((segment.duration * Double(sampleRate)).rounded())
            let url = archive.directory(document.id).appendingPathComponent(segment.audioFile)
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size == expectedSamples * MemoryLayout<Float>.size, expectedSamples > 0 else {
                throw MeetingSpeakerAnalysisError.invalidAudio
            }
        }
        return segments
    }
}

/// Streaming probability integration, independent of the native model. Only per-segment totals
/// survive a chunk; raw predictions and audio do not accumulate with the meeting's duration.
struct MeetingSpeakerEvidence {
    private let segments: [MediaSegment]
    private let frameDuration: Double
    private let speakerCount: Int
    private let origin: Double
    private var activity: [[Double]]
    private var confident: [Double]
    private var uncertain: [Double]
    private var frontier = 0
    private var segmentCursor = 0

    init(segments: [MediaSegment], frameDuration: Double, speakerCount: Int, origin: Double) {
        self.segments = segments
        self.frameDuration = frameDuration
        self.speakerCount = speakerCount
        self.origin = origin
        activity = Array(repeating: Array(repeating: 0, count: speakerCount), count: segments.count)
        confident = Array(repeating: 0, count: segments.count)
        uncertain = Array(repeating: 0, count: segments.count)
    }

    mutating func addFinalized(startFrame: Int, predictions: [Float]) throws {
        guard speakerCount > 0, predictions.count.isMultiple(of: speakerCount), startFrame >= 0 else {
            throw MeetingSpeakerAnalysisError.unsupportedModel
        }
        let frames = predictions.count / speakerCount
        for row in 0..<frames {
            let frame = startFrame + row
            guard frame >= frontier else { continue }
            let start = origin + Double(frame) * frameDuration
            let end = start + frameDuration
            while segmentCursor < segments.count, segments[segmentCursor].start + segments[segmentCursor].duration <= start {
                segmentCursor += 1
            }
            let probabilities = predictions[(row * speakerCount)..<((row + 1) * speakerCount)]
            guard probabilities.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
                throw MeetingSpeakerAnalysisError.unsupportedModel
            }
            let strong = probabilities.contains { $0 >= 0.65 }
            let ambiguous = !strong && probabilities.contains { $0 >= 0.35 }
            var index = segmentCursor
            while index < segments.count, segments[index].start < end {
                let segment = segments[index]
                let duration = min(end, segment.start + segment.duration) - max(start, segment.start)
                if duration > 0 {
                    if strong { confident[index] += duration }
                    if ambiguous { uncertain[index] += duration }
                    for speaker in 0..<speakerCount where predictions[row * speakerCount + speaker] >= 0.65 {
                        activity[index][speaker] += duration
                    }
                }
                index += 1
            }
        }
        frontier = max(frontier, startFrame + frames)
    }

    mutating func finish(tentativeStartFrame: Int, tentativePredictions: [Float]) throws -> [UUID: [Int]] {
        try addFinalized(startFrame: tentativeStartFrame, predictions: tentativePredictions)
        var result: [UUID: [Int]] = [:]
        for (index, segment) in segments.enumerated() {
            // A short spike or mostly uncertain speech cannot justify a named voice. Multiple
            // qualifying slots remain explicitly mixed instead of choosing the first/dominant one.
            guard confident[index] + 1e-9 >= 0.4, uncertain[index] <= confident[index] + 1e-9 else {
                result[segment.id] = []
                continue
            }
            let minimum = 0.3
            result[segment.id] = (0..<speakerCount).filter { activity[index][$0] + 1e-9 >= minimum }
        }
        return result
    }
}
