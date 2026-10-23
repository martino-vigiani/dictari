// TranscriptionEngine.swift
// Dictari — abstraction over the local speech-to-text backend.
// The default implementation is WhisperKitEngine; an MLX engine can later
// conform to the same protocol so the engine is swappable at runtime.

import Foundation

/// On-device transcription backend. All work is local; no network except first model download.
protocol TranscriptionEngine: AnyObject, Sendable {
    /// Load and warm up the model (one dummy inference). Idempotent.
    /// `progress` reports download/load progress 0...1 when available; may be called on any thread.
    func warmUp(progress: @escaping @Sendable (Double) -> Void) async throws

    /// Transcribe finished 16 kHz mono Float32 PCM samples.
    /// `language` is an ISO 639-1 code or "auto". Returns trimmed text ("" == no speech).
    func transcribe(samples: [Float], language: String) async throws -> String

    /// The same inference as `transcribe`, plus the words it was built from and how sure the
    /// model was of each. `text` is exactly what `transcribe` returns for the same input.
    /// Engines without scores inherit the default below (words with nil confidence).
    func transcribeDetailed(samples: [Float], language: String) async throws -> TranscriptionOutput

    /// Display name of the currently loaded model.
    func currentModelName() async -> String

    /// Whether this warm backend can afford once-per-phrase background inference. This is
    /// separate from the legacy, repeatedly decoded live-preview experiment.
    var supportsBackgroundTranscription: Bool { get }

    // MARK: - Streaming (optional capability)

    /// Whether this engine can emit partial transcripts while the user is still speaking.
    /// Defaults to `false`, so an engine that only knows how to transcribe a finished
    /// utterance stays a valid `TranscriptionEngine` without writing a line of code.
    var supportsStreaming: Bool { get }

    /// Open a live session for one utterance. Feed it audio with `append`, read hypotheses
    /// from `updates`, and end it with `finish()`, whose return value is the text to insert.
    ///
    /// Synchronous and non-isolated on purpose: this sits on the start-dictation path, which
    /// has a 150 ms budget, so it must not cost an actor hop or an await.
    /// Throws `TranscriptionError.streamingUnavailable` when `supportsStreaming` is `false`.
    func startStream(language: String) throws -> any TranscriptionStream
}

extension TranscriptionEngine {
    func transcribeDetailed(samples: [Float], language: String) async throws -> TranscriptionOutput {
        TranscriptionOutput.unscored(try await transcribe(samples: samples, language: language))
    }

    var supportsBackgroundTranscription: Bool { false }
    var supportsStreaming: Bool { false }

    func startStream(language: String) throws -> any TranscriptionStream {
        throw TranscriptionError.streamingUnavailable
    }
}

// MARK: - Streaming

/// The incremental strategy is chosen once, before capture starts, and then frozen into the
/// recording context. A settings or model change while somebody is speaking therefore applies
/// only to the next dictation. Exactly one of these paths may own an engine for a recording.
enum RecordingTranscriptionMode: Equatable, Sendable {
    case batch
    case background
    case realtime

    static func select(
        realtimeEnabled: Bool?,
        modelReady: Bool,
        supportsStreaming: Bool,
        supportsBackground: Bool
    ) -> Self {
        guard modelReady else { return .batch }
        if realtimeEnabled == true, supportsStreaming { return .realtime }
        if supportsBackground { return .background }
        return .batch
    }

    static func fallbackAfterStreamingFailure(supportsBackground: Bool) -> Self {
        supportsBackground ? .background : .batch
    }

    var streamsSamples: Bool { self != .batch }
}

/// One result from a live session: either a hypothesis that may still change, or the
/// finished transcript. Exactly one update with `isFinal == true` is ever emitted, and it
/// carries the same string `finish()` returns.
struct TranscriptionUpdate: Equatable, Sendable {
    let text: String
    let isFinal: Bool
}

/// Generation fencing for a provisional live transcript. Final updates are deliberately rejected:
/// only `finish()` has delivery authority, while this gate can update the pill and the safely-owned
/// provisional field range solely during the recording generation that opened it.
struct LiveTranscriptionFence: Sendable {
    private(set) var generation: UInt = 0

    mutating func begin() -> UInt {
        generation &+= 1
        return generation
    }

    mutating func invalidate() {
        generation &+= 1
    }

