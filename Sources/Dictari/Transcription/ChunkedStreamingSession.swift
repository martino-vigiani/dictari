// ChunkedStreamingSession.swift
// Dictari — words on screen while the user is still talking.
//
// Why re-transcription and not a streaming decoder
// ------------------------------------------------
// FluidAudio does ship true cache-aware streaming encoders (see the note in ParakeetEngine),
// but every one of them is a *different* model download, and the multilingual one is a second
// 0.6 B network on top of the Parakeet TDT v3 the app already ships. Adopting one would mean a
// second ~600 MB download, a second warm-up, and a final transcript produced by a model nobody
// has measured against ours. That is a product decision, not an engine decision.
//
// So this takes the other route: the utterance so far is re-transcribed at a cadence with the
// model that is *already warm*, and each pass is published as a hypothesis. The consequences
// are the ones that matter:
//
//   - The final transcript is produced by exactly the call the app makes today
//     (`engine.transcribe(samples:language:)` over the whole utterance — reached through
//     `transcribeDetailed`, whose `text` is that same string), so inserted text is
//     bit-for-bit what it was before this file existed. Partials cannot corrupt it.
//   - No new download, no second model resident in memory, and every language the active
//     engine supports keeps working, because it *is* the active engine.
//   - The cost is redundant compute: re-transcribing a growing buffer is quadratic in the
//     length of the dictation. `Tuning` exists to bound that — see the cadence rules below.
//
// Concurrency
// -----------
// `@unchecked Sendable` because the audio side calls `append` from wherever it lives while a
// background task decodes. All mutable state is inside a single `OSAllocatedUnfairLock`; every
// other stored property is a `let`. Critical sections are an array append and a copy of a
// struct of counters — no I/O, no inference, no allocation beyond the buffer growth itself.

import Foundation
import os

/// Publishes hypotheses for a single utterance by re-transcribing the audio so far.
final class ChunkedStreamingSession: TranscriptionStream, @unchecked Sendable {

    /// Everything about how hard this works.
    ///
    /// These numbers are measured, not guessed. Decoding truncated prefixes of one fixture
    /// sentence through the warm v3 model (Debug build, M-series):
    ///
    ///     0.4 s → 193 ms → ""
    ///     0.8 s → 188 ms → ""
    ///     1.2 s → 204 ms → ""
    ///     2.0 s → 237 ms → ""
    ///     2.5 s → 278 ms → "The quick brown fox jumps over the lazy dog near."
    ///
    /// Two facts fall out, and both drive the defaults. First, a pass costs roughly the same
    /// (~200 ms) whatever the audio length, because the encoder input is a fixed 15 s window —
    /// so cadence, not utterance length, is what sets CPU load. Second, the model frequently
    /// returns *nothing at all* for a truncated prefix under about two seconds: decoding
    /// sooner does not make words appear sooner, it only burns the ANE to produce "".
    ///
    /// Live typing (September 2026) tightened the cadence to 0.4–1.0 s, because words that
    /// appear two seconds late do not read as "typing as I speak". The CPU budget is enforced
    /// by `maximumDutyCycle`, not by the cadence alone: the next pass never starts sooner than
    /// `lastPassDuration / maximumDutyCycle` after the previous one started, so a slow Mac
    /// (or a long utterance) automatically stretches the cadence instead of queueing work.
    /// `LiveStreamingBudgetTests` measures the result with real speech on every run.
    struct Tuning: Sendable {
        /// Don't decode before there is this much audio — see the table above.
        var minimumSeconds: Double = 1.0
        /// Shortest gap between two decode passes.
        var minimumCadence: Double = 0.4
        /// Longest gap between two decode passes.
        var maximumCadence: Double = 1.0
        /// The cadence grows with the utterance (`seconds / divisor`, clamped to the two
        /// bounds above). Early on, passes are cheap and frequent, which is what "the word
        /// appears as you say it" needs; by the time the buffer is long, each pass costs real
        /// time and the user has plenty of text on screen already, so they slow down. This is
        /// what keeps the quadratic from being felt.
        var cadenceDivisor: Double = 16
        /// Hard ceiling on the fraction of wall time spent inside hypothesis inference. At
        /// 0.5 the decoder is idle at least half the time whatever the machine, so the audio
        /// pump, the event tap and the final decode never compete with a back-to-back loop.
        var maximumDutyCycle: Double = 0.5
        /// Beyond this much audio, stop emitting hypotheses entirely and just keep recording.
        /// A minute-long dictation must not heat the machine for a preview; the authoritative
        /// final decode at stop still covers everything.
        var maximumSeconds: Double = 30
        /// Don't re-decode unless at least this much *new* audio arrived.
        var minimumNewSeconds: Double = 0.3
        /// How often the decode loop wakes to check whether a pass is due. A wake-up reads
        /// two integers under the lock and copies nothing.
        var pollMilliseconds: UInt64 = 50

