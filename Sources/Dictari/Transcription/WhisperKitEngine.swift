// WhisperKitEngine.swift
// Dictari — default on-device TranscriptionEngine backed by WhisperKit.
//
// WhisperKit (github.com/argmaxinc/WhisperKit) runs Whisper CoreML models on the
// Apple Neural Engine / GPU. Models are downloaded from Hugging Face on first use
// and cached on disk. All transcription is local — the only network access is the
// one-time model download.
//
// Concurrency model: the engine is an `actor`. The `TranscriptionEngine` protocol is
// `Sendable`, and the underlying `WhisperKit` instance carries mutable model state, so
// we isolate it inside an actor rather than dealing with manual locking. The protocol's
// `async` methods map naturally onto actor-isolated methods.

import Foundation
import Hub
import NaturalLanguage
import Tokenizers
import WhisperKit

/// Default transcription backend. One instance per loaded model; create a new engine
/// (via `AppCoordinator.reloadModel()`) to switch models.
final actor WhisperKitEngine: TranscriptionEngine {

    /// WhisperKit model variant id, e.g. "openai_whisper-large-v3-v20240930_turbo".
    private let modelName: String

    /// The live WhisperKit instance, created in `warmUp`.
    /// `nonisolated(unsafe)`: WhisperKit's `transcribe` is `@concurrent`/non-`Sendable`, so
    /// the `nonisolated` `transcribe(samples:)` must read this off-actor. Soundness rests on
    /// a strict happens-before invariant enforced by the caller: each engine instance is
    /// warmed exactly once (a single write of `pipe`/`isWarm`) and `AppCoordinator` only
    /// calls `transcribe` after `modelState == .ready` — i.e. after that warm-up has fully
    /// completed (awaited). Switching models builds a brand-new engine, so `pipe` is never
    /// re-written on a live instance. Reads therefore never overlap the single write.
    private nonisolated(unsafe) var pipe: WhisperKit?
    private nonisolated(unsafe) var isWarm = false

    /// Guards against concurrent `warmUp` calls racing to build the pipeline.
    private var warmUpTask: Task<Void, Error>?

    init(modelName: String) {
        self.modelName = modelName
    }

    // MARK: - TranscriptionEngine

    func warmUp(progress: @escaping @Sendable (Double) -> Void) async throws {
        if isWarm { return }

        // Coalesce concurrent warm-up requests onto a single in-flight task.
        if let existing = warmUpTask {
            try await withTaskCancellationHandler {
                try await existing.value
            } onCancel: {
                existing.cancel()
            }
            return
        }

        let task = Task { [modelName] () throws -> Void in
            try await self.performWarmUp(modelName: modelName, progress: progress)
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
            // Allow a later retry after a failure.
            task.cancel()
            warmUpTask = nil
            throw error
        }
    }

    // `nonisolated`: WhisperKit's `transcribe` is `@concurrent` and `WhisperKit` is not
    // Sendable, so the call cannot cross the actor boundary. Running this method off the
    // actor (reading the `nonisolated(unsafe)` `pipe`/`isWarm`) is the clean way to satisfy
    // region isolation. WhisperKit serializes its own inference internally.
    nonisolated func transcribe(samples: [Float], language: String) async throws -> String {
        try await transcribeDetailed(samples: samples, language: language).text
    }

    /// Per-word confidence here is a **segment** score spread over the segment's words:
    /// exp(avgLogprob), the geometric-mean token probability. It costs nothing extra, which is
    /// the point — the decode already computed it. It cannot single out the one misheard name
    /// in a long, otherwise confident segment; it flags whole segments Whisper was unsure of.
    ///
    /// Real per-word probabilities are available later if they prove worth it: set
    /// `wordTimestamps: true` in `decodingOptions(for:)` and read `segment.words`
    /// (`WordTiming.probability`, the mean of that word's token probabilities). That adds an
    /// alignment pass over the cross-attention weights on every dictation, i.e. latency on the
    /// stop→inject path, so it was deliberately not switched on here.
    nonisolated func transcribeDetailed(
        samples: [Float], language: String
    ) async throws -> TranscriptionOutput {
        guard let pipe, isWarm else {
            throw TranscriptionError.notReady
        }
        guard !samples.isEmpty else { return TranscriptionOutput(text: "", words: []) }

        do {
            let options = Self.decodingOptions(
                for: try await Self.constrainedLanguage(language, samples: samples, pipe: pipe)
            )
            let results = try await pipe.transcribe(audioArray: samples, decodeOptions: options)
            // Concatenate the text of every returned result/segment, then trim.
            let combined = results.map(\.text).joined(separator: " ")
            let text = Self.cleanedTranscript(combined)
            var words: [TranscribedWord] = []
            for segment in results.flatMap(\.segments) {
                let confidence = TranscriptConfidence.confidence(
                    fromAverageLogProbability: segment.avgLogprob
                )
                for piece in segment.text.split(whereSeparator: \.isWhitespace) {
                    // skipSpecialTokens is on, but a stray "<|…|>" must not become a word.
                    guard !piece.hasPrefix("<|") else { continue }
                    words.append(TranscribedWord(text: String(piece), confidence: confidence))
                }
            }
            return TranscriptionOutput(
                text: text,
                words: words.isEmpty ? TranscriptionOutput.unscored(text).words : words
            )
        } catch let error as TranscriptionError {
            throw error
        } catch {
            throw TranscriptionError.inferenceFailed(error.localizedDescription)
        }
    }

    func currentModelName() async -> String {
        // Prefer the descriptor's human-readable name; fall back to the raw variant id.
        ModelDescriptor.curated
            .first(where: { $0.whisperKitName == modelName })?
            .displayName ?? modelName
    }

    // `supportsStreaming` stays at the protocol default of `false`, on purpose. Whisper pads
    // every input to a 30 s window, so a hypothesis over 1 s of speech costs the same as one
    // over 30 s — the re-transcription trick that is cheap on Parakeet's transducer is
    // ruinous here. Worse, Whisper invents text on near-silence, so the early passes would
    // put words in the preview that the user never said. If Whisper ever gets partials they
    // have to come from WhisperKit's own `AudioStreamTranscriber`, not from this route.

    // MARK: - Warm-up implementation

    private func performWarmUp(
        modelName: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        if isWarm { return }

        // Report 0 immediately so the UI can show a determinate-ish bar from the start.
        progress(0)

        // WhisperKit's own downloader follows the repository's moving default branch. Fetch
        // every manifest file from the pinned revision into the variant folder ourselves
        // (files already matching are kept), then hand WhisperKit that local folder with
        // `download: false`, which also keeps a normal offline warm-up off the network.
        // Download is mapped to 0...0.9; loading owns the rest.
        let modelFolder = ModelFiles.whisperKitDirectory(forVariant: modelName)
        let downloadedBytes: Int64
        do {
            downloadedBytes = try await ModelFiles.ensureBundledModel(
                modelID: modelName,
                directory: modelFolder,
                progress: { p in progress(min(max(p, 0), 1) * 0.9) }
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TranscriptionError.modelUnavailable(error.localizedDescription)
        }
        try Task.checkCancellation()

        // WhisperKit.loadModels() otherwise calls ModelUtilities.loadTokenizer(), whose
        // local-parse failure falls back to an unpinned Hub download. Build the tokenizer
        // from exactly two reviewed JSON byte arrays and install it before loadModels().
        let tokenizerID: String
        let tokenizerRepo: String
        switch modelName {
        case "openai_whisper-base":
            tokenizerID = "tokenizer-whisper-base"
            tokenizerRepo = "openai/whisper-base"
        case "openai_whisper-large-v3-v20240930_turbo":
            tokenizerID = "tokenizer-whisper-large-v3"
            tokenizerRepo = "openai/whisper-large-v3"
        default:
            throw ModelIntegrityError.missingModel(modelName)
        }
        // Reuse WhisperKit's existing tokenizer cache so an already-installed model still
        // works offline after an app upgrade. We parse only the two verified JSON byte
        // arrays below; any other cache neighbors are never passed to a Hub loader.
        let tokenizerDirectory = HubApi(downloadBase: AppPaths.models).localRepoLocation(
            HubApi.Repo(id: tokenizerRepo)
        )
        do {
            try await ModelFiles.ensureBundledModel(
                modelID: tokenizerID, directory: tokenizerDirectory
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TranscriptionError.modelUnavailable(error.localizedDescription)
        }
        let verifiedTokenizer = try await ModelFiles.withBundledVerification(
            modelID: tokenizerID, directory: tokenizerDirectory
        ) {
            let configBytes = try ModelFiles.verifiedPinnedData(
                modelID: tokenizerID, path: "tokenizer_config.json",
                directory: tokenizerDirectory
            )
            let tokenizerBytes = try ModelFiles.verifiedPinnedData(
                modelID: tokenizerID, path: "tokenizer.json",
                directory: tokenizerDirectory
            )
            let config = try JSONDecoder().decode(Config.self, from: configBytes)
            let data = try JSONDecoder().decode(Config.self, from: tokenizerBytes)
            // Match WhisperKit 0.18.0's local path exactly (PreTrainedTokenizer,
            // not the remote AutoTokenizer fallback).
            let tokenizer = try PreTrainedTokenizer(tokenizerConfig: config, tokenizerData: data)
            return VerifiedWhisperTokenizer(tokenizer: tokenizer)
        }
        try Task.checkCancellation()

        // Build the pipeline without auto-loading so the manifest gate can run first.
        let config = WhisperKitConfig(
            model: modelName,
            downloadBase: AppPaths.models,
            modelFolder: modelFolder.path,
            verbose: false,
            logLevel: .error,
            prewarm: false,
            load: false,
            download: false
        )

        let kit: WhisperKit
        do {
            kit = try await WhisperKit(config)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TranscriptionError.modelUnavailable(error.localizedDescription)
        }
        try Task.checkCancellation()

        // Verify exactly the folder WhisperKit will load from.
        guard let loadFolder = kit.modelFolder else {
            throw TranscriptionError.modelUnavailable("The downloaded model folder could not be found.")
        }

        // Bridge WhisperKit's Foundation `Progress` (load only: WhisperKit no longer
        // downloads anything) onto the remainder of the 0...1 bar. KVO on
        // `fractionCompleted`; the observer is retained for the duration of load.
        let loadStart = downloadedBytes > 0 ? 0.9 : 0
        let observer = ProgressBridge(kit.progress) { fraction in
            progress(loadStart + (1 - loadStart) * fraction)
        }
        defer { observer.invalidate() }

        do {
            try await ModelFiles.withBundledVerification(
                modelID: modelName, directory: loadFolder
            ) {
                kit.tokenizer = verifiedTokenizer
                // The upstream tokenizer loader also sets this flag; bypassing it must not
                // silently make a multilingual model decode as English-only.
                kit.textDecoder.isModelMultilingual = true
                try await kit.loadModels()
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TranscriptionError.modelUnavailable(error.localizedDescription)
        }
        try Task.checkCancellation()

        // Compile the ANE/GPU graph with one tiny dummy inference (~0.5s of silence at 16 kHz),
        // while `kit` is still a local (disconnected region) so it can cross into WhisperKit's
        // `@concurrent` transcribe without a data-race diagnostic. Failure here is non-fatal —
        // the graph compiles on first real use instead.
        let silence = [Float](repeating: 0, count: 16_000 / 2)
        do {
            _ = try await kit.transcribe(
                audioArray: silence,
                decodeOptions: DecodingOptions(verbose: false, task: .transcribe, language: "en")
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Dummy inference failed — keep the loaded model but report readiness anyway.
        }
        try Task.checkCancellation()

        self.pipe = kit
        isWarm = true
        progress(1)
    }

    // MARK: - Helpers

    /// Internal (not private) so the opt-in ASR benchmark measures exactly these options.
    ///
    /// Everything else is left at WhisperKit's defaults on purpose. On whisper-base, 152
    /// synthetic IT/DE/EN clips (docs/research/2026-09-24-asr-quality-benchmark.md), relative
    /// to these options in auto mode (WER 23.2–23.7%, which moves ±0.5 pt run to run because
    /// temperature fallback samples):
    /// - temperatureFallbackCount 0 → 26.5% (worse); 1 or 2 → 24.0–24.3% (no gain, slower p95).
    /// - Dropping the compression-ratio / log-prob thresholds → 25.7% (worse).
    /// - usePrefillPrompt false → 29.4% (much worse), though it was the only knob that
    ///   returned empty text on non-speech.
    /// - withoutTimestamps false → 23.9%, ~+140 ms p50. suppressBlank → 24.0%, no change.
    /// - Suppressing "[", "(" and "♪" tokens does not stop non-speech hallucination: the
    ///   model writes "*Musica*", "you" or "e" instead of "[Musica]"/"[BLANK_AUDIO]".
    /// - A pinned language beats auto in all four paired comparisons: −0.6 to −1.3 pt WER
    ///   overall (Italian −1.0 to −3.0 pt), 100% vs 96–97% language ID, and a lower p50 every
    ///   time (−79 ms in the least loaded run) because the detection pass is skipped. That is a settings default question (per-app/per-profile
    ///   language already exists), not something to hard-code here.
    nonisolated static func decodingOptions(for language: String) -> DecodingOptions {
        let isAuto = language == "auto" || language.isEmpty
        // "auto" => let WhisperKit detect the language (language nil + detectLanguage true).
        // Otherwise pin to the ISO 639-1 code.
        return DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: isAuto ? nil : language,
            detectLanguage: isAuto ? true : false,
            skipSpecialTokens: true,
            withoutTimestamps: true
        )
    }

    /// "Auto" with several spoken languages: run Whisper's language pass, keep the best of the
    /// user's own languages, then decode pinned to it. Plain auto picks among all 99 languages,
    /// so a short Italian clip could come out as Spanish; pinning is also measurably better
    /// (see `decodingOptions`). The extra cost is one encoder pass over at most 30 s, paid only
    /// in auto with more than one spoken language — a single one is pinned upstream for free.
    private nonisolated static func constrainedLanguage(
        _ language: String, samples: [Float], pipe: WhisperKit
    ) async throws -> String {
        let spoken = SpokenLanguages.current.withLock { $0 }
        guard SpokenLanguages.isAuto(language), spoken.count > 1 else { return language }
        guard let detection = try? await pipe.detectLangauge(audioArray: samples),
              let best = SpokenLanguages.best(of: detection.langProbs, among: spoken) else {
            return language
        }
        return best
    }

    /// Trim whitespace and collapse the doubled spaces that segment-joining can introduce.
    private static func cleanedTranscript(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("  ") else { return trimmed }
        return trimmed
            .split(whereSeparator: { $0 == " " })
            .joined(separator: " ")
    }
}

/// Local-only equivalent of WhisperKit 0.18.0's WhisperTokenizerWrapper. Its initializer
/// is internal upstream, so Dictari cannot construct it from verified in-memory JSON. Keep
/// this adapter's token IDs and word splitting in parity tests when upgrading WhisperKit.
final class VerifiedWhisperTokenizer: WhisperTokenizer, @unchecked Sendable {
    private let tokenizer: any Tokenizer
    let specialTokens: SpecialTokens
    let allLanguageTokens: Set<Int>

    init(tokenizer: any Tokenizer) {
        self.tokenizer = tokenizer
        let tokens = SpecialTokens(
            endToken: tokenizer.convertTokenToId("<|endoftext|>") ?? 50257,
            englishToken: tokenizer.convertTokenToId("<|en|>") ?? 50259,
            noSpeechToken: tokenizer.convertTokenToId("<|nospeech|>") ?? 50362,
            noTimestampsToken: tokenizer.convertTokenToId("<|notimestamps|>") ?? 50363,
            specialTokenBegin: tokenizer.convertTokenToId("<|endoftext|>") ?? 50257,
            startOfPreviousToken: tokenizer.convertTokenToId("<|startofprev|>") ?? 50361,
            startOfTranscriptToken: tokenizer.convertTokenToId("<|startoftranscript|>") ?? 50258,
            timeTokenBegin: tokenizer.convertTokenToId("<|0.00|>") ?? 50364,
            transcribeToken: tokenizer.convertTokenToId("<|transcribe|>") ?? 50359,
            translateToken: tokenizer.convertTokenToId("<|translate|>") ?? 50358,
            whitespaceToken: tokenizer.convertTokenToId(" ") ?? 220
        )
        specialTokens = tokens
        allLanguageTokens = Set(
            Constants.languages.compactMap { tokenizer.convertTokenToId("<|\($0.value)|>") }
                .filter { $0 > tokens.specialTokenBegin }
        )
    }

    func encode(text: String) -> [Int] { tokenizer.encode(text: text) }
    func decode(tokens: [Int]) -> String { tokenizer.decode(tokens: tokens) }
    func convertTokenToId(_ token: String) -> Int? { tokenizer.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { tokenizer.convertIdToToken(id) }

    private func splitTokensOnUnicode(tokens: [Int]) -> (words: [String], wordTokens: [[Int]]) {
        let decodedFull = tokenizer.decode(tokens: tokens)
        let replacementString = "\u{fffd}"
        var words: [String] = []
        var wordTokens: [[Int]] = []
        var currentTokens: [Int] = []

        for token in tokens {
            currentTokens.append(token)
            let decoded = tokenizer.decode(tokens: currentTokens)
            var hasUnicodeInFullString = false
            if let range = decoded.range(of: replacementString) {
                hasUnicodeInFullString = decodedFull[range] == replacementString
            }
            if !decoded.contains(replacementString) || hasUnicodeInFullString {
                words.append(decoded)
                wordTokens.append(currentTokens)
                currentTokens = []
            }
        }
        return (words, wordTokens)
    }

    private func splitTokensOnSpaces(tokens: [Int]) -> (words: [String], wordTokens: [[Int]]) {
        let (subwords, subwordTokensList) = splitTokensOnUnicode(tokens: tokens)
        var words: [String] = []
        var wordTokens: [[Int]] = []

        for (subword, subwordTokens) in zip(subwords, subwordTokensList) {
            let special = subwordTokens.first! >= specialTokens.specialTokenBegin
            let withSpace = subword.hasPrefix(" ")
            var punctuation = false
            if let strippedSubword = UnicodeScalar(subword.trimmingCharacters(in: .whitespaces)) {
                punctuation = CharacterSet.punctuationCharacters.contains(strippedSubword)
            }
            if special || withSpace || punctuation || words.isEmpty {
                words.append(subword)
                wordTokens.append(subwordTokens)
            } else {
                words[words.count - 1] += subword
                wordTokens[words.count - 1].append(contentsOf: subwordTokens)
            }
        }
        return (words, wordTokens)
    }

    func splitToWordTokens(tokenIds: [Int]) -> (words: [String], wordTokens: [[Int]]) {
        let decodedWords = tokenizer.decode(
            tokens: tokenIds.filter { $0 < specialTokens.specialTokenBegin }
        )
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(decodedWords)
        let languageCode = recognizer.dominantLanguage?.rawValue
        if ["zh", "ja", "th", "lo", "my", "yue"].contains(languageCode) {
            return splitTokensOnUnicode(tokens: tokenIds)
        }
        return splitTokensOnSpaces(tokens: tokenIds)
    }
}

// MARK: - Progress bridge

/// Bridges a Foundation `Progress` (WhisperKit's download/load progress) to a
/// `@Sendable (Double) -> Void` callback via KVO on `fractionCompleted`.
///
/// `Progress` and `NSKeyValueObservation` are not `Sendable`; this object is created,
/// used, and invalidated entirely within a single actor-isolated call, and the KVO
/// callback only forwards a `Double` to a `@Sendable` closure, so there is no shared
/// mutable state crossing concurrency domains. Marked `@unchecked Sendable` solely so it
/// can be captured by the report closure; it is never sent across actors.
private final class ProgressBridge: @unchecked Sendable {
    private var observation: NSKeyValueObservation?

    init(_ progress: Progress, report: @escaping @Sendable (Double) -> Void) {
        // Emit the current value once, then on every change. Clamp to 0...1.
        report(min(max(progress.fractionCompleted, 0), 1))
        observation = progress.observe(\.fractionCompleted, options: [.new]) { prog, _ in
            report(min(max(prog.fractionCompleted, 0), 1))
        }
    }

    func invalidate() {
        observation?.invalidate()
        observation = nil
    }

    deinit {
        observation?.invalidate()
    }
}
