// AudioCaptureTests.swift
// Proves the microphone path returns real audio, which is the failure the history recorded
// fourteen times in a row: sessions of four, eleven, even seventy seconds, all tagged
// "no audio" with an empty transcript.
//
// The check is deliberately physical. `say` speaks through the speakers while capture is
// running, and the built-in microphone hears it. That exercises the whole chain — device
// selection, the voice processor, the render graph, the realtime tap, the resampler — which
// is where the bug actually was: with voice processing enabled and nothing connected to the
// mixer, the duplex unit never rendered and the tap received zeros.
//
// Skips rather than fails when the environment cannot support it: no microphone permission
// for the test runner, or a machine with no input device.

import AVFoundation
import XCTest

@MainActor
final class AudioCaptureTests: XCTestCase {

    /// The same floor the coordinator uses to declare a session silent.
    private let silenceThreshold: Float = 0.005

    override func setUp() async throws {
        try await super.setUp()
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw XCTSkip("the test runner has no microphone permission")
        }
    }

    func testCaptureHearsSound() async throws {
        try await assertCaptureHearsSpeech()
    }

    // MARK: - Helper

    private func assertCaptureHearsSpeech(
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let engine = AudioCaptureEngine()
        engine.configure(
            vadEnabled: false,            // no auto-stop: this test controls the window
            silenceSeconds: 10,
            sensitivity: 3,
            inputDeviceUID: nil           // system default input
        )

        do {
            try engine.start()
        } catch {
            throw XCTSkip("no usable audio input: \(error.localizedDescription)")
        }

        await speakAloud("Testing testing one two three testing")
        // Let the tail of the utterance reach the tap.
        try? await Task.sleep(for: .milliseconds(400))

        let samples = engine.stop()

        XCTAssertFalse(samples.isEmpty, "the tap delivered no samples at all",
                       file: file, line: line)

        let peak = samples.map(abs).max() ?? 0
        XCTAssertGreaterThan(
            peak, silenceThreshold,
            """
            captured digital silence (peak \(peak), \(samples.count) samples). \
            This is the "no audio" failure.
            """,
            file: file, line: line
        )
    }

    /// Speak through the speakers and return once `say` has finished.
    private func speakAloud(_ text: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
                process.arguments = ["-r", "180", text]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try? process.run()
                process.waitUntilExit()
                continuation.resume()
            }
        }
    }
}
