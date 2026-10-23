// OnboardingChrome.swift
// Dictari — the shared furniture of the first-run flow: the step identity, the scaffold
// every step is poured into, the buttons, the staged-entrance modifier, and the synthetic
// level source that lets the pill breathe before the microphone is ever granted.
//
// Nothing here knows what any individual step says. Steps own their own strings.

import SwiftUI

// MARK: - Layout

/// Geometry that belongs to onboarding alone. `Metrics` stays the app-wide source of truth;
/// these are the numbers only this window uses.
enum OnboardingLayout {
    static let window = CGSize(width: 720, height: 520)
    /// Horizontal margin of every step's content.
    static let margin: CGFloat = 56
    /// Height of the bottom bar: step counter, step indicator, caption. It is the window's
    /// chrome, so steps compose against `stage` and treat this band as already spoken for.
    static let footerHeight: CGFloat = 64
    /// The area a step actually composes in — everything above the footer.
    static var stage: CGSize { CGSize(width: window.width, height: window.height - footerHeight) }
    /// matchedGeometry id of the one element that survives every step: the pill.
    static let pillID = "dictari.onboarding.pill"

    // MARK: Pill

    /// The hero on the welcome step. Larger than life — it is the only object on that screen —
    /// but the same slim capsule as `Metrics.pillRecordingSize` (360×44), never a slab.
    // Larger than the real 360×44 pill because it is the hero, but only just: at 420 pt it
    // took up nearly 60% of the window's width and read as a black slab rather than as the
    // object the user is about to live with.
    static let heroPill = CGSize(width: 344, height: 48)
    /// The small mark the pill shrinks to while the user grants permissions and picks a model.
    /// Proportioned off `Metrics.pillIdleSize` (120×28) for the same reason.
    static let markPill = CGSize(width: 112, height: 26)
    /// Welcome step: distance from the top of the stage to the top of the hero pill, and the
    /// air between the pill and the title under it. The pill anchor is derived from these, so
    /// the reserved footprint and the travelling pill can never drift apart.
    static let heroTop: CGFloat = 122
    static let heroTitleGap: CGFloat = 50

    // MARK: Step indicator

    static let stepMarkWidth: CGFloat = 18
    static let stepMarkCurrentWidth: CGFloat = 30
    static let stepMarkHeight: CGFloat = 3
    static let stepMarkGap: CGFloat = 5
}

// MARK: - Steps

/// The four screens, in order. `rawValue` is the position, so progress is arithmetic.
enum OnboardingStepID: Int, CaseIterable, Identifiable, Hashable {
    case welcome = 0
    case permissions
    case model
    case dictation

    var id: Int { rawValue }

    var next: OnboardingStepID? { OnboardingStepID(rawValue: rawValue + 1) }

    /// "01" — shown next to the total in the footer.
    var number: String { String(format: "%02d", rawValue + 1) }
}

// MARK: - Step indicator

/// One short segment per step, sitting in the footer between the `01 / 04` counter and the
/// caption.
///
/// The previous indicator was a single hairline filling across the very bottom edge of the
/// window: at a glance it read as a scrollbar or a rendering seam rather than as progress,
/// because a partially-filled line carries no idea of "how many". Four discrete marks say
/// "step two of four" without a word, and the current one is the only one at full ink — so
/// the eye finds position, not just proportion. It stays deliberately small; the counter
/// beside it already spells the number out.
struct OnboardingStepIndicator: View {
    var current: OnboardingStepID

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: OnboardingLayout.stepMarkGap) {
            ForEach(OnboardingStepID.allCases) { step in
                Capsule(style: .continuous)
                    .fill(fill(for: step))
                    .frame(
                        width: step == current
                            ? OnboardingLayout.stepMarkCurrentWidth
                            : OnboardingLayout.stepMarkWidth,
                        height: OnboardingLayout.stepMarkHeight
                    )
            }
        }
        .animation(Motion.reduced(Motion.morph, reduceMotion: reduceMotion), value: current)
        .accessibilityElement()
        .accessibilityLabel(Strings.label)
        .accessibilityValue("\(current.rawValue + 1) of \(OnboardingStepID.allCases.count)")
    }

    /// Done steps keep a trace of ink so the row shows how far along it is; steps still to
    /// come are barely there. Both read correctly in either appearance because `Mono.ink`
    /// is the adaptive primary, not a fixed black.
    private func fill(for step: OnboardingStepID) -> Color {
        if step == current { return Mono.ink(0.85) }
        return step.rawValue < current.rawValue ? Mono.ink(0.32) : Mono.ink(0.12)
    }

    private enum Strings {
        static let label = String(localized: "Setup progress", comment: "Onboarding")
    }
}