    func accepts(
        _ update: TranscriptionUpdate,
        generation candidate: UInt,
        isListening: Bool
    ) -> Bool {
        candidate == generation
            && isListening
            && !update.isFinal
            && !update.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// A live transcription of a single utterance.
///
/// Lifecycle: `startStream` → `append` repeatedly → `finish()` (or `cancel()`). One session
/// per dictation; sessions are not reusable.
protocol TranscriptionStream: AnyObject, Sendable {

    /// Hypotheses as they are produced, ending with the final transcript. Consume it once.
    /// The stream buffers only the newest values: a slow consumer (the pill, redrawing at
    /// screen rate) must never back-pressure the decoder.
    var updates: AsyncStream<TranscriptionUpdate> { get }

    /// Hand over the next buffer of 16 kHz mono Float32 samples.
    ///
    /// Non-isolated and non-blocking so the audio side can call it from wherever it already
    /// lives without an await; the implementation must not allocate unboundedly or do I/O.
    func append(_ samples: [Float])

    /// Stop accepting audio and produce the final transcript over everything appended.
    /// This — not any partial — is the text that gets inserted.
    func finish() async throws -> String

    /// Finalize from the capture engine's authoritative PCM. A live feed may start one pump
    /// tick after capture and therefore miss an initial slice; production calls this overload
    /// so preview transport can never change or truncate the delivered transcript.
    func finish(samples: [Float]) async throws -> String

    /// `finish(samples:)` with per-word confidence. Its `text` is what `finish(samples:)` returns.
    func finishDetailed(samples: [Float]) async throws -> TranscriptionOutput

    /// Abandon the session. No final update is emitted and `updates` completes.
    func cancel()

    /// Atomically cancel and report whether a native inference was already in flight. The
    /// coordinator uses this to quarantine a backend that may ignore Swift cancellation.
    /// Implementations without incremental native work safely inherit the default below.
    func cancelAndReportInference() -> Bool

    /// Called once all native work owned by the session has returned. This is distinct from
    /// `updates` ending: a cancelled CoreML request may keep running after its UI stream closes.
    func installTerminationHandler(_ handler: @escaping @Sendable () -> Void)
}

extension TranscriptionStream {
    func finish(samples: [Float]) async throws -> String {
        try await finish()
    }

    func finishDetailed(samples: [Float]) async throws -> TranscriptionOutput {
        TranscriptionOutput.unscored(try await finish(samples: samples))
    }

    func cancelAndReportInference() -> Bool {
        cancel()
        return false
    }

    func installTerminationHandler(_ handler: @escaping @Sendable () -> Void) {}
}

/// Errors surfaced to the UI as `DictationState.error`.
enum TranscriptionError: LocalizedError {
    case modelUnavailable(String)
    case notReady
    case inferenceFailed(String)
    case streamingUnavailable
    case timedOut

    var errorDescription: String? {
        switch self {
        // Shown in the pill and History. The wrapped detail stays as the engine produced it:
        // `ModelDownloadFailure` classifies damaged files by matching that text.
        case .modelUnavailable(let m):
            return String(localized: "Model unavailable: \(m)", comment: "Error; the argument is the underlying reason")
        case .notReady:
            return String(localized: "Model still loading", comment: "Dictation failure: the transcription model is not ready yet")
        case .inferenceFailed(let m):
            return String(localized: "Transcription failed: \(m)", comment: "Error; the argument is the underlying reason")
        case .streamingUnavailable:
            return String(localized: "This model cannot show words as you speak", comment: "Error")
        case .timedOut:
            return String(localized: "Transcription timed out", comment: "Error")
        }
    }
}

/// A recording keeps the engine/configuration it started with, but readiness may improve while
/// the user is speaking. Reject only when that exact engine was neither ready at start nor became
/// the active ready engine by stop time.
enum RecordingReadiness {
    static func isReady(wasReadyAtStart: Bool, sameEngineIsReadyAtStop: Bool) -> Bool {
        wasReadyAtStart || sameEngineIsReadyAtStop
    }
}

/// Bounds one inference without coupling the engine protocol to a particular timeout policy.
enum TranscriptionDeadline {
    typealias Sleeper = @Sendable (Duration) async throws -> Void

    static func run<T: Sendable>(
        for duration: Duration,
        onOperationFinished: @escaping @Sendable () -> Void = {},
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await run(
            for: duration,
            sleep: { try await Task.sleep(for: $0) },
            onOperationFinished: onOperationFinished,
            operation: operation
        )
    }

    /// The injected sleeper keeps the deadline deterministic in tests; production uses the
    /// overload above. Inference is deliberately unstructured: a backend may not cooperate
    /// with cancellation, and a structured task group would otherwise hold the caller past its
    /// deadline. `DeadlineRace` owns cancellation and resumes the caller exactly once.
    static func run<T: Sendable>(
        for duration: Duration,
        sleep: @escaping Sleeper,
        onOperationFinished: @escaping @Sendable () -> Void = {},
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let race = DeadlineRace<T>()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Task {
                    guard await race.install(continuation) else {
                        // Cancellation won before any native operation existed. The lifecycle
                        // callback must still release the coordinator's generation quarantine.
                        onOperationFinished()
                        return
                    }

                    let operationTask = Task.detached {
                        defer { onOperationFinished() }
                        do {
                            let value = try await operation()
                            await race.succeed(value)
                        } catch {
                            await race.fail(error)
                        }
                    }
                    let deadlineTask = Task.detached {
                        do {
                            try await sleep(duration)
                            try Task.checkCancellation()
                            await race.fail(TranscriptionError.timedOut)
                        } catch is CancellationError {
                            // The other result, or the caller, already finished the race.
                        } catch {
                            await race.fail(error)
                        }
                    }
                    await race.register(operationTask: operationTask, deadlineTask: deadlineTask)
                }
            }
        } onCancel: {
            Task { await race.cancel() }
        }
    }
}

private actor DeadlineRace<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, any Error>?
    private var didFinish = false
    private var operationTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?

    func install(_ continuation: CheckedContinuation<Value, any Error>) -> Bool {
        guard !didFinish else {
            continuation.resume(throwing: CancellationError())
            return false
        }

        self.continuation = continuation
        return true
    }

    func register(operationTask: Task<Void, Never>, deadlineTask: Task<Void, Never>) {
        guard !didFinish else {
            operationTask.cancel()
            deadlineTask.cancel()
            return
        }

        self.operationTask = operationTask
        self.deadlineTask = deadlineTask
    }

    func succeed(_ value: Value) {
        finish(.success(value))
    }

    func fail(_ error: any Error) {
        finish(.failure(error))
    }

    func cancel() {
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<Value, any Error>) {
        guard !didFinish else { return }
        didFinish = true

        let continuation = continuation
        self.continuation = nil
        let operationTask = operationTask
        self.operationTask = nil
        let deadlineTask = deadlineTask
        self.deadlineTask = nil

        operationTask?.cancel()
        deadlineTask?.cancel()
        continuation?.resume(with: result)
    }
}
