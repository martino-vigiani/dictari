import Foundation
import AVFoundation

struct MediaSegment: Codable, Identifiable, Sendable, Equatable {
    var id = UUID()
    let start: Double
    let duration: Double
    let source: String
    var text: String?
    var error: String?
    /// Anonymous voice slots local to this recording; nil also decodes older archives.
    var speakerIndices: [Int]?
    /// Canonical English label. `source` is persisted and compared ("App audio", "Microphone",
    /// "File"), and this label is part of `transcript`, which the local MCP server pages by
    /// character offset: it must not change with the interface language.
    var speakerLabel: String {
        guard let indices = speakerSlots else { return source }
        return indices.count == 1 ? "Speaker \(indices[0] + 1)" : "Speakers " + indices.map { String($0 + 1) }.joined(separator: ", ")
    }

    /// The same label in the interface language, for what the user reads, copies or exports.
    var localizedSpeakerLabel: String {
        guard let indices = speakerSlots else { return Self.localizedSource(source) }
        if indices.count == 1 {
            return String(localized: "Speaker \(indices[0] + 1)", comment: "Transcript label for one estimated voice")
        }
        let list = indices.map { String($0 + 1) }.joined(separator: ", ")
        return String(localized: "Speakers \(list)", comment: "Transcript label for a block with several voices, e.g. Speakers 1, 2")
    }

    private var speakerSlots: [Int]? {
        guard source == "App audio", let speakerIndices else { return nil }
        let indices = Array(Set(speakerIndices.filter { (0..<10).contains($0) })).sorted()
        return indices.isEmpty ? nil : indices
    }

    /// Display name of a stored source value. Unknown values (a newer build) show as stored.
    static func localizedSource(_ source: String) -> String {
        switch source {
        case "App audio": String(localized: "App audio", comment: "Transcript label: audio from the meeting app")
        case "Microphone": String(localized: "Microphone", comment: "Transcript label: audio from your microphone")
        case "File": String(localized: "File", comment: "Transcript label: audio from an imported file")
        default: source
        }
    }
    var audioFile: String { id.uuidString + ".pcm" }
}

struct MediaDocument: Codable, Identifiable, Sendable {
    var id = UUID()
    let title: String
    var created = Date()
    let language: String
    var status = "Preparing"
    var segments: [MediaSegment] = []

    var canAnalyzeSpeakers: Bool { status == "Completed" && segments.contains { $0.source == "App audio" } }

    var hasTranscript: Bool { segments.contains { !($0.text ?? "").isEmpty } }

    /// Canonical plain text (English speaker labels): what the local MCP server serves.
    var transcript: String { transcript(label: \.speakerLabel) }

    /// The plain text the user copies, exports or revises: speaker labels in the interface
    /// language, otherwise identical to `transcript`.
    var localizedTranscript: String { transcript(label: \.localizedSpeakerLabel) }

    private func transcript(label: KeyPath<MediaSegment, String>) -> String {
        segments.sorted { $0.start < $1.start }.compactMap { segment in
            guard let text = segment.text, !text.isEmpty else { return nil }
            let seconds = Int(max(0, segment.start))
            return String(format: "[%02d:%02d:%02d] %@\n%@", seconds / 3600, seconds / 60 % 60, seconds % 60,
                          segment[keyPath: label], text)
        }.joined(separator: "\n\n")
    }

    /// `status` is persisted and compared in logic ("Completed", "No audio", …), so it stays
    /// English on disk. This maps the known values for display; anything else shows as stored.
    var displayStatus: String {
        switch status {
        case "Preparing": String(localized: "Preparing", comment: "Media transcript status")
        case "Transcribing": String(localized: "Transcribing", comment: "Media transcript status")
        case "Recording and transcribing": String(localized: "Recording and transcribing", comment: "Media transcript status")
        case "Recording — waiting for next audio segment":
            String(localized: "Recording — waiting for next audio segment", comment: "Media transcript status")
        case "Completed": String(localized: "Completed", comment: "Media transcript status")
        case "No audio": String(localized: "No audio", comment: "Media transcript status")
        case "Interrupted — saved audio available":
            String(localized: "Interrupted — saved audio available", comment: "Media transcript status")
        case "Interrupted — capture error": String(localized: "Interrupted — capture error", comment: "Media transcript status")
        case "Interrupted — audio retained": String(localized: "Interrupted — audio retained", comment: "Media transcript status")
        default: status
        }
    }

    /// Meeting titles are stored as "Meeting — <app>" (English, persisted). Display only.
    var displayTitle: String {
        let prefix = "Meeting — "
        guard title.hasPrefix(prefix) else { return title }
        let application = String(title.dropFirst(prefix.count))
        return String(localized: "Meeting — \(application)", comment: "Title of a recorded meeting; the argument is the app name")
    }
}

/// Skip only exact digital silence, never an amplitude threshold that could discard
/// quiet speech. This does not claim to classify voices, music or background noise.
enum MediaAudioActivity {
    static func isDigitalSilence<C: Collection>(_ samples: C) -> Bool where C.Element == Float {
        samples.allSatisfy { $0 == 0 }
    }
}

enum MediaArchiveError: LocalizedError {
    case noAudio, decodeFailed, tooLong, empty, unavailable
    var errorDescription: String? {
        switch self {
        case .noAudio: String(localized: "This file has no readable audio track.")
        case .decodeFailed: String(localized: "The audio could not be decoded. Try exporting it as WAV or M4A.")
        case .tooLong: String(localized: "The current limit is four hours per file or meeting.")
        case .empty: String(localized: "No audio was captured.")
        case .unavailable: String(localized: "Wait for the current dictation or model loading to finish.")
        }
    }
}

