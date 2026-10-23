// ParakeetEngine.swift
// Dictari — on-device TranscriptionEngine backed by NVIDIA Parakeet TDT via FluidAudio.
//
// FluidAudio (github.com/FluidInference/FluidAudio, Apache 2.0) ships CoreML conversions of
// Parakeet and runs them on the Apple Neural Engine. Compared to Whisper this is a transducer
// rather than an encoder-decoder: it emits tokens as it consumes audio instead of decoding
// 30-second windows, which is where the speed difference comes from, and it does not
// hallucinate text on silence the way Whisper does.
//
// Trade-off vs WhisperKitEngine: Parakeet TDT v3 covers 25 European languages (German,
// Italian and English among them) at ~0.6B parameters. Anything outside that set still needs
// the Whisper backend, which is why both engines conform to `TranscriptionEngine` and the
// user's model choice selects between them.
//
// Concurrency: same shape as WhisperKitEngine — an actor owning the model state, with
// `transcribe` running off-actor because `AsrManager` performs its own serialization.

import CoreML
import Foundation
import FluidAudio

/// Transcription backend for Parakeet TDT models.
/// One instance per loaded model; build a new engine to switch models.
final actor ParakeetEngine: TranscriptionEngine {

    /// Human-readable name of the variant this engine was built for.
    private let displayName: String

    /// Which Parakeet weights this engine loads. Fixed for the engine's lifetime.
    private let variant: ParakeetVariant

    /// The live FluidAudio manager, created in `warmUp`.
    ///
    /// `nonisolated(unsafe)`: mirrors the invariant documented on `WhisperKitEngine.pipe` —
    /// each engine instance is warmed exactly once (a single write of `manager`/`isWarm`) and
    /// `AppCoordinator` only calls `transcribe` after warm-up has completed. Switching models
    /// builds a brand-new engine, so this is never re-written on a live instance.
    private nonisolated(unsafe) var manager: AsrManager?
    private nonisolated(unsafe) var isWarm = false

    /// Guards against concurrent `warmUp` calls racing to build the pipeline.
    private var warmUpTask: Task<Void, Error>?

    init(displayName: String, variant: ParakeetVariant = .v3) {
        self.displayName = displayName
        self.variant = variant
    }

    // MARK: - TranscriptionEngine

    func warmUp(progress: @escaping @Sendable (Double) -> Void) async throws {
        if isWarm { return }

        if let existing = warmUpTask {
            try await withTaskCancellationHandler {
                try await existing.value
            } onCancel: {
                existing.cancel()
            }
            return
        }

        let task = Task { () throws -> Void in
            try await self.performWarmUp(progress: progress)
        }
        warmUpTask = task

        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            warmUpTask = nil
        } catch {
            task.cancel()
            warmUpTask = nil
            throw error
        }
    }

    // `nonisolated` for the same reason as WhisperKitEngine: keep the inference call out of
    // the actor's isolation domain. FluidAudio serializes inference internally.
    nonisolated func transcribe(samples: [Float], language: String) async throws -> String {
        try await transcribeDetailed(samples: samples, language: language).text
    }

    /// One inference, with per-word confidence grouped from FluidAudio's token timings.
    /// Grouping is a linear pass over a few hundred tokens (measured in
    /// TranscriptConfidenceTests), so the plain `transcribe` pays it too rather than keeping a
    /// second copy of the inference code.
    nonisolated func transcribeDetailed(
        samples: [Float], language: String
    ) async throws -> TranscriptionOutput {
        guard let manager, isWarm else {
            throw TranscriptionError.notReady
        }
        guard !samples.isEmpty else { return TranscriptionOutput(text: "", words: []) }

        // Each dictation is an independent utterance, so it starts from a clean decoder
        // state. (Carrying state across utterances is what the streaming path is for.)
        var decoderState: TdtDecoderState
        do {
            decoderState = try TdtDecoderState()
        } catch {
            throw TranscriptionError.inferenceFailed(error.localizedDescription)
        }

        do {
            let result = try await manager.transcribe(
                samples,
                decoderState: &decoderState,
                language: Self.languageHint(for: language)
            )
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let words = ParakeetWordGrouping.words(from: result.tokenTimings ?? [])
            return TranscriptionOutput(
                text: text,
                words: words.isEmpty ? TranscriptionOutput.unscored(text).words : words
            )
        } catch {
            throw TranscriptionError.inferenceFailed(error.localizedDescription)
        }
    }

    /// Map our ISO 639-1 setting onto FluidAudio's `Language`.
    /// The hint drives script-aware token filtering on v3; `nil` means let the model decide.
    ///
    /// Measured, not assumed (docs/research/2026-09-24-asr-quality-benchmark.md): in
    /// FluidAudio 0.15.7 the hint only swaps a top-1 token whose *script* is wrong (Latin vs
    /// Cyrillic, …) and enables a French-only English blocklist. It cannot steer between
    /// Italian, German and English. On 152 synthetic clips pinned it/de/en produced
    /// byte-identical transcripts to `nil` (WER 6.4% both) and the paired per-clip latency
    /// difference was 0.5 ms (median). So "auto" stays `nil`, and an explicit language is still
    /// passed because it is free and does help Cyrillic-script languages. It also does not stop
    /// the drift we did observe — German with English jargon, fast or noisy, decoded as English.
    /// Internal (not private) so the opt-in ASR benchmark exercises this exact mapping.
    ///
    /// "auto" is the exception to "no hint": short Italian dictations sometimes came out in
    /// Cyrillic (reported 25 Sep 2026). Every language Dictari targets is written in Latin
    /// script, and the hint's only effect on it/de/en is to reject wrong-script tokens, so
    /// "auto" passes a Latin-script language. English is used because it has no side effects
    /// (the only language-specific rule is the French blocklist).
    nonisolated static func languageHint(for code: String) -> Language? {
        guard code != "auto", !code.isEmpty else { return .english }
        return Language(rawValue: code) ?? .english
    }

    func currentModelName() async -> String { displayName }

    // The same warm multilingual model decodes completed phrases without a second model.
    nonisolated var supportsBackgroundTranscription: Bool { true }

    // MARK: - Streaming

    /// Parakeet is the engine that can afford this. It is a transducer — a decode of 5 s of
    /// audio costs a fraction of real time on the ANE — so re-transcribing the utterance so
    /// far a few times per second is cheap enough to be worth doing for the preview.
    ///
    /// FluidAudio also ships *true* streaming encoders, which this deliberately does not use:
    /// `StreamingModelVariant.createManager()` returns cache-aware managers
    /// (`StreamingEouAsrManager`, `StreamingNemotronAsrManager`, `StreamingUnifiedAsrManager`)
    /// and there is a multilingual `StreamingNemotronMultilingualAsrManager` — but each is a
    /// separate model repo. The EOU and Unified ones are English-only, and the multilingual
    /// Nemotron is another 0.6 B download beside the one the user already has. TDT v3 also has
    /// a pseudo-streaming `SlidingWindowAsrManager`, but its window layout needs ~13 s of
    /// audio before the first update and it takes no language hint, which is worse than
    /// useless for dictation. See ChunkedStreamingSession for the full reasoning.
    nonisolated var supportsStreaming: Bool { true }

    nonisolated func startStream(language: String) throws -> any TranscriptionStream {
        guard manager != nil, isWarm else { throw TranscriptionError.notReady }
        return ChunkedStreamingSession(engine: self, language: language)
    }

    // MARK: - Warm-up implementation

    private func performWarmUp(progress: @escaping @Sendable (Double) -> Void) async throws {
        if isWarm { return }

        progress(0)

        // v3 is the multilingual variant (25 European languages); v2 is English-only.
        // The int8 encoder is FluidAudio's default and the reason the model stays small
        // enough for low-spec Macs. Ultra is a post-training of v3 with the same contract and
        // its own int8 encoder, so the same pinned-download and load path serves both.
        let modelDirectory = ModelFiles.parakeetDirectory(for: variant)
        let manifestModelID = variant.manifestModelID
        let version = ModelFiles.parakeetVersion(for: variant)
        do {
            // AsrModels.download() is not download-only (it opens Core ML bundles before
            // returning) and ModelHub.download() follows the repository's moving default
            // branch. Fetch every manifest file from the pinned revision instead, seeding
            // from FluidAudio's shared cache when it already holds the reviewed bytes.
            // Download is mapped to 0...0.9; loading and the ANE warm-up own the rest.
            try await ModelFiles.ensureBundledModel(
                modelID: manifestModelID,
                directory: modelDirectory,
                seedDirectory: ModelFiles.sharedFluidAudioParakeetDirectory(for: variant),
                progress: { p in progress(min(max(p, 0), 1) * 0.9) }
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TranscriptionError.modelUnavailable(error.localizedDescription)
        }
        try Task.checkCancellation()

        // AsrModels.load() calls ModelHub.loadModels(), whose failure handler can purge
        // and re-download after our hash check. Build AsrModels directly from local files
        // through the verified gate so no code path can replace trusted bytes mid-load.
        let models: AsrModels
        do {
            models = try await ModelFiles.withBundledVerification(
                modelID: manifestModelID, directory: modelDirectory
            ) {
                try Self.loadVerifiedLocalModels(
                    from: modelDirectory,
                    manifestModelID: manifestModelID,
                    version: version
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TranscriptionError.modelUnavailable(error.localizedDescription)
        }
        try Task.checkCancellation()

        let asr = AsrManager(config: .default)
        do {
            try await asr.loadModels(models)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TranscriptionError.modelUnavailable(error.localizedDescription)
        }
        try Task.checkCancellation()

        // Compile the ANE graph with a short dummy inference so the first real dictation is
        // not the one that pays for it. Failure is non-fatal.
        if var warmState = try? TdtDecoderState() {
            let silence = [Float](repeating: 0, count: 16_000 / 2)
            _ = try? await asr.transcribe(silence, decoderState: &warmState, language: nil)
        }
        try Task.checkCancellation()

        self.manager = asr
        isWarm = true
        progress(1)
    }

    /// Mirrors FluidAudio 0.17.7's v3-family/default-compute path without its cache-recovery
    /// wrapper. The four names, compute units and vocabulary parsing match AsrModels.load():
    /// v3 (int8 precision) and Ultra both ship Preprocessor, Encoder, Decoder and
    /// JointDecisionv3 under the same file names.
    private static func loadVerifiedLocalModels(
        from directory: URL, manifestModelID: String, version: AsrModelVersion
    ) throws -> AsrModels {
        let configuration = AsrModels.defaultConfiguration()

        func open(_ name: String, computeUnits: MLComputeUnits) throws -> MLModel {
            let modelConfig = MLModelConfiguration()
            modelConfig.computeUnits = computeUnits
            modelConfig.allowLowPrecisionAccumulationOnGPU = true
            return try MLModel(
                contentsOf: directory.appendingPathComponent(name), configuration: modelConfig
            )
        }

        let names = ModelNames.ASR.self
        let preprocessor = try open(names.preprocessorFile, computeUnits: .cpuOnly)
        let encoder = try open(names.encoderFile, computeUnits: configuration.computeUnits)
        let decoder = try open(names.decoderFile, computeUnits: configuration.computeUnits)
        let joint = try open(names.jointV3File, computeUnits: configuration.computeUnits)

        let data = try ModelFiles.verifiedPinnedData(
            modelID: manifestModelID,
            path: names.vocabularyFile,
            directory: directory
        )
        let json = try JSONSerialization.jsonObject(with: data)
        guard let words = json as? [String: String] else {
            throw AsrModelsError.loadingFailed("Vocabulary file has unexpected format")
        }
        var vocabulary: [Int: String] = [:]
        for (key, value) in words {
            if let tokenID = Int(key) { vocabulary[tokenID] = value }
        }

        return AsrModels(
            encoder: encoder, preprocessor: preprocessor, decoder: decoder,
            joint: joint, configuration: configuration, vocabulary: vocabulary, version: version
        )
    }
}

// MARK: - Word confidence

/// Turns FluidAudio's SentencePiece token timings into words.
///
/// A piece that starts with the word-boundary marker begins a new word; every other piece —
/// including punctuation, which Parakeet emits as its own piece — continues the current one.
/// FluidAudio 0.15.7 has already replaced "▁" with a space in `TokenTiming.token`, but the raw
/// marker is accepted too, so a package upgrade that stops normalising cannot silently merge
/// every word into one.
///
/// A word is only as certain as its weakest piece: a proper noun the model does not know is
/// typically spelled from a few confident pieces and one it was guessing at, and averaging
/// would hide exactly that piece.
enum ParakeetWordGrouping {
    static func words(from timings: [TokenTiming]) -> [TranscribedWord] {
        var words: [TranscribedWord] = []
        words.reserveCapacity(timings.count)
        var current = ""
        var confidence: Float?

        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { words.append(TranscribedWord(text: trimmed, confidence: confidence)) }
            current = ""
            confidence = nil
        }

        for timing in timings {
            let token = timing.token
            // Control pieces (<blank>, <pad>, <unk>, <|...|>) never reach the text.
            if token.isEmpty || (token.hasPrefix("<") && token.hasSuffix(">")) { continue }
            if token.hasPrefix(" ") || token.hasPrefix("\u{2581}") {
                flush()
                current = String(token.dropFirst())
            } else {
                current += token
            }
            if timing.confidence.isFinite {
                let score = min(max(timing.confidence, 0), 1)
                confidence = min(confidence ?? score, score)
            }
        }
        flush()
        return words
    }
}
