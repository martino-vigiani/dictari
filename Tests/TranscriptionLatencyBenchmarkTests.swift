// TranscriptionLatencyBenchmarkTests.swift
// Opt-in latency benchmark: how long Parakeet v3 takes to transcribe the same clip.
//
// Skipped unless DICTARI_LATENCY_BENCH is set (pass it to xcodebuild as
// TEST_RUNNER_DICTARI_LATENCY_BENCH=<output.json>). It exists to compare build configurations
// (Debug vs Release, package optimization levels) on identical audio without launching the app,
// which would install an event tap and simulate input on the developer's working Mac.
//
// It goes through `ParakeetEngine` exactly as the coordinator does, so the number includes the
// app-side work around the FluidAudio call (decoder state, confidence grouping), not only the
// model. The Mac's own load moves the numbers, so compare interleaved runs, not single ones.

import Foundation
import XCTest

final class TranscriptionLatencyBenchmarkTests: XCTestCase {

    func testParakeetLatencyOnFixedClip() async throws {
        guard let output = ProcessInfo.processInfo.environment["DICTARI_LATENCY_BENCH"],
              !output.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_DICTARI_LATENCY_BENCH=<file.json> to run the benchmark")
        }
        let iterations = Int(ProcessInfo.processInfo.environment["DICTARI_LATENCY_ITERATIONS"] ?? "") ?? 12

        // About 20 s of Italian: the length of a long dictation, where per-frame app and
        // package code would show up if it were unoptimized.
        let text = """
        Buongiorno a tutti, oggi vorrei parlarvi del progetto che stiamo portando avanti da \
        qualche mese. Abbiamo completato la prima fase dello sviluppo e i risultati sono \
        incoraggianti. La prossima settimana incontreremo il cliente per discutere le \
        modifiche richieste e pianificare il rilascio della nuova versione entro la fine \
        del mese. Vi chiedo di preparare un breve riepilogo del vostro lavoro.
        """
        let samples = try AudioFixture.samples(text: text, voice: "Alice")
        let seconds = Double(samples.count) / 16_000

        let engine = try await SharedParakeet.shared.engine()

        // Two untimed passes: the first inference compiles/loads ANE state lazily.
        for _ in 0..<2 { _ = try await engine.transcribe(samples: samples, language: "it") }

        var timings: [Double] = []
        var transcript = ""
        let clock = ContinuousClock()
        for _ in 0..<iterations {
            let start = clock.now
            transcript = try await engine.transcribe(samples: samples, language: "it")
            let elapsed = clock.now - start
            timings.append(Double(elapsed.components.attoseconds) / 1e15
                + Double(elapsed.components.seconds) * 1000)
        }
        XCTAssertFalse(transcript.isEmpty)

        #if DEBUG
        let configuration = "Debug"
        #else
        let configuration = "Release"
        #endif
        let report: [String: Any] = [
            "configuration": configuration,
            "audioSeconds": seconds,
            "timingsMs": timings,
            "transcript": transcript,
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted])
        try data.write(to: URL(fileURLWithPath: output))
    }
}