        static let `default` = Tuning()
    }

    /// What the session actually spent. Read by tests; cheap enough to keep in production.
    struct Statistics: Equatable, Sendable {
        var passes = 0
        var emitted = 0
        var inferenceSeconds: Double = 0
        var longestPassSeconds: Double = 0
    }

    // MARK: - Stored state

    let updates: AsyncStream<TranscriptionUpdate>
    private let continuation: AsyncStream<TranscriptionUpdate>.Continuation

    private let engine: any TranscriptionEngine
    private let language: String
    private let tuning: Tuning
    private static let sampleRate: Double = 16_000

    private struct State {
        var samples: [Float] = []
        /// Set by `finish()`/`cancel()`; the decode loop stops at the next check.
        var stopped = false
        var cancelled = false
        /// Set under the same lock used by cancellation immediately before a native call.
        /// That makes `cancelAndReportInference()` an atomic answer rather than a racy peek.
        var inferenceRunning = false
        var statistics = Statistics()
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    /// Set once, during `init`, before the session is handed to anyone.
    private let loop = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

    private struct LifecycleState {
        var handler: (@Sendable () -> Void)?
        var didTerminate = false
    }
    private let lifecycle = OSAllocatedUnfairLock(initialState: LifecycleState())

    // MARK: - Lifecycle

    init(engine: any TranscriptionEngine, language: String, tuning: Tuning = .default) {
        self.engine = engine
        self.language = language
        self.tuning = tuning

        // `.bufferingNewest(1)`: a hypothesis that has been superseded is worthless — live
        // typing must never replay a stale one after a newer one exists — and the decoder
        // must never wait on the main actor. The final update, being newest, always survives.
        let (stream, continuation) = AsyncStream<TranscriptionUpdate>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        self.updates = stream
        self.continuation = continuation
        // One allocation up front instead of repeated doubling copies inside the lock while
        // the user speaks (30 s of 16 kHz Float32 ≈ 1.9 MB).
        state.withLock { $0.samples.reserveCapacity(Int(tuning.maximumSeconds * Self.sampleRate)) }

        let task = Task.detached(priority: .utility) { [weak self] () -> Void in
            await self?.decodeLoop()
        }
        loop.withLock { $0 = task }
    }

    // MARK: - TranscriptionStream

    func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        state.withLock { st in
            guard !st.stopped else { return }
            st.samples.append(contentsOf: samples)
        }
    }

    func finish() async throws -> String {
        try await finish(authoritativeSamples: nil).text
    }

    func finish(samples: [Float]) async throws -> String {
        try await finish(authoritativeSamples: samples).text
    }

    /// Only the final decode carries word confidence; partial hypotheses stay plain text.
    func finishDetailed(samples: [Float]) async throws -> TranscriptionOutput {
        try await finish(authoritativeSamples: samples)
    }

    private func finish(authoritativeSamples: [Float]?) async throws -> TranscriptionOutput {
        let samples = try state.withLock { st -> [Float] in
            guard !st.stopped else { throw CancellationError() }
            st.stopped = true
            return authoritativeSamples ?? st.samples
        }
        defer {
            continuation.finish()
            signalTermination()
        }

        // Wait for the loop to unwind. Cancellation cannot interrupt an inference already
        // inside CoreML, so in the worst case this costs one partial pass (~200 ms on 20 s of
        // audio, less on anything shorter) before the final decode starts. Not waiting would
        // not help: FluidAudio serializes inference internally, so the final call would queue
        // behind that same pass anyway — this way at least the ordering is explicit.
        let task = loop.withLock { $0 }
        task?.cancel()
        await task?.value

        try Task.checkCancellation()
        try state.withLock { st in
            guard !st.cancelled else { throw CancellationError() }
            st.inferenceRunning = true
        }
        defer { state.withLock { $0.inferenceRunning = false } }
        let output = try await engine.transcribeDetailed(samples: samples, language: language)
        try Task.checkCancellation()
        guard !state.withLock({ $0.cancelled }) else { throw CancellationError() }
        continuation.yield(TranscriptionUpdate(text: output.text, isFinal: true))
        return output
    }

    func cancel() {
        _ = cancelAndReportInference()
    }

    func cancelAndReportInference() -> Bool {
        let inferenceRunning = state.withLock { st -> Bool in
            st.cancelled = true
            st.stopped = true
            return st.inferenceRunning
        }
        loop.withLock { $0 }?.cancel()
        continuation.finish()
        // With the lock held above, a decode can no longer cross into native inference. If
        // none was already running, engine ownership is released synchronously.
        if !inferenceRunning { signalTermination() }
        return inferenceRunning
    }