/// Immutable chunk files and atomic metadata. Paths come from UUIDs, never imported filenames.
struct MediaArchive: Sendable {
    let root: URL
    init(root: URL = AppPaths.support.appendingPathComponent("Transcripts", isDirectory: true)) { self.root = root }
    func directory(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    func save(_ document: MediaDocument) throws {
        let folder = directory(document.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: folder.appendingPathComponent("document.json"), options: .atomic)
    }
    func list() throws -> [MediaDocument] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { UUID(uuidString: $0.lastPathComponent) != nil }
            .compactMap { folder in
                guard let data = try? Data(contentsOf: folder.appendingPathComponent("document.json")),
                      let document = try? JSONDecoder().decode(MediaDocument.self, from: data),
                      document.id.uuidString == folder.lastPathComponent else { return nil }
                return document
            }.sorted { $0.created > $1.created }
    }
    func write(_ samples: [Float], segment: MediaSegment, documentID: UUID) throws {
        let data = samples.withUnsafeBytes { Data($0) }
        try data.write(to: directory(documentID).appendingPathComponent(segment.audioFile), options: .atomic)
        // Sidecar makes a sealed chunk discoverable even if the process exits before UI receives it.
        try JSONEncoder().encode(segment).write(to: directory(documentID).appendingPathComponent(segment.id.uuidString + ".json"), options: .atomic)
    }
    func samples(_ segment: MediaSegment, documentID: UUID) throws -> [Float] {
        let data = try Data(contentsOf: directory(documentID).appendingPathComponent(segment.audioFile))
        guard data.count % MemoryLayout<Float>.size == 0, data.count <= 16_000 * 25 * 4 else { throw MediaArchiveError.decodeFailed }
        return data.withUnsafeBytes { bytes in
            (0..<(bytes.count / 4)).map { bytes.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) }
        }
    }
    func recoverSegments(_ document: MediaDocument) throws -> MediaDocument {
        var result = document
        let known = Set(result.segments.map(\.id))
        for file in try FileManager.default.contentsOfDirectory(at: directory(document.id), includingPropertiesForKeys: nil) where file.pathExtension == "json" && file.lastPathComponent != "document.json" {
            guard let data = try? Data(contentsOf: file), var segment = try? JSONDecoder().decode(MediaSegment.self, from: data),
                  !known.contains(segment.id) else { continue }
            if segment.duration == 0,
               let attributes = try? FileManager.default.attributesOfItem(atPath: directory(document.id).appendingPathComponent(segment.audioFile).path),
               let bytes = attributes[.size] as? NSNumber {
                let duration = bytes.doubleValue / (16000 * 4)
                var recovered = MediaSegment(start: segment.start, duration: duration, source: segment.source)
                recovered.id = segment.id
                segment = recovered
            }
            result.segments.append(segment)
        }
        result.segments.sort { $0.start < $1.start }
        return result
    }
    func delete(_ id: UUID) throws { try FileManager.default.removeItem(at: directory(id)) }
}

/// Decodes only audio from a media asset. Disk chunks bound memory independently of file length.
enum MediaFileDecoder {
    static func decode(url: URL, document: MediaDocument, archive: MediaArchive) async throws -> MediaDocument {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw MediaArchiveError.noAudio }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration <= 4 * 3600 else { throw MediaArchiveError.tooLong }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        guard reader.canAdd(output) else { throw MediaArchiveError.decodeFailed }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? MediaArchiveError.decodeFailed }
        defer { reader.cancelReading() }
        var result = document
        var pending: [Float] = []
        pending.reserveCapacity(16_000 * 21)
        var sampleOffset = 0
        while true {
            try Task.checkCancellation()
            // Drain AVFoundation autoreleased buffers per decode step, not after a long file.
            let decoded: [Float]? = try autoreleasepool {
                guard let sample = output.copyNextSampleBuffer() else { return nil }
                guard let block = CMSampleBufferGetDataBuffer(sample) else { throw MediaArchiveError.decodeFailed }
                let byteCount = CMBlockBufferGetDataLength(block)
                guard byteCount > 0, byteCount % 4 == 0, byteCount <= 16_000 * 25 * 4 else { throw MediaArchiveError.decodeFailed }
                var values = [Float](repeating: 0, count: byteCount / 4)
                let status = values.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: byteCount, destination: $0.baseAddress!) }
                guard status == noErr else { throw MediaArchiveError.decodeFailed }
                return values
            }
            guard let values = decoded else { break }
            pending.append(contentsOf: values)
            while pending.count >= 16_000 * 20 {
                let chunk = Array(pending.prefix(16_000 * 20))
                let segment = MediaSegment(start: Double(sampleOffset) / 16000, duration: 20, source: "File")
                try archive.write(chunk, segment: segment, documentID: document.id)
                result.segments.append(segment)
                sampleOffset += chunk.count
                pending.removeFirst(chunk.count)
            }
        }
        guard reader.status == .completed else { throw reader.error ?? MediaArchiveError.decodeFailed }
        if !pending.isEmpty {
            let segment = MediaSegment(start: Double(sampleOffset) / 16000, duration: Double(pending.count) / 16000, source: "File")
            try archive.write(pending, segment: segment, documentID: document.id)
            result.segments.append(segment)
        }
        guard !result.segments.isEmpty else { throw MediaArchiveError.empty }
        return result
    }
}
