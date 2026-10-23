import Foundation
import Testing

struct RealtimeTranscriptionPolicyTests {
    @Test func realtimeDefaultsOffIndependentlyOfLegacyPreview() {
        let settings = SettingsData()

        #expect(settings.realtimeTranscriptionEnabled == nil)
        #expect(settings.showTranscriptPreview)
        #expect(
            RecordingTranscriptionMode.select(
                realtimeEnabled: settings.realtimeTranscriptionEnabled,
                modelReady: true,
                supportsStreaming: true,
                supportsBackground: true
            ) == .background
        )
    }

    @Test func explicitRealtimeChoicePersistsAndLegacyDataStaysOff() throws {
        var settings = SettingsData()
        settings.realtimeTranscriptionEnabled = true
        let encoded = try JSONEncoder().encode(settings)
        let roundTrip = try JSONDecoder().decode(SettingsData.self, from: encoded)
        #expect(roundTrip.realtimeTranscriptionEnabled == true)

        var legacyObject = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        legacyObject.removeValue(forKey: "realtimeTranscriptionEnabled")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let legacy = try JSONDecoder().decode(SettingsData.self, from: legacyData)
        #expect(legacy.realtimeTranscriptionEnabled == nil)
    }

    @Test func realtimeRequiresOptInReadinessAndCapability() {
        #expect(
            RecordingTranscriptionMode.select(
                realtimeEnabled: true,
                modelReady: true,
                supportsStreaming: true,
                supportsBackground: true
            ) == .realtime
        )
        #expect(
            RecordingTranscriptionMode.select(
                realtimeEnabled: true,
                modelReady: false,
                supportsStreaming: true,
                supportsBackground: true
            ) == .batch
        )
        #expect(
            RecordingTranscriptionMode.select(
                realtimeEnabled: false,
                modelReady: true,
                supportsStreaming: true,
                supportsBackground: true
            ) == .background
        )
        #expect(
            RecordingTranscriptionMode.select(
                realtimeEnabled: true,
                modelReady: true,
                supportsStreaming: false,
                supportsBackground: false
            ) == .batch
        )
    }

    @Test func chosenModeIsAValueFrozenForTheRecording() {
        var realtimeEnabled: Bool? = true
        let recordingMode = RecordingTranscriptionMode.select(
            realtimeEnabled: realtimeEnabled,
            modelReady: true,
            supportsStreaming: true,
            supportsBackground: true
        )

        realtimeEnabled = false
        #expect(recordingMode == .realtime)
        #expect(realtimeEnabled == false)
    }

    @Test func failedStreamingFallsBackWithoutOpeningASecondRealtimePath() {
        #expect(
            RecordingTranscriptionMode.fallbackAfterStreamingFailure(supportsBackground: true)
                == .background
        )
        #expect(
            RecordingTranscriptionMode.fallbackAfterStreamingFailure(supportsBackground: false)
                == .batch
        )
    }

    @Test func previewFenceRejectsFinalAndStaleUpdates() {
        var fence = LiveTranscriptionFence()
        let firstGeneration = fence.begin()
        let partial = TranscriptionUpdate(text: "working words", isFinal: false)
        let final = TranscriptionUpdate(text: "authoritative text", isFinal: true)

        #expect(fence.accepts(partial, generation: firstGeneration, isListening: true))
        #expect(fence.accepts(final, generation: firstGeneration, isListening: true) == false)
        #expect(fence.accepts(partial, generation: firstGeneration, isListening: false) == false)

        fence.invalidate()
        #expect(fence.accepts(partial, generation: firstGeneration, isListening: true) == false)
        let secondGeneration = fence.begin()
        #expect(fence.accepts(partial, generation: firstGeneration, isListening: true) == false)
        #expect(fence.accepts(partial, generation: secondGeneration, isListening: true))
    }

    @Test(.timeLimit(.minutes(1)))
    func streamedFinalIsAuthoritativeAndEmittedExactlyOnce() async throws {
        let engine = ScriptedRealtimeEngine(outputs: ["working draft", "authoritative final"])
        let stream = ChunkedStreamingSession(
            engine: engine,
            language: "en",
            tuning: fastStreamingTuning()
        )
        let recorder = TranscriptionUpdateRecorder()
        let collector = Task {
            for await update in stream.updates { await recorder.append(update) }
        }

        stream.append([Float](repeating: 0.1, count: 32))
        for _ in 0..<200 {
            if await recorder.count > 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await recorder.count == 1)

        let authoritativeSamples = [Float](repeating: 0.2, count: 64)
        let final = try await stream.finish(samples: authoritativeSamples)
        await collector.value
        let updates = await recorder.snapshot
        let callCount = await engine.callCount
        let sampleCounts = await engine.sampleCounts

        #expect(final == "authoritative final")
        #expect(updates.filter { $0.isFinal }.count == 1)
        #expect(updates.last == TranscriptionUpdate(text: final, isFinal: true))
        #expect(callCount == 2)
        #expect(sampleCounts == [32, authoritativeSamples.count])
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellationDropsLateNativePartialAndNeverEmitsFinal() async throws {
        let engine = SuspendedRealtimeEngine()
        let stream = ChunkedStreamingSession(
            engine: engine,
            language: "en",
            tuning: fastStreamingTuning()
        )
        let recorder = TranscriptionUpdateRecorder()
        let termination = AsyncTestLatch()
        stream.installTerminationHandler {
            Task { await termination.signal() }
        }
        let collector = Task {
            for await update in stream.updates { await recorder.append(update) }
        }

        stream.append([Float](repeating: 0.1, count: 32))
        await engine.waitUntilStarted()
        #expect(stream.cancelAndReportInference())
        await engine.resume(with: "late partial")
        await termination.wait()
        await collector.value

        #expect(await recorder.snapshot.isEmpty)
    }

    private func fastStreamingTuning() -> ChunkedStreamingSession.Tuning {
        var tuning = ChunkedStreamingSession.Tuning.default
        tuning.minimumSeconds = 0.001
        tuning.minimumCadence = 60
        tuning.maximumCadence = 60
        tuning.cadenceDivisor = 1
        tuning.maximumSeconds = 5
        tuning.minimumNewSeconds = 0.001
        tuning.pollMilliseconds = 1
        return tuning
    }
}