    func installTerminationHandler(_ handler: @escaping @Sendable () -> Void) {
        let callImmediately = lifecycle.withLock { lifecycle -> Bool in
            if lifecycle.didTerminate { return true }
            lifecycle.handler = handler
            return false
        }
        if callImmediately { handler() }
    }

    // MARK: - Decode loop

    private func decodeLoop() async {
        var lastDecodedCount = 0
        var lastPassStarted = ContinuousClock.now
        var hasDecodedOnce = false

        let minimumSamples = Int(tuning.minimumSeconds * Self.sampleRate)
        let maximumSamples = Int(tuning.maximumSeconds * Self.sampleRate)
        let minimumNewSamples = Int(tuning.minimumNewSeconds * Self.sampleRate)

        var lastPassSeconds: Double = 0

        while !Task.isCancelled {
            // Read only the count here. Copying the buffer on every wake-up (the old code did)
            // kept a second reference alive across the sleep, so the next `append` on the main
            // actor paid a copy-on-write of the whole utterance inside the lock.
            let status = state.withLock { st -> (count: Int, stopped: Bool) in
                (st.samples.count, st.stopped)
            }
            if status.stopped { return }

            let count = status.count
            let due: Bool = {
                guard count >= minimumSamples, count <= maximumSamples else { return false }
                guard count >= lastDecodedCount + minimumNewSamples else { return false }
                guard hasDecodedOnce else { return true }
                let elapsed = ContinuousClock.now - lastPassStarted
                return elapsed >= .seconds(cadence(forSamples: count, lastPassSeconds: lastPassSeconds))
            }()

            if due {
                // Cancellation and the native-call transition share one lock. Either cancel
                // marks the session stopped first, or it observes this call as in flight and
                // keeps the engine quarantined until `signalTermination()` runs. The snapshot
                // is taken in the same critical section and dropped right after the pass.
                let snapshot = state.withLock { st -> [Float]? in
                    guard !st.stopped else { return nil }
                    st.inferenceRunning = true
                    return st.samples
                }
                guard let snapshot else { return }
                let passStarted = ContinuousClock.now
                lastPassStarted = passStarted
                lastDecodedCount = snapshot.count
                hasDecodedOnce = true

                // A failed hypothesis is not an error the user should ever see: the final
                // decode is a separate call and reports its own failures.
                let text = (try? await engine.transcribe(
                    samples: snapshot, language: language)) ?? ""
                let passSeconds = Self.seconds(passStarted.duration(to: .now))
                lastPassSeconds = passSeconds

                // Re-read after the inference — the user may have stopped talking during it,
                // in which case `finish()` owns the transcript and a late hypothesis would
                // land after the final update.
                let outcome = state.withLock { st -> (stopped: Bool, cancelled: Bool) in
                    st.inferenceRunning = false
                    st.statistics.passes += 1
                    st.statistics.inferenceSeconds += passSeconds
                    st.statistics.longestPassSeconds = max(st.statistics.longestPassSeconds, passSeconds)
                    return (st.stopped, st.cancelled)
                }
                if outcome.cancelled { signalTermination() }
                if outcome.stopped || Task.isCancelled { return }

                // Never blank text that already had words: an empty pass is far more likely to
                // be a bad decode of a trailing pause than a real correction. A pass identical
                // to the last one *is* emitted: live typing reads two agreeing hypotheses as
                // "this tail is stable", which is exactly what a pause in speech produces.
                if !text.isEmpty {
                    state.withLock { $0.statistics.emitted += 1 }
                    continuation.yield(TranscriptionUpdate(text: text, isFinal: false))
                }
            }

            do {
                try await Task.sleep(nanoseconds: tuning.pollMilliseconds * 1_000_000)
            } catch {
                return
            }
        }
    }

    /// Gap between pass starts: the utterance-length schedule, stretched when the last pass
    /// was slow enough that the schedule would exceed the duty-cycle budget.
    private func cadence(forSamples count: Int, lastPassSeconds: Double) -> Double {
        let seconds = Double(count) / Self.sampleRate
        let scheduled = min(max(seconds / tuning.cadenceDivisor, tuning.minimumCadence), tuning.maximumCadence)
        let duty = min(max(tuning.maximumDutyCycle, 0.05), 1)
        return max(scheduled, lastPassSeconds / duty)
    }

    /// Work done so far. Cheap: one lock and a struct copy.
    var statistics: Statistics {
        state.withLock { $0.statistics }
    }

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    private func signalTermination() {
        let handler = lifecycle.withLock { lifecycle -> (@Sendable () -> Void)? in
            guard !lifecycle.didTerminate else { return nil }
            lifecycle.didTerminate = true
            let handler = lifecycle.handler
            lifecycle.handler = nil
            return handler
        }
        handler?()
    }
}
