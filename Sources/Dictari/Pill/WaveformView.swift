// WaveformView.swift
// Dictari — the signature live waveform shown inside the pill.
//
// PERFORMANCE-CRITICAL. This view sits on the 60fps hot path while dictating.
// Design constraints (see project build context):
//   • One Canvas draw call per frame — NOT 28 individually-animated SwiftUI shapes.
//   • Zero per-frame heap allocation. The only mutable per-frame state is a single
//     fixed-size [CGFloat] of smoothed bar heights, preallocated once and never grown.
//   • Strictly monochrome — bars use the `tint` colour (white on the dark pill).
//   • Idle cost is paid only by TimelineView(.animation), which the system pauses
//     when the view is off-screen; we add no spinning Timers of our own.

import SwiftUI

/// A compact, scrolling, monochrome level meter.
///
/// `levels` is a rolling buffer in `0...1` with the *newest* sample last. We map it to
/// `Metrics.waveformBarCount` bars, mirror each bar around the vertical center, and apply
/// per-frame exponential smoothing (fast attack / slow decay) so motion feels alive rather
/// than steppy. When inactive or silent, bars settle to the minimum height with a gentle
/// low-energy sine sway (~1pt) — suppressed under Reduce Motion.
struct WaveformView: View {
    /// Live level history, read by reference so a new sample does not invalidate the view.
    var levels: LevelBuffer
    var isActive: Bool
    /// Bar colour. White by default so the waveform reads on the always-dark pill.
    var tint: Color = .white

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Smoothed bar heights live in a reference holder so the Canvas closure can mutate them
    // in place every frame without triggering SwiftUI state invalidation (we are driven by
    // TimelineView, not by @State changes). Preallocated to the fixed bar count — never grows.
    @State private var smoothing = SmoothingState()

    var body: some View {
        // TimelineView(.animation) ticks once per display refresh (≈60/120fps) and is the
        // sole animation driver. No explicit per-bar SwiftUI animation, no Timer.
        TimelineView(.animation) { timeline in
            Canvas(opaque: false, rendersAsynchronously: false) { context, size in
                draw(in: &context,
                     size: size,
                     time: timeline.date.timeIntervalSinceReferenceDate)
            }
            // The Canvas content is purely computed; keep it from being treated as
            // accessibility-significant. (Canvas is already GPU-backed — no .drawingGroup,
            // which would add a redundant offscreen pass per frame.)
            .accessibilityHidden(true)
        }
        .accessibilityElement()
        .accessibilityLabel("Audio level")
    }

    // MARK: - Rendering

    private func draw(in context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        let barCount = Metrics.waveformBarCount
        let store = smoothing

        // Advance the smoothed heights toward their targets for this frame.
        store.step(targets: { index in targetHeight(for: index, barCount: barCount) },
                   barCount: barCount,
                   isActive: isActive,
                   hasSignal: hasSignal,
                   reduceMotion: reduceMotion,
                   time: time)

        // Layout: bars are laid out centered as a group, each centered vertically (mirrored).
        let barWidth = Metrics.waveformBarWidth
        let gap = Metrics.waveformBarGap
        let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * gap
        let startX = (size.width - totalWidth) / 2
        let centerY = size.height / 2
        let radius = Metrics.waveformBarRadius
        let color = tint

        // A single Path accumulates every rounded bar; one fill call submits them all.
        var path = Path()
        for index in 0..<barCount {
            let h = store.heights[index]
            let x = startX + CGFloat(index) * (barWidth + gap)
            let rect = CGRect(x: x,
                              y: centerY - h / 2,
                              width: barWidth,
                              height: h)
            path.addRoundedRect(in: rect, cornerSize: CGSize(width: radius, height: radius))
        }
        context.fill(path, with: .color(color))
    }

    // MARK: - Target mapping

    /// Whether the incoming buffer carries meaningful energy.
    private var hasSignal: Bool {
        guard isActive else { return false }
        // Cheap scan; the buffer is tiny (≈ bar count). Treat near-zero as silence.
        if levels.hasSignal() { return true }
        return false
    }

