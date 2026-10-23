// SelfTest.swift
// A one-shot end-to-end check that runs inside the real app.
//
// The XCTest bundle cannot open the microphone — the runner has no TCC grant and no prompt
// appears in a headless run, so the capture tests skip. The app does have the grant, so this
// exercises the chain the user actually depends on: microphone → realtime tap → resampler →
// model → transcript. It speaks through the speakers and listens with the built-in mic.
//
//   DICTARI_SELFTEST=1 /path/to/Dictari.app/Contents/MacOS/Dictari
//
// Prints a verdict and exits. Never runs unless the variable is set.

import AVFoundation
import AppKit

@MainActor
enum SelfTest {

    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["DICTARI_SELFTEST"] == "1"
    }

    /// Runs the check and terminates the process: 0 on success, 1 on failure.
    static func run(coordinator: AppCoordinator) async throws -> Never {
        var failures: [String] = []

        print("Dictari self-test")
        print("  model: \(coordinator.settings.activeModel.displayName)")

        // 1. Permissions — everything below is meaningless without them. *Request* the
        // microphone rather than just reading the status: the self-test is run interactively
        // from a terminal, which is exactly the one context where the TCC prompt can appear,
        // and a not-yet-determined (or signature-stale) grant used to fail here without ever
        // giving the user a chance to say yes.
        let micGranted = await AVCaptureDevice.requestAccess(for: .audio)
        var permissions = PermissionStatus.current()
        permissions.microphone = micGranted
        print("  microphone: \(permissions.microphone ? "granted" : "MISSING")")
        print("  accessibility: \(permissions.accessibility ? "granted" : "MISSING")")
        if !permissions.microphone { failures.append("microphone permission") }

        // 2. The model must actually load.
        let engine = AppCoordinator.makeEngine(for: coordinator.settings.activeModel)
        let modelStart = Date()
        do {
            try await engine.warmUp { _ in }
            print(String(format: "  model loaded in %.1f s", Date().timeIntervalSince(modelStart)))
        } catch {
            failures.append("model load: \(error.localizedDescription)")
            return finish(failures)
        }

        // 3. Capture. This is the step that silently returned zeros.
        let spoken = "The quick brown fox jumps over the lazy dog"
        guard permissions.microphone else { return finish(failures) }

        let audio = AudioCaptureEngine()
        audio.configure(vadEnabled: false, silenceSeconds: 10, sensitivity: 3,
                        inputDeviceUID: coordinator.settings.data.inputDeviceUID)
        // Start cost matters more than it looks: the user is already speaking by the time
        // they finish pressing the shortcut, so every millisecond here clips the first word.
        let prearmStart = Date()
        audio.prearm()
        print(String(format: "  audio prearm: %.0f ms",
                     Date().timeIntervalSince(prearmStart) * 1000))
        let audioStart = Date()
        do {
            try audio.start()
        } catch {
            failures.append("audio start: \(error.localizedDescription)")
            return finish(failures)
        }
        print(String(format: "  audio engine start (cold): %.0f ms",
                     Date().timeIntervalSince(audioStart) * 1000))

        // Does reusing the same engine object make the second start cheaper? If it does, the
        // fix is to keep it prepared between sessions rather than rebuilding the graph.
        _ = audio.stop()
        for attempt in 1...2 {
            // What the coordinator actually does between sessions.
            audio.prearm()
            let warmStart = Date()
            try? audio.start()
            let ms = Date().timeIntervalSince(warmStart) * 1000
            _ = audio.stop()
            print(String(format: "  audio engine start (session %d, re-armed): %.0f ms",
                         attempt, ms))
        }
        try audio.start()

        await speakAloud(spoken)
        try? await Task.sleep(for: .milliseconds(400))
        let samples = audio.stop()

        let peak = samples.map(abs).max() ?? 0
        // speechLevel is what the proximity filter actually judges — print it so the
        // thresholds can be set from a measurement instead of from taste.
        print(String(format: "  captured %d samples, peak %.4f, speechLevel %.4f",
                     samples.count, peak, audio.lastSpeechLevel))
        print("  proximity thresholds: gentle \(ProximityFilter.gentle.minimumSpeechLevel), "
              + "normal \(ProximityFilter.normal.minimumSpeechLevel), "
              + "strict \(ProximityFilter.strict.minimumSpeechLevel)")
        if peak < 0.005 {
            failures.append("captured digital silence")
            return finish(failures)
        }

        // 4. Transcribe what the microphone actually heard.
        let transcribeStart = Date()
        do {
            let text = try await engine.transcribe(samples: samples, language: "en")
            let latency = Int(Date().timeIntervalSince(transcribeStart) * 1000)
            print("  transcript: \"\(text)\"")
            print("  latency: \(latency) ms")
            if text.isEmpty { failures.append("transcript was empty") }
        } catch {
            failures.append("transcription: \(error.localizedDescription)")
        }

        // 5. How transcription time scales with utterance length. This decides whether
        // streaming is worth building: if cost grows with duration, a long dictation pays a
        // long wait at the end, and only incremental decoding fixes that.
        print("  scaling:")
        for seconds in [2, 5, 10, 20] {
            let slice = Array(repeating: samples, count: (seconds / 2) + 1)
                .flatMap { $0 }
                .prefix(16_000 * seconds)
            let start = Date()
            _ = try? await engine.transcribe(samples: Array(slice), language: "en")
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            print(String(format: "    %2ds audio -> %4d ms  (%.0fx realtime)",
                         seconds, ms, Double(seconds * 1000) / Double(max(ms, 1))))
        }

        return finish(failures)
    }

    private static func finish(_ failures: [String]) -> Never {
        if failures.isEmpty {
            print("PASS — microphone to transcript works end to end")
            exit(0)
        }
        print("FAIL")
        for failure in failures { print("  - \(failure)") }
        exit(1)
    }

    private static func speakAloud(_ text: String) async {
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
