#if DEBUG
import Foundation

/// Explicit visual harness only: bounded geometry samples, never transcript or user data.
@MainActor
enum PillMotionProbe {
    private struct Sample: Codable {
        var time: Double
        var x: Double
        var y: Double
        var width: Double
        var height: Double
    }
    private static var samples: [Sample] = []
    private static var flushTask: Task<Void, Never>?
    private static let started = ProcessInfo.processInfo.systemUptime

    static func record(frame: CGRect) {
        guard ProcessInfo.processInfo.environment["DICTARI_WRITING_UI_PREVIEW"] == "motion" else { return }
        if samples.count == 512 { samples.removeFirst(128) }
        samples.append(Sample(time: ProcessInfo.processInfo.systemUptime - started,
                              x: frame.minX, y: frame.minY, width: frame.width, height: frame.height))
        flushTask?.cancel()
        flushTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
            guard !Task.isCancelled, let data = try? JSONEncoder().encode(samples) else { return }
            try? data.write(to: URL(fileURLWithPath: "/tmp/dictari-pill-motion.json"), options: .atomic)
        }
    }
}
#endif
