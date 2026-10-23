import Foundation
import os

/// Completes phrases while capture continues, without publishing partial text. Each phrase
/// is decoded once, on one worker. A pause is required: a long uninterrupted phrase
/// stays on the batch path instead of cutting a word or repeatedly decoding a growing prefix.
final class BackgroundTranscriptionSession: @unchecked Sendable {
    struct Tuning: Sendable {
        var minimumSeconds: Double = 3
        var silenceSeconds: Double = 0.45
        var maximumSeconds: Double = 15
        var queuedChunks: Int = 256
    }

    private struct State {
        var receivedCount = 0
        var accepting = true
        var invalidFeed = false
        var cancelled = false
        var inferenceRunning = false
        var finalSamples: [Float]?
    }

    /// FluidAudio's `ASRConstants.minimumRequiredSamples` at 16 kHz (300 ms). Kept as a
    /// constant so this engine-agnostic session does not import FluidAudio.
    static let minimumDecodeSamples = 4_800

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let input: AsyncStream<[Float]>.Continuation
    private let worker = OSAllocatedUnfairLock<Task<TranscriptionOutput, Error>?>(initialState: nil)

    init(
        engine: any TranscriptionEngine,
        language: String,
        tuning: Tuning = Tuning(),
        onFinished: @escaping @Sendable () -> Void = {}
    ) {
        let (chunks, input) = AsyncStream<[Float]>.makeStream(
            bufferingPolicy: .bufferingOldest(max(1, tuning.queuedChunks))
        )
        self.input = input
        // This is work for an active user interaction, even though it has no visible preview.
        // Utility QoS can defer native inference behind other work until it falls behind speech.
        // Keep it off-main and bound the number of calls, rather than lowering its priority.
        let task = Task.detached(priority: .userInitiated) { [self] in
            defer { onFinished() }
            return try await decode(chunks, engine: engine, language: language, tuning: tuning)
        }
        worker.withLock { $0 = task }
    }

    /// Absolute offsets detect a missing/reordered pump callback. The final recording is
    /// authoritative; a broken incremental feed must fall back instead of silently losing words.
    func append(_ samples: [Float], at offset: Int) {
        guard !samples.isEmpty else { return }
        state.withLock { st in
            guard st.accepting, !st.cancelled, !st.invalidFeed else { return }
            guard offset == st.receivedCount else {
                st.invalidFeed = true
                return
            }
            st.receivedCount += samples.count
            if case .dropped = input.yield(samples) { st.invalidFeed = true }
        }
    }

    /// Capture may stop before its last pump callback runs. Finalize from the original PCM,
    /// starting at the last committed sample, so those last syllables are always included.
    func finish(samples: [Float]) async throws -> String {
        try await finishDetailed(samples: samples).text
    }

    /// `finish(samples:)` with each phrase's words carried through the stitching. The text is
    /// identical: phrases are joined with one space exactly as before.
    func finishDetailed(samples: [Float]) async throws -> TranscriptionOutput {
        state.withLock { st in
            if st.accepting {
                if st.receivedCount > samples.count { st.invalidFeed = true }
                st.finalSamples = samples
                st.accepting = false
            }
            input.finish()
        }
        return try await withTaskCancellationHandler {
            guard let task = worker.withLock({ $0 }) else { throw CancellationError() }
            return try await task.value
        } onCancel: {
            self.cancel()
        }
    }

    /// Returns whether a native call still owns the engine. The coordinator can immediately
    /// reuse an idle engine; an uncooperative call must retain the existing quarantine lease.
    @discardableResult
    func cancel() -> Bool {
        let running = state.withLock { st in
            st.cancelled = true
            st.accepting = false
            input.finish()
            return st.inferenceRunning
        }
        worker.withLock { $0 }?.cancel()
        return running
    }

    private func transcribe(
        _ samples: [Float], engine: any TranscriptionEngine, language: String
    ) async throws -> TranscriptionOutput {
        try state.withLock { st in
            guard !st.cancelled, !Task.isCancelled else { throw CancellationError() }
            st.inferenceRunning = true
        }
        defer { state.withLock { $0.inferenceRunning = false } }
        var output = try await engine.transcribeDetailed(samples: samples, language: language)
        try Task.checkCancellation()
        guard !state.withLock({ $0.cancelled }) else { throw CancellationError() }
        output.text = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return output
    }

