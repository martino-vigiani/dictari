import XCTest
import os

/// Opt-in replay of real recordings from the recovery store through the exact pre-model path a
/// dictation takes: the background session (default for Parakeet) fed at real-time pace, and a
/// plain batch call. Recordings stay outside the repository; point the test at a folder of
/// `<id>.pcm` copies (raw 16 kHz mono Float32, as `DictationRecoveryStore` writes them).
///
/// ```
/// TEST_RUNNER_DICTARI_RECOVERY_REPLAY_DIR=/path/to/pcm xcodebuild … test \
///   -only-testing:DictariTests/RecoveredDictationReplayTests
/// ```
final class RecoveredDictationReplayTests: XCTestCase {
    func testReplayRecoveredRecordings() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["DICTARI_RECOVERY_REPLAY_DIR"] else {
            throw XCTSkip("Set DICTARI_RECOVERY_REPLAY_DIR to a folder of recovery PCM copies")
        }
        let folder = URL(fileURLWithPath: path)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "pcm" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let model = ParakeetEngine(displayName: "Parakeet v3")
        try await model.warmUp { _ in }

        for file in files {
            let data = try Data(contentsOf: file)
            let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            let name = file.deletingPathExtension().lastPathComponent
            let languages = (environment["DICTARI_RECOVERY_REPLAY_LANGS"] ?? "auto")
                .split(separator: ",").map(String.init)
            for language in languages {
                let batch: String
                do { batch = try await model.transcribe(samples: samples, language: language) }
                catch { batch = "ERROR \(error.localizedDescription)" }
                print("REPLAY \(name) batch[\(language)]=\(batch)")
            }
            guard environment["DICTARI_RECOVERY_REPLAY_BACKGROUND"] != "0" else { continue }

            let logged = LoggingEngine(engine: model)
            let session = BackgroundTranscriptionSession(engine: logged, language: "auto")
            let start = ContinuousClock.now
            for offset in stride(from: 0, to: samples.count, by: 1_600) {
                let end = min(offset + 1_600, samples.count)
                session.append(Array(samples[offset..<end]), at: offset)
                try await Task.sleep(until: start + .seconds(Double(end) / 16_000), clock: .continuous)
            }
            let background: String
            do { background = try await session.finish(samples: samples) }
            catch { background = "ERROR \(error.localizedDescription)" }
            print("REPLAY \(name) seconds=\(Double(samples.count) / 16_000) calls=\(logged.calls)")
            print("REPLAY \(name) background=\(background)")
            // A recording the model can accept must never fail outright: phrases already decoded
            // were lost with it (99FB294A).
            if samples.count >= BackgroundTranscriptionSession.minimumDecodeSamples {
                XCTAssertFalse(background.hasPrefix("ERROR"), "\(name): \(background)")
            }
            // Optional `<id>.txt` beside the PCM: words a person heard in it. Parakeet's
            // whole-window blank decode returned nothing for 46F9997D before FluidAudio 0.17.
            let expectation = file.deletingPathExtension().appendingPathExtension("txt")
            if let expected = try? String(contentsOf: expectation, encoding: .utf8) {
                XCTAssertGreaterThanOrEqual(
                    TranscriptMatch.wordRecall(expected: expected, actual: background), 0.8, "\(name): \(background)")
            }
        }
    }
}

private final class LoggingEngine: TranscriptionEngine, Sendable {
    let engine: any TranscriptionEngine
    private let log = OSAllocatedUnfairLock(initialState: [String]())
    var calls: [String] { log.withLock { $0 } }
    init(engine: any TranscriptionEngine) { self.engine = engine }
    func warmUp(progress: @escaping @Sendable (Double) -> Void) async throws {}
    func currentModelName() async -> String { "logged Parakeet" }
    func transcribe(samples: [Float], language: String) async throws -> String {
        do {
            let text = try await engine.transcribe(samples: samples, language: language)
            log.withLock { $0.append("\(samples.count)→\"\(text)\"") }
            return text
        } catch {
            log.withLock { $0.append("\(samples.count)→ERROR") }
            throw error
        }
    }
}