// MARK: - Staged entrance

/// Fades and lifts a view into place, `index` positions later than its predecessor.
///
/// Staging is the whole reason the flow reads as composed rather than as a form: the title
/// settles first, then the body, then the control that asks for something. Under Reduce
/// Motion the offsets and the stagger both collapse — the content simply is there.
private struct StagedAppear: ViewModifier {
    let index: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 9)
            .animation(
                Motion.reduced(Motion.appear, reduceMotion: reduceMotion)
                    .delay(reduceMotion ? 0 : Double(index) * 0.07),
                value: shown
            )
            .onAppear { shown = true }
    }
}

extension View {
    /// Enter as element number `index` of this step's sequence.
    func staged(_ index: Int) -> some View { modifier(StagedAppear(index: index)) }
}

// MARK: - Scaffold

/// The shape every step shares: a title block, free-form content, and a trailing row of
/// actions pinned to the bottom. Keeping this in one place is what makes four screens feel
/// like one object rather than four pages.
struct OnboardingScaffold<Content: View, Actions: View>: View {
    /// Vertical space reserved above the title for the pill in its small "mark" position.
    var topInset: CGFloat = 78
    var eyebrow: String?
    var title: String
    var subtitle: String?
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0).frame(height: topInset)

            VStack(alignment: .leading, spacing: 6) {
                if let eyebrow {
                    Text(eyebrow.uppercased())
                        .font(Typo.sectionLabel)
                        .tracking(1.1)
                        .foregroundStyle(Mono.tertiaryText)
                        .staged(0)
                }
                Text(title)
                    .font(Typo.screenTitle)
                    .foregroundStyle(Mono.primaryText)
                    .staged(1)
                if let subtitle {
                    Text(subtitle)
                        .font(Typo.body)
                        .foregroundStyle(Mono.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 460, alignment: .leading)
                        .staged(2)
                }
            }

            content
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 12)

            HStack(spacing: 10) {
                Spacer(minLength: 0)
                actions
            }
            .staged(5)
        }
        .padding(.horizontal, OnboardingLayout.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Buttons

/// The only three button weights onboarding needs. Monochrome, pressed-scale, no tint.
struct OnboardingButton: View {
    enum Kind {
        /// Filled ink — the one thing the step wants the user to do.
        case primary
        /// Outlined — a real alternative, but not the point.
        case secondary
        /// Text only — "later", "skip". Deliberately hard to mistake for the primary.
        case quiet
    }

    var title: String
    var kind: Kind = .primary
    var isEnabled: Bool = true
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: kind == .quiet ? .regular : .medium))
                .foregroundStyle(foreground)
                .padding(.horizontal, kind == .quiet ? 8 : 18)
                .frame(height: 32)
                .background(background)
                .overlay {
                    if kind == .secondary {
                        Capsule(style: .continuous).strokeBorder(Mono.ink(0.16), lineWidth: 1)
                    }
                }
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(OnboardingPressStyle())
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
        .animation(Motion.snap, value: isEnabled)
    }

    private var foreground: Color {
        switch kind {
        case .primary:   return Mono.selectionText
        case .secondary: return Mono.primaryText
        case .quiet:     return Mono.secondaryText
        }
    }

    @ViewBuilder
    private var background: some View {
        switch kind {
        case .primary:   Capsule(style: .continuous).fill(Mono.ink())
        case .secondary: Capsule(style: .continuous).fill(Color.clear)
        case .quiet:     Capsule(style: .continuous).fill(Color.clear)
        }
    }
}

/// Shared press feedback so every control in the flow reacts identically.
struct OnboardingPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(MonoPressFeedback(isPressed: configuration.isPressed))
    }
}