private actor ScriptedRealtimeEngine: TranscriptionEngine {
    private let outputs: [String]
    private var calls = 0
    private var receivedSampleCounts: [Int] = []

    init(outputs: [String]) {
        self.outputs = outputs
    }

    func warmUp(progress: @escaping @Sendable (Double) -> Void) async throws {}

    func transcribe(samples: [Float], language: String) async throws -> String {
        let index = min(calls, max(0, outputs.count - 1))
        receivedSampleCounts.append(samples.count)
        calls += 1
        return outputs.isEmpty ? "" : outputs[index]
    }

    func currentModelName() async -> String { "scripted" }
    var callCount: Int { calls }
    var sampleCounts: [Int] { receivedSampleCounts }
}

private actor SuspendedRealtimeEngine: TranscriptionEngine {
    private var didStart = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var pending: CheckedContinuation<String, Never>?

    func warmUp(progress: @escaping @Sendable (Double) -> Void) async throws {}

    func transcribe(samples: [Float], language: String) async throws -> String {
        didStart = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        return await withCheckedContinuation { pending = $0 }
    }

    func currentModelName() async -> String { "suspended" }

    func waitUntilStarted() async {
        if didStart { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func resume(with output: String) {
        pending?.resume(returning: output)
        pending = nil
    }
}

private actor TranscriptionUpdateRecorder {
    private var updates: [TranscriptionUpdate] = []

    var count: Int { updates.count }
    var snapshot: [TranscriptionUpdate] { updates }

    func append(_ update: TranscriptionUpdate) {
        updates.append(update)
    }
}

private actor AsyncTestLatch {
    private var didSignal = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        didSignal = true
        let current = waiters
        waiters.removeAll()
        for waiter in current { waiter.resume() }
    }

    func wait() async {
        if didSignal { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
