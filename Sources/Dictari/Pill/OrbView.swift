// OrbView.swift
// Dictari — the minimal pill: a circle that answers one question, "is it hearing me?"
//
// No text, no capsule, no chrome. Bars inside a dark disc rise the instant sound arrives and
// fall the instant it stops, so the thing reads as a microphone rather than as a widget.
//
// PERFORMANCE-CRITICAL, same rules as WaveformView: one Canvas draw call per frame, no
// per-frame heap allocation, driven solely by TimelineView(.animation).
//
// Response shape is deliberately asymmetric. Attack is nearly instantaneous — a bar reaches
// most of a new peak within one frame, because any perceptible lag makes the orb feel like it
// is reporting the past rather than the present. Decay is slower, or the bars would strobe on
// the natural gaps between syllables.

import SwiftUI

struct OrbView: View {
    /// Live level history. A reference, so the Canvas reads the newest value each frame
    /// without the view graph being invalidated fifty times a second.
    var levels: LevelBuffer
    var isActive: Bool
    var tint: Color = .white

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Smoothed per-bar heights, preallocated once. A reference type so the Canvas closure
    /// can mutate it in place without invalidating SwiftUI state every frame.
    @State private var smoothing = OrbSmoothing()

    private var newestLevel: CGFloat {
        guard isActive else { return 0 }
        return CGFloat(levels.latest)
    }

    var body: some View {
        // Paused while idle: with "always show pill" the orb is permanently on screen, and an
        // unpaused `.animation` timeline redraws the resting disc at display refresh forever.
        // The idle frame is static by construction (level 0, whisper gated on `isActive`), so
        // pausing costs one visual nicety only — the ~100 ms decay animation on the
        // listening→idle flip snaps instead (`draw` zeroes the bars when inactive).
        TimelineView(.animation(minimumInterval: nil, paused: !isActive)) { timeline in
            Canvas(opaque: false, rendersAsynchronously: false) { context, size in
                draw(in: &context,
                     size: size,
                     time: timeline.date.timeIntervalSinceReferenceDate)
            }
            .accessibilityHidden(true)
        }
        .accessibilityElement()
        .accessibilityLabel(isActive ? "Listening" : "Idle")
    }

    // MARK: - Drawing

    private func draw(in context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        // Elapsed time since the previous frame, clamped so a stall (debugger, app paused)
        // cannot produce one enormous jump.
        var dt = CGFloat(time - smoothing.lastTime)
        smoothing.lastTime = time
        if dt <= 0 || dt > 0.1 { dt = 1.0 / 60.0 }

        // The timeline is paused while idle, so this frame is the last one drawn until the
        // orb activates again: settle the bars instead of freezing them mid-decay.
        if !isActive {
            for index in 0..<OrbSmoothing.barCount { smoothing.heights[index] = 0 }
        }

        let diameter = min(size.width, size.height)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)

        // The disc.
        let disc = Path(ellipseIn: CGRect(
            x: center.x - diameter / 2, y: center.y - diameter / 2,
            width: diameter, height: diameter
        ))
        context.fill(disc, with: .color(Mono.pillFill))

        // Bars.
        let count = OrbSmoothing.barCount
        let barWidth = diameter * 0.075
        let spacing = diameter * 0.075
        let totalWidth = CGFloat(count) * barWidth + CGFloat(count - 1) * spacing
        var x = center.x - totalWidth / 2

        let level = newestLevel
        let maxHeight = diameter * 0.52
        let minHeight = barWidth   // a dot, so the orb never looks switched off

        // One path and one fill for all bars — five separate `Path`/`fill` pairs per frame
        // was ~600 CGPath allocations a second at 120 Hz, against this file's own
        // no-per-frame-allocation rule (WaveformView already draws this way).
        var bars = Path()
        let shading = GraphicsContext.Shading.color(tint.opacity(isActive ? 0.95 : 0.4))

        for index in 0..<count {
            // Centre bars carry more of the level than the outer ones, which is what makes a
            // flat number read as a voice rather than as a bar chart.
            let weight = OrbSmoothing.weights[index]
            var target = level * weight

            // A whisper of movement while listening in silence, so "armed" is visibly
            // different from "off" without implying signal that is not there.
            if isActive, level < 0.02, !reduceMotion {
                target += 0.03 * CGFloat(sin(time * 2.4 + Double(index) * 0.9))
            }
            target = max(0, min(1, target))

            let previous = smoothing.heights[index]
            // Attack almost immediately, release gently. Under Reduce Motion, snap: the
            // level itself is the only movement.
            //
            // The coefficient is derived from elapsed time, not applied per frame: a fixed
            // per-frame fraction converges twice as fast on a 120 Hz display as on 60 Hz, so
            // the orb would visibly react differently on different Macs — and on an external
            // monitor versus the built-in one. WaveformView already works this way.
            let tau: CGFloat = target > previous ? 0.012 : 0.09
            let coefficient: CGFloat = reduceMotion ? 1 : 1 - exp(-dt / tau)
            let smoothed = previous + (target - previous) * min(1, coefficient)
            smoothing.heights[index] = smoothed

            let height = minHeight + smoothed * (maxHeight - minHeight)
            let rect = CGRect(x: x, y: center.y - height / 2, width: barWidth, height: height)
            bars.addRoundedRect(in: rect, cornerSize: CGSize(width: barWidth / 2, height: barWidth / 2))
            x += barWidth + spacing
        }
        context.fill(bars, with: shading)
    }
}

/// Fixed-size smoothing state for the orb's bars.
@MainActor
private final class OrbSmoothing {
    static let barCount = 5
    /// Centre-weighted so the cluster reads as a voice rather than a level meter.
    static let weights: [CGFloat] = [0.45, 0.78, 1.0, 0.78, 0.45]

    var heights: [CGFloat] = Array(repeating: 0, count: OrbSmoothing.barCount)
    var lastTime: TimeInterval = 0
}
