// AudioFixture.swift
// Generates real speech on the fly with `/usr/bin/say`, then decodes it to the 16 kHz mono
// Float32 PCM the transcription engines expect.
//
// This is what makes the transcription tests meaningful: they run actual audio through the
// actual model rather than asserting on mocks. `say` ships with macOS and has native German
// (Anna) and Italian (Alice) voices, so the German/Italian claims the product is sold on are
// checked, not assumed.

import AVFoundation
import Foundation

enum AudioFixture {

    enum FixtureError: Error, CustomStringConvertible {
        case sayFailed(Int32)
        case decodeFailed(String)

        var description: String {
            switch self {
            case .sayFailed(let code): return "`say` exited with status \(code)"
            case .decodeFailed(let m): return "could not decode fixture audio: \(m)"
            }
        }
    }

    /// Synthesize `text` with `voice` and return 16 kHz mono Float32 samples.
    /// `rate` is `say -r` in words per minute; nil keeps the voice's own pace.
    static func samples(text: String, voice: String, rate: Int? = nil) throws -> [Float] {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dictari-fixture-\(UUID().uuidString).aiff")
        defer { try? FileManager.default.removeItem(at: url) }

        try synthesize(text: text, voice: voice, rate: rate, to: url)
        return try decodeTo16kMono(url)
    }

    // MARK: - Synthesis

    private static func synthesize(text: String, voice: String, rate: Int?, to url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        // Always `-o`: fixtures are rendered to a file, never played through the speakers.
        var arguments = ["-v", voice, "-o", url.path]
        if let rate { arguments += ["-r", String(rate)] }
        process.arguments = arguments + [text]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw FixtureError.sayFailed(process.terminationStatus)
        }
    }

    // MARK: - Decoding

    /// Read an audio file and convert it to the engines' input format: 16 kHz, mono, Float32.
    private static func decodeTo16kMono(_ url: URL) throws -> [Float] {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw FixtureError.decodeFailed(error.localizedDescription)
        }

        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            throw FixtureError.decodeFailed("could not build the 16 kHz mono target format")
        }

        guard let converter = AVAudioConverter(from: file.processingFormat, to: target) else {
            throw FixtureError.decodeFailed("no converter from \(file.processingFormat)")
        }

        // Generous capacity: `say` output is a few seconds, and the ratio only ever shrinks
        // the frame count when downsampling from 22/44 kHz.
        let ratio = target.sampleRate / file.processingFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(file.length) * ratio) + 4096
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw FixtureError.decodeFailed("could not allocate the output buffer")
        }

        var readError: Error?
        var reachedEnd = false
        var conversionError: NSError?

        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            // Check the position before reading: AVAudioFile.read throws eofErr (-39) when
            // called at the end of the file rather than returning zero frames.
            if reachedEnd || file.framePosition >= file.length {
                reachedEnd = true
                inputStatus.pointee = .endOfStream
                return nil
            }
            let remaining = AVAudioFrameCount(min(file.length - file.framePosition, 8192))
            guard let input = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: remaining
            ) else {
                inputStatus.pointee = .endOfStream
                return nil
            }
            do {
                try file.read(into: input, frameCount: remaining)
            } catch {
                readError = error
                inputStatus.pointee = .endOfStream
                return nil
            }
            if input.frameLength == 0 {
                reachedEnd = true
                inputStatus.pointee = .endOfStream
                return nil
            }
            inputStatus.pointee = .haveData
            return input
        }

        if let readError {
            throw FixtureError.decodeFailed(readError.localizedDescription)
        }
        if let conversionError, status == .error {
            throw FixtureError.decodeFailed(conversionError.localizedDescription)
        }
        guard let channel = output.floatChannelData?[0], output.frameLength > 0 else {
            throw FixtureError.decodeFailed("conversion produced no samples")
        }

        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}

// MARK: - Text comparison

enum TranscriptMatch {

    /// Lowercase, strip punctuation, collapse whitespace — so comparisons survive the
    /// casing and punctuation choices a model is free to make.
    static func normalize(_ text: String) -> String {
        let stripped = text.unicodeScalars
            .map { CharacterSet.punctuationCharacters.contains($0) ? " " : Character($0) }
            .map(String.init)
            .joined()
        return stripped
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// Fraction of `expected`'s words that appear in `actual`, in 0...1.
    /// A loose measure on purpose: it catches "the model produced unrelated text or nothing"
    /// without failing on a single mis-heard word, which no ASR system is free of.
    static func wordRecall(expected: String, actual: String) -> Double {
        let wanted = normalize(expected).split(separator: " ").map(String.init)
        guard !wanted.isEmpty else { return 1 }
        let got = Set(normalize(actual).split(separator: " ").map(String.init))
        let hits = wanted.filter { got.contains($0) }.count
        return Double(hits) / Double(wanted.count)
    }
}