// MARK: - The pill

/// The signature dark capsule, rendered once by `OnboardingView` and moved between steps by
/// `matchedGeometryEffect`. It has no size of its own — the anchor it is matched to supplies
/// the frame — so the content scales to whatever it is handed.
struct OnboardingPill: View {
    var levels: LevelBuffer
    var isActive: Bool
    /// When set, the capsule shows recognised text instead of the meter.
    var transcript: String?

    /// The meter's natural drawn size: `waveformBarCount` fixed-width bars at full height.
    /// `WaveformView` lays its bars out from `Metrics` in absolute points, so handing it a
    /// bigger frame only adds empty margin around a tiny row of ticks. The capsule is filled
    /// by scaling that natural block instead.
    private static let meterSize = CGSize(
        width: CGFloat(Metrics.waveformBarCount) * Metrics.waveformBarWidth
            + CGFloat(Metrics.waveformBarCount - 1) * Metrics.waveformBarGap,
        height: Metrics.waveformMaxHeight
    )

    /// How far the bars may be stretched horizontally relative to their vertical scale. The
    /// pill is a ~7:1 capsule and the meter is ~5:1, so some stretch is needed to span it;
    /// past this the row stops reading as a waveform and starts reading as a comb.
    private static let meterStretchLimit: CGFloat = 2.2

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Capsule(style: .continuous).fill(Mono.pillFill)

                if let transcript, !transcript.isEmpty {
                    HStack(spacing: 9) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Mono.pillOn(0.75))
                        Text(transcript)
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(Mono.pillOn(0.96))
                            // Two lines is what a 52pt capsule holds; a third would be clipped
                            // by the shape, which is worse than an ellipsis.
                            .lineLimit(2)
                            .truncationMode(.tail)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 22)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                } else {
                    let scale = Self.meterScale(in: geo.size)
                    WaveformView(levels: levels, isActive: isActive, tint: Mono.pillOn())
                        .frame(width: Self.meterSize.width, height: Self.meterSize.height)
                        .scaleEffect(x: scale.width, y: scale.height, anchor: .center)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    /// Bars take just over half the capsule's height and as much of its width as the round
    /// end caps leave free — so the meter reads as the capsule's content rather than as
    /// something floating in the middle of it.
    private static func meterScale(in size: CGSize) -> CGSize {
        let vertical = size.height * 0.52 / meterSize.height
        // The caps are unusable width: a bar sitting in one would poke out of the shape.
        let inset = size.height * 0.55
        let free = max(size.width - inset * 2, 0)
        let horizontal = min(free / meterSize.width, vertical * meterStretchLimit)
        return CGSize(width: max(horizontal, vertical), height: vertical)
    }
}

// MARK: - Synthetic levels

/// Feeds a `LevelBuffer` with a plausible speech envelope.
///
/// Step one has to show the product doing its one trick before the user has granted the
/// microphone — a frozen pill would be a screenshot of the app rather than the app. The shape
/// is deliberately speech-like (syllable bursts inside phrase-length swells with pauses
/// between them) rather than a sine: a metronome reads as a loading bar, not as a voice.
@MainActor
final class SyntheticLevelSource {
    let buffer = LevelBuffer()
    private var time: Double = 0

    /// Advance by one 20 ms frame.
    func tick() {
        time += 0.02
        // Phrase envelope: long swells, like sentences — but it breathes rather than stopping.
        // A bare `max(0, sin(…))` is zero for half its period, which left the hero pill flat and
        // lifeless for roughly five seconds at a time. It is the first thing anyone sees when
        // the app opens, so it must never look switched off.
        let phrase = 0.30 + 0.70 * max(0, sin(time * 0.62))
        // Syllables riding on top of the phrase.
        let syllables = pow(max(0, sin(time * 8.4)), 1.6)
        let jitter = Double.random(in: 0...0.06)
        let level = 0.06 + 0.78 * phrase * syllables + jitter * phrase
        buffer.append(Float(min(1, level)))
    }

    /// Drive the buffer until the calling task is cancelled.
    func run() async {
        while !Task.isCancelled {
            tick()
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}