    /// Target (un-smoothed) height for a bar, mapping the newest sample to the trailing edge.
    /// Index 0 is oldest (leading), index barCount-1 is newest (trailing) → the meter scrolls.
    private func targetHeight(for index: Int, barCount: Int) -> CGFloat {
        let minH = Metrics.waveformMinHeight
        let maxH = Metrics.waveformMaxHeight
        guard isActive, levels.count > 0 else { return minH }

        // Map the bar index onto the levels buffer, aligning newest level to the last bar.
        // If the buffer is shorter than the bar count, older bars read as silence.
        let offsetFromNewest = (barCount - 1) - index            // 0 == newest
        let level = CGFloat(levels.sample(fromNewest: offsetFromNewest))
        return minH + (maxH - minH) * level
    }
}

// MARK: - Smoothing state (preallocated, mutated in place)

/// Holds the per-bar smoothed heights and the per-frame integrator. A reference type so the
/// Canvas closure can mutate it without SwiftUI state churn; all access is from the main
/// thread (the view's render pass), so no synchronization is required.
@MainActor
private final class SmoothingState {
    /// Smoothed, currently-displayed heights. Fixed length == waveformBarCount.
    var heights: [CGFloat]

    /// Last frame timestamp, for delta-time-based smoothing independent of refresh rate.
    private var lastTime: TimeInterval = 0

    init() {
        // Preallocate to the fixed bar count and seed at the resting height.
        heights = [CGFloat](repeating: Metrics.waveformMinHeight,
                            count: Metrics.waveformBarCount)
    }

    /// Advance every bar one frame toward its target.
    ///
    /// - Attack (rising) is faster than decay (falling) so peaks pop and tails relax.
    /// - When idle/silent, the resting target gets a tiny sine sway (~1pt) for liveliness.
    /// - Under Reduce Motion we skip smoothing and sway entirely: bars snap to target.
    func step(targets: (Int) -> CGFloat,
              barCount: Int,
              isActive: Bool,
              hasSignal: Bool,
              reduceMotion: Bool,
              time: TimeInterval) {

        // Defensive: keep the buffer at the expected size without per-frame reallocation
        // in the steady state (this branch only runs once if the constant ever changes).
        if heights.count != barCount {
            heights = [CGFloat](repeating: Metrics.waveformMinHeight, count: barCount)
        }

        // Delta time, clamped so a stall (app paused, debugger) can't produce a huge jump.
        var dt = time - lastTime
        lastTime = time
        if dt <= 0 || dt > 0.1 { dt = 1.0 / 60.0 }

        if reduceMotion {
            // Minimal interpolation: map levels directly, no sway. Still updates each tick.
            for index in 0..<barCount {
                heights[index] = targets(index)
            }
            return
        }

        // Exponential smoothing coefficients. Higher == snappier. Converted from a per-frame
        // base (tuned at 60fps) into a dt-aware factor so 120Hz displays match feel.
        let attackPerSec: CGFloat = 32   // rising
        let decayPerSec: CGFloat = 12    // falling
        let restEnergy = isActive && hasSignal

        let minH = Metrics.waveformMinHeight
        // Idle sway: a gentle ~1pt sine, phase-shifted per bar so the row breathes.
        let swayAmplitude: CGFloat = 1.0

        for index in 0..<barCount {
            var target = targets(index)

            if !restEnergy {
                // Phase offset per bar (cheap, no allocation) for a soft travelling ripple.
                let phase = Double(index) * 0.45
                let sway = sin(time * 1.6 + phase)
                target = minH + swayAmplitude * 0.5 * (1 + CGFloat(sway))
            }

            let current = heights[index]
            let rising = target > current
            let rate = rising ? attackPerSec : decayPerSec
            // Frame-rate-independent exponential approach: 1 - e^(-rate*dt).
            let alpha = 1 - CGFloat(exp(Double(-rate) * dt))
            heights[index] = current + (target - current) * alpha
        }
    }
}