    private func decode(
        _ chunks: AsyncStream<[Float]>, engine: any TranscriptionEngine,
        language: String, tuning: Tuning
    ) async throws -> TranscriptionOutput {
        var segmenter = BackgroundPhraseSegmenter(tuning: tuning)
        var committedCount = 0
        var phrases: [TranscriptionOutput] = []
        var phraseStarts: [Int] = []
        var backgroundFailed = false

        for await chunk in chunks {
            let status = state.withLock { ($0.cancelled, $0.invalidFeed, $0.finalSamples != nil) }
            if status.0 { throw CancellationError() }
            // At stop, bypass queued work and decode only the authoritative remaining PCM.
            if status.2 { break }
            guard !status.1, !backgroundFailed else { continue }
            for phrase in segmenter.append(chunk) {
                if state.withLock({ $0.finalSamples != nil }) { break }
                do {
                    let output = try await transcribe(phrase, engine: engine, language: language)
                    // A missed phrase is not silence: retry the full recording at stop.
                    guard !output.text.isEmpty else { backgroundFailed = true; break }
                    phrases.append(output)
                    phraseStarts.append(committedCount)
                    committedCount += phrase.count
                } catch {
                    if state.withLock({ $0.cancelled }) || Task.isCancelled { throw CancellationError() }
                    backgroundFailed = true
                    break
                }
            }
        }

        let (samples, invalidFeed) = try state.withLock { st in
            guard !st.cancelled, let samples = st.finalSamples else { throw CancellationError() }
            return (samples, st.invalidFeed)
        }
        defer { state.withLock { $0.finalSamples = nil } }
        if invalidFeed || backgroundFailed || committedCount > samples.count {
            return try await transcribe(samples, engine: engine, language: language)
        }
        if committedCount < samples.count {
            // Pure digital silence after a committed phrase needs no inference. Quiet speech
            // is deliberately NOT filtered here; recovery/proximity policy stays in the app.
            if committedCount == 0 || samples[committedCount...].contains(where: { $0 != 0 }) {
                var start = committedCount
                var replaced: TranscriptionOutput?
                // Parakeet refuses a decode under 300 ms, and that throw failed the whole
                // dictation, decoded phrases included (recovery 99FB294A, 9 Oct 2026: 5.04 s
                // phrase + 149 ms of room noise). Padding the slice is not the answer: alone,
                // that noise decodes as "Yeah.". Re-decode the last phrase with it instead, so
                // the model hears it in context exactly as the batch path would.
                if samples.count - start < Self.minimumDecodeSamples, let last = phraseStarts.popLast() {
                    replaced = phrases.removeLast()
                    start = last
                }
                let tail = Array(samples[start...])
                let output = try await transcribe(tail, engine: engine, language: language)
                if let kept = output.text.isEmpty ? replaced : output { phrases.append(kept) }
            }
        }
        return TranscriptionOutput.joined(phrases)
    }
}

/// Linear, bounded pause detection, run on the worker rather than the realtime tap or UI.
/// Boundary decisions use complete 10 ms frames and persist across arbitrary pump slices.
struct BackgroundPhraseSegmenter {
    private let minimumSamples: Int
    private let silenceSamples: Int
    private let maximumSamples: Int
    private var samples: [Float] = []
    private var frameEnergy: Float = 0
    private var frameCount = 0
    private var peakRMS: Float = 0
    private var quietCount = 0
    private var sawSpeech = false
    private(set) var suspended = false

    init(tuning: BackgroundTranscriptionSession.Tuning = .init()) {
        minimumSamples = max(160, Int(tuning.minimumSeconds * 16_000))
        silenceSamples = max(160, Int(tuning.silenceSeconds * 16_000))
        maximumSamples = max(minimumSamples + silenceSamples, Int(tuning.maximumSeconds * 16_000))
        samples.reserveCapacity(maximumSamples)
    }

    mutating func append(_ input: [Float]) -> [[Float]] {
        guard !suspended else { return [] }
        var complete: [[Float]] = []
        for sample in input {
            // No hard cut inside speech and no unbounded background buffer. The complete
            // recording already exists in capture and will supply this suffix at stop.
            guard samples.count < maximumSamples else {
                suspended = true
                samples.removeAll(keepingCapacity: false)
                break
            }
            samples.append(sample)
            frameEnergy += sample * sample
            frameCount += 1
            guard frameCount == 160 else { continue }
            let rms = (frameEnergy / 160).squareRoot()
            frameEnergy = 0
            frameCount = 0
            peakRMS = max(peakRMS, rms)
            // Only a sustained, very quiet interval can close a phrase. Relative threshold
            // retains soft consonants; the absolute cap avoids treating quiet words as pauses
            // after a loud syllable. Background noise simply keeps the batch fallback active.
            let quietThreshold = max(0.0001, min(0.0015, peakRMS * 0.04))
            if rms > quietThreshold {
                sawSpeech = true
                quietCount = 0
            } else if sawSpeech {
                quietCount += 160
            }
            if samples.count >= minimumSamples, quietCount >= silenceSamples {
                complete.append(samples)
                samples = []
                samples.reserveCapacity(maximumSamples)
                peakRMS = 0
                quietCount = 0
                sawSpeech = false
            }
        }
        return complete
    }
}
