// LiveStreamingBudgetTests.swift
// What does live typing cost, and how fast do words appear?
//
// Streaming once starved the Mac badly enough to freeze the keyboard, so "production-safe"
// has to be a number, not a belief. This feeds real synthesized Italian speech through the
// real Parakeet model at wall-clock pace — exactly as the capture engine does — and measures:
//
//   - process CPU time over the dictation (average cores busy),
//   - how often hypotheses arrive and how long after the audio started the first one lands,
//   - stop → final transcript latency, compared with the plain batch call on the same PCM,
//   - how much the field would churn under `LiveTypingPlanner` (Backspaces per typed char).
//
// The numbers are printed with a `[live-budget]` prefix so a run can be compared with the
// last one. Bounds are loose on purpose: they catch a regression to "decode in a hot loop",
// not a 10% wobble between machines.

import XCTest

final class LiveStreamingBudgetTests: XCTestCase {

    private struct TimedUpdate: Sendable {
        let at: ContinuousClock.Instant
        let update: TranscriptionUpdate
    }

    private struct Measurement {
        var partialOffsets: [Double] = []      // seconds since feed start
        var partialTexts: [String] = []
        var feedSeconds: Double = 0
        var cpuSecondsDuringFeed: Double = 0
        var stopToFinalMs: Double = 0
        var batchMs: Double = 0
        var final = ""
        var batch = ""
        var audioSeconds: Double = 0
        var statistics = ChunkedStreamingSession.Statistics()
    }

    func testLiveStreamingStaysWithinItsBudget() async throws {
        let engine = try await SharedParakeet.shared.engine()
        let spoken = """
            Domani mattina devo passare in ufficio per ritirare i documenti, \
            poi vorrei andare in banca e fare la spesa al mercato vicino alla stazione.
            """
        let samples = try AudioFixture.samples(text: spoken, voice: "Alice")
        let m = try await measure(engine: engine, samples: samples, language: "it")

        let intervals = zip(m.partialOffsets.dropFirst(), m.partialOffsets).map { $0 - $1 }
        let sortedIntervals = intervals.sorted()
        let medianInterval = sortedIntervals.isEmpty ? .infinity : sortedIntervals[sortedIntervals.count / 2]
        let cores = m.cpuSecondsDuringFeed / max(m.feedSeconds, 0.001)

        var planner = LiveTypingPlanner()
        var backspaces = 0
        var typedCharacters = 0
        var edits = 0
        for partial in m.partialTexts {
            if let edit = planner.propose(partial: partial) {
                backspaces += edit.deleteCount
                typedCharacters += edit.insert.count
                edits += 1
                planner.commit(edit)
            }
        }
        let liveShown = planner.typed
        let finalEdit = planner.finalEdit(for: m.final + " ") ?? LiveTypingEdit(deleteCount: 0, insert: "")

        print("""
            [live-budget] audio=\(fmt(m.audioSeconds))s feed=\(fmt(m.feedSeconds))s \
            partials=\(m.partialOffsets.count) firstPartialAt=\(fmt(m.partialOffsets.first ?? -1))s \
            medianInterval=\(fmt(medianInterval))s maxInterval=\(fmt(sortedIntervals.last ?? -1))s
            [live-budget] cpu=\(fmt(m.cpuSecondsDuringFeed))s avgCores=\(fmt(cores)) \
            stopToFinal=\(fmt(m.stopToFinalMs))ms batch=\(fmt(m.batchMs))ms \
            passes=\(m.statistics.passes) inference=\(fmt(m.statistics.inferenceSeconds))s \
            duty=\(fmt(m.statistics.inferenceSeconds / max(m.feedSeconds, 0.001))) \
            longestPass=\(fmt(m.statistics.longestPassSeconds * 1_000))ms
            [live-budget] planner edits=\(edits) typed=\(typedCharacters) backspaces=\(backspaces) \
            finalFix=-\(finalEdit.deleteCount)+\(finalEdit.insert.count) shownBeforeStop="\(liveShown)"
            [live-budget] final="\(m.final)"
            """)

        // Correctness is not negotiable: streaming must not change what gets delivered.
        XCTAssertEqual(TranscriptMatch.normalize(m.final), TranscriptMatch.normalize(m.batch),
                       "the streamed final differs from the batch transcript")
        // Words appear while speaking, at a cadence a person reads as "live".
        XCTAssertGreaterThanOrEqual(m.partialOffsets.count, 3, "too few hypotheses to feel live")
        XCTAssertLessThan(medianInterval, 1.0, "hypotheses arrive too slowly")
        // CPU budget: the whole process, model included, averages under one core while talking.
        XCTAssertLessThan(cores, 1.0, "live streaming burns more than a core on average")
        // Stop → final may queue behind one in-flight hypothesis pass, never more.
        XCTAssertLessThan(m.stopToFinalMs, m.batchMs * 2 + 400, "final decode queued behind too much work")
        XCTAssertFalse(liveShown.isEmpty, "nothing would have been typed before stop")
    }

    // MARK: - Measurement

    private func measure(engine: ParakeetEngine, samples: [Float], language: String) async throws -> Measurement {
        var m = Measurement()
        m.audioSeconds = Double(samples.count) / 16_000

        let stream = try engine.startStream(language: language)
        let clock = ContinuousClock()
        let start = clock.now
        let updates = stream.updates
        let collector = Task.detached { () -> [TimedUpdate] in
            var received: [TimedUpdate] = []
            for await update in updates {
                received.append(TimedUpdate(at: ContinuousClock.now, update: update))
            }
            return received
        }

        let cpuStart = Self.processCPUSeconds()
        // 100 ms slices at wall-clock pace, like the capture engine's sample pump.
        let slice = 1_600
        var offset = 0
        while offset < samples.count {
            let end = min(offset + slice, samples.count)
            stream.append(Array(samples[offset..<end]))
            offset = end
            try await Task.sleep(for: .milliseconds(100))
        }
        m.feedSeconds = Self.seconds(start.duration(to: clock.now))
        m.cpuSecondsDuringFeed = Self.processCPUSeconds() - cpuStart

        if let session = stream as? ChunkedStreamingSession {
            m.statistics = session.statistics
        }
        let stopAt = clock.now
        m.final = try await stream.finish(samples: samples)
        m.stopToFinalMs = Self.seconds(stopAt.duration(to: clock.now)) * 1_000

        let received = await collector.value
        for timed in received where !timed.update.isFinal {
            m.partialOffsets.append(Self.seconds(start.duration(to: timed.at)))
            m.partialTexts.append(timed.update.text)
        }

        let batchStart = clock.now
        m.batch = try await engine.transcribe(samples: samples, language: language)
        m.batchMs = Self.seconds(batchStart.duration(to: clock.now)) * 1_000
        return m
    }

    private static func processCPUSeconds() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID)) / 1_000_000_000
    }

    private static func seconds(_ duration: Duration) -> Double {
        let c = duration.components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }

    private func fmt(_ value: Double) -> String { String(format: "%.3f", value) }
}
