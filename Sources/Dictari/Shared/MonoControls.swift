// MonoControls.swift
// Dictari — small, dependency-free B/W building blocks used across
// settings, dashboard, and any future view.
//
// Naming: MonoCard, DotMeter, SettingRow — unique and collision-safe.
//
// Design principles applied (make-interfaces-feel-better):
// - Concentric border radius: card outer radius + card padding = inner content radius
// - Scale on press (0.96) where interactive
// - Minimum 40 pt hit area on SettingRow via frame
// - Tabular numbers on DotMeter count labels via .monospacedDigit()
// - Shadows layered over borders where appropriate (card)
// - Interruptible spring animations on hover/press state

import SwiftUI

struct MonoPressFeedback: ViewModifier {
    let isPressed: Bool
    var scales = true
    var pressedScale: CGFloat = 0.96
    var hoverBackground: Color? = nil
    var cornerRadius: CGFloat = 6
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .background {
                if let hoverBackground {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(enabled && (hovered || isPressed) ? hoverBackground : Color.clear)
                        .animation(Motion.reduced(Motion.hover, reduceMotion: reduceMotion), value: hovered)
                        .animation(Motion.reduced(Motion.press, reduceMotion: reduceMotion), value: isPressed)
                }
            }
            .opacity(enabled ? (isPressed ? 0.85 : (hovered ? 0.92 : 1)) : 0.45)
            .scaleEffect(enabled && scales && isPressed && !reduceMotion ? pressedScale : 1)
            // The press lands immediately; release uses the spring and retargets cleanly
            // when someone clicks repeatedly.
            .animation(
                Motion.reduced(isPressed ? Motion.press : Motion.snap, reduceMotion: reduceMotion),
                value: isPressed
            )
            .animation(Motion.reduced(Motion.hover, reduceMotion: reduceMotion), value: hovered)
            .onHover { hovered = $0 && enabled }
    }
}

struct MonoPlainButtonStyle: ButtonStyle {
    var scales = true
    var pressedScale: CGFloat = 0.96
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .modifier(MonoPressFeedback(
                isPressed: configuration.isPressed,
                scales: scales,
                pressedScale: pressedScale
            ))
    }
}

// MARK: - Reduce-Motion-aware animation helpers

extension View {
    /// `.animation(_:value:)` that reads Reduce Motion itself, so call sites don't have to
    /// plumb the environment value. Under Reduce Motion the change becomes a 0.1 s
    /// cross-fade (`Motion.reduced`), never a slide or a scale.
    func monoAnimation<V: Equatable>(_ animation: Animation, value: V) -> some View {
        modifier(MonoAnimationModifier(animation: animation, value: value))
    }
}

private struct MonoAnimationModifier<V: Equatable>: ViewModifier {
    let animation: Animation
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(Motion.reduced(animation, reduceMotion: reduceMotion), value: value)
    }
}

extension AnyTransition {
    /// Content appearing in place (a disclosure's rows, an inline notice): fades in while
    /// settling `Motion.travel` points down; leaves with a plain fade. Pass Reduce Motion so
    /// the travel drops out.
    static func monoReveal(reduceMotion: Bool) -> AnyTransition {
        reduceMotion
            ? .opacity
            : .asymmetric(insertion: .opacity.combined(with: .offset(y: -Motion.travel)),
                          removal: .opacity)
    }

    /// A settings page replacing another. The incoming page rises `Motion.travel` points;
    /// the outgoing one only fades, on the quicker `Motion.pageExit`.
    static func monoPage(reduceMotion: Bool) -> AnyTransition {
        reduceMotion
            ? .opacity
            : .asymmetric(
                insertion: .opacity.combined(with: .offset(y: Motion.travel)).animation(Motion.page),
                removal: .opacity.animation(Motion.pageExit)
            )
    }
}

// MARK: - MonoActionButtonStyle

/// The settings button. One style, four roles, two sizes — replaces the per-screen copies
/// (`MediaActionStyle`, `VocabularyQuietButtonStyle`, `DestructiveMonoButtonStyle`, …).
///
/// - `.primary`: ink fill, paper text. At most one per card; it is the only emphasis Mono has.
/// - `.secondary`: field-grey fill. The default for everything else.
/// - `.outline`: hairline border, no fill. For an alternative next to a primary.
/// - `.destructive`: outline with a stronger stroke. Monochrome, so the word carries the
///   danger ("Delete All…"); pair it with a confirmation, never with colour.
///
/// ```swift
/// Button("Import…") { … }.buttonStyle(MonoActionButtonStyle(.primary))
/// Button("Done") { … }.buttonStyle(MonoActionButtonStyle())
/// Button("Copy") { … }.buttonStyle(MonoActionButtonStyle(.secondary, size: .small))
/// ```
struct MonoActionButtonStyle: ButtonStyle {
    enum Role { case primary, secondary, outline, destructive }
    enum Size { case regular, small }

    var role: Role = .secondary
    var size: Size = .regular

    init(_ role: Role = .secondary, size: Size = .regular) {
        self.role = role
        self.size = size
    }

    func makeBody(configuration: Configuration) -> some View {
        MonoActionButtonBody(configuration: configuration, role: role, size: size)
    }
}

private struct MonoActionButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let role: MonoActionButtonStyle.Role
    let size: MonoActionButtonStyle.Size
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var radius: CGFloat { size == .regular ? Metrics.controlRadius : Metrics.controlRadius - 1 }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let lit = enabled && (hovered || configuration.isPressed)
        configuration.label
            .font(size == .regular ? Typo.button : Typo.buttonSmall)
            .lineLimit(1)
            .foregroundStyle(role == .primary ? Mono.selectionText : Mono.primaryText)
            .padding(.horizontal, size == .regular ? 12 : 9)
            .frame(minHeight: size == .regular ? Metrics.controlHeight : Metrics.controlHeightSmall)
            .background {
                switch role {
                case .primary:
                    shape.fill(Mono.ink(configuration.isPressed ? 0.78 : (lit ? 0.86 : 1)))
                case .secondary:
                    shape.fill(Mono.fieldFill)
                    shape.fill(lit ? Mono.hover : Color.clear)
                case .outline, .destructive:
                    shape.fill(lit ? Mono.hover : Color.clear)
                }
            }
            .overlay {
                switch role {
                case .outline: shape.strokeBorder(Mono.ink(0.18), lineWidth: 1)
                case .destructive: shape.strokeBorder(Mono.ink(0.55), lineWidth: 1)
                default: EmptyView()
                }
            }
            .contentShape(shape)
            .opacity(enabled ? 1 : 0.4)
            .scaleEffect(enabled && configuration.isPressed && !reduceMotion ? 0.97 : 1)
            // Press lands immediately; release springs and retargets on repeated clicks.
            .animation(Motion.reduced(configuration.isPressed ? Motion.press : Motion.snap,
                                      reduceMotion: reduceMotion),
                       value: configuration.isPressed)
            .animation(Motion.reduced(Motion.hover, reduceMotion: reduceMotion), value: hovered)
            .onHover { hovered = $0 }
    }
}

// MARK: - MonoGlyphButtonStyle

/// Icon-only button: a square hit area with a hover wash. For row accessories (remove,
/// reveal in Finder, more…). Always give the button an `accessibilityLabel` and `.help`.
///
/// ```swift
/// Button { remove() } label: { Image(systemName: "trash") }
///     .buttonStyle(MonoGlyphButtonStyle())
///     .accessibilityLabel("Remove").help("Remove")
/// ```
struct MonoGlyphButtonStyle: ButtonStyle {
    var side: CGFloat = 26

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.iconOnly)
            .symbolRenderingMode(.monochrome)
            .imageScale(.medium)
            .foregroundStyle(Mono.secondaryText)
            .frame(width: side, height: side)
            .contentShape(RoundedRectangle(cornerRadius: Metrics.controlRadius - 1, style: .continuous))
            .modifier(MonoPressFeedback(
                isPressed: configuration.isPressed,
                hoverBackground: Mono.hover,
                cornerRadius: Metrics.controlRadius - 1
            ))
    }
}

// MARK: - MonoCopyButton

/// A button that confirms itself: "Copy" swaps to a checkmark + "Copied" for
/// `Motion.feedbackHold`, then reverts. The width is reserved for the longer label so the
/// row never jumps. The caller owns the pasteboard write in `action`; this view only
/// presents the confirmation.
///
/// ```swift
/// MonoCopyButton { NSPasteboard.general.… }                       // "Copy"
/// MonoCopyButton("Copy Link", size: .small) { … }
/// ```
struct MonoCopyButton: View {
    private let title: Text
    private let confirmation: Text
    var role: MonoActionButtonStyle.Role = .secondary
    var size: MonoActionButtonStyle.Size = .regular
    let action: () -> Void

    @State private var confirmed = false
    @State private var resetTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// `nil` titles use the standard "Copy" / "Copied". Literals passed here are localized.
    init(_ title: LocalizedStringKey? = nil, confirmation: LocalizedStringKey? = nil,
         role: MonoActionButtonStyle.Role = .secondary,
         size: MonoActionButtonStyle.Size = .regular,
         action: @escaping () -> Void) {
        self.title = title.map { Text($0) }
            ?? Text("Copy", comment: "Button that copies text to the clipboard")
        self.confirmation = confirmation.map { Text($0) }
            ?? Text("Copied", comment: "Shown briefly on a Copy button after it copied to the clipboard")
        self.role = role
        self.size = size
        self.action = action
    }

    var body: some View {
        Button {
            action()
            withAnimation(Motion.reduced(Motion.swap, reduceMotion: reduceMotion)) { confirmed = true }
            resetTask?.cancel()
            resetTask = Task { @MainActor in
                try? await Task.sleep(for: Motion.feedbackHold)
                guard !Task.isCancelled else { return }
                withAnimation(Motion.reduced(Motion.swap, reduceMotion: reduceMotion)) { confirmed = false }
            }
        } label: {
            // Both labels are laid out; only one is visible. Reserves the wider width.
            ZStack {
                title.opacity(confirmed ? 0 : 1)
                Label { confirmation } icon: { Image(systemName: "checkmark") }
                    .labelStyle(.titleAndIcon)
                    .opacity(confirmed ? 1 : 0)
            }
        }
        .buttonStyle(MonoActionButtonStyle(role, size: size))
        .accessibilityLabel(confirmed ? confirmation : title)
        .onDisappear { resetTask?.cancel() }
    }
}

// MARK: - MonoCard

/// A rounded card surface with optional title and arbitrary content.
///
/// ```swift
/// MonoCard(title: "Audio") {
///     Toggle("Noise suppression", isOn: $noisy)
/// }
/// ```
struct MonoCard<Content: View>: View {
    var title: LocalizedStringKey?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: title != nil ? 10 : 0) {
            if let title {
                Text(title)
                    .font(Typo.cardTitle)
                    .foregroundStyle(Mono.primaryText)
            }

            content
        }
        .padding(Metrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        // One restrained shadow, cast by the surface shape only: shadowing the whole card
        // would blur its text and controls too, an off-screen pass per card per frame.
        .background(
            RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                .fill(Mono.card)
                .shadow(color: Mono.cardShadow, radius: 4, x: 0, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                .strokeBorder(Mono.cardBorder, lineWidth: 0.5)
        )
    }
}

// MARK: - MonoSegmented

/// A strictly black & white segmented control. Replaces the system `.segmented` Picker,
/// which renders the blue accent on macOS. Selected segment = ink fill + inverse text; the
/// thumb slides between segments on `Motion.select` (matchedGeometry). Under Reduce Motion
/// the thumb cross-fades in place instead of travelling. Unselected segments show a soft
/// hover wash so the control reads as clickable.
struct MonoSegmented<T: Hashable>: View {
    @Binding var selection: T
    private let options: [(value: T, label: Text)]
    @Namespace private var ns
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Labels written as literals in the call (`[(.a, "Meeting"), (.b, "File")]`): localized.
    init(selection: Binding<T>, options: [(value: T, label: LocalizedStringKey)]) {
        _selection = selection
        self.options = options.map { ($0.value, Text($0.label)) }
    }

    /// Labels computed at runtime (`Enum.allCases.map { ($0, $0.label) }`), shown as is: make
    /// `label` return `String(localized:)` at its source.
    @_disfavoredOverload
    init(selection: Binding<T>, options: [(value: T, label: String)]) {
        _selection = selection
        self.options = options.map { ($0.value, Text(verbatim: $0.label)) }
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { opt in
                MonoSegment(
                    label: opt.label,
                    isSelected: opt.value == selection,
                    namespace: ns,
                    slides: !reduceMotion
                ) {
                    withAnimation(Motion.reduced(Motion.select, reduceMotion: reduceMotion)) {
                        selection = opt.value
                    }
                }
            }
        }
        .padding(3)
        .background(Capsule(style: .continuous).fill(Mono.fieldFill))
        .accessibilityElement(children: .contain)
    }
}

private struct MonoSegment: View {
    let label: Text
    let isSelected: Bool
    let namespace: Namespace.ID
    let slides: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            label
                .font(Typo.secondary.weight(.medium))
                .foregroundStyle(isSelected ? Mono.selectionText : (hovered ? Mono.primaryText : Mono.secondaryText))
                .lineLimit(1)
                .padding(.vertical, 5)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity)
                .background {
                    if isSelected {
                        if slides {
                            Capsule(style: .continuous)
                                .fill(Mono.selection)
                                .matchedGeometryEffect(id: "segSelection", in: namespace)
                        } else {
                            Capsule(style: .continuous).fill(Mono.selection)
                        }
                    } else if hovered {
                        Capsule(style: .continuous).fill(Mono.hover)
                    }
                }
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(MonoPlainButtonStyle(scales: false))
        .onHover { hovered = $0 }
        .monoAnimation(Motion.hover, value: hovered)
        .accessibilityLabel(label)
        .accessibilityValue(isSelected ? "Selected" : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - DotMeter

/// A row of filled/empty dots representing a 1…n rating (speed, accuracy, etc.)
///
/// ```swift
/// DotMeter(filled: model.speed)         // uses default total of 5
/// DotMeter(filled: 3, total: 5)
/// ```
struct DotMeter: View {
    var filled: Int
    var total: Int = 5

    // Dot geometry
    private let dotSize: CGFloat = 7
    private let dotSpacing: CGFloat = 4

    var body: some View {
        HStack(spacing: dotSpacing) {
            ForEach(0..<total, id: \.self) { index in
                Circle()
                    .fill(index < filled ? Mono.ink(0.80) : Mono.ink(0.15))
                    .frame(width: dotSize, height: dotSize)
                    // Concentric: no inner content, so no nested radius needed
            }
        }
        // Expose filled count to accessibility as a numeric value
        .accessibilityElement()
        .accessibilityLabel("\(filled) out of \(total)")
        .accessibilityValue("\(filled)")
    }
}

// MARK: - SettingRow

/// A single label + trailing control row at `Metrics.rowHeight`.
///
/// ```swift
/// SettingRow(label: "Injection method") {
///     Picker("", selection: $method) { … }
///         .labelsHidden()
/// }
/// ```
struct SettingRow<Trailing: View>: View {
    var label: LocalizedStringKey
    var sublabel: LocalizedStringKey? = nil
    @ViewBuilder var trailing: Trailing

    // Hover feedback (macOS)
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            // Label stack
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(Typo.body)
                    .foregroundStyle(Mono.primaryText)

                if let sublabel {
                    Text(sublabel)
                        .font(Typo.secondary)
                        .foregroundStyle(Mono.tertiaryText)
                }
            }

            Spacer(minLength: 12)

            trailing
        }
        // Ensure minimum 40 pt hit area (surfaces principle)
        .frame(minHeight: Metrics.rowHeight)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                // Inner radius = card outer radius (12) − padding (16) ≈ use 7 for nested content
                .fill(isHovered ? Mono.hover : Color.clear)
                .animation(Motion.snap, value: isHovered)
        )
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - MonoToggleStyle

/// A strictly black & white switch. AppKit's `.switch` toggle ignores SwiftUI `.tint`
/// on macOS and renders the system accent — this draws the knob/track from Mono tokens.
struct MonoToggleStyle: ToggleStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            Capsule()
                .fill(configuration.isOn ? Mono.ink() : Mono.ink(0.18))
                .frame(width: 38, height: 22)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle()
                        .fill(Mono.paper())
                        .frame(width: 18, height: 18)
                        .padding(2)
                        .shadow(color: Mono.ink(0.20), radius: 1, y: 0.5)
                }
                .animation(reduceMotion ? nil : Motion.snap, value: configuration.isOn)
        }
        .buttonStyle(MonoPlainButtonStyle(scales: false))
        .accessibilityAddTraits(configuration.isOn ? [.isButton, .isSelected] : .isButton)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}

// MARK: - MonoSlider

/// A SwiftUI-only monochrome slider. AppKit's `NSSlider` ignores `.tint` on macOS, so we
/// draw the track, fill, and knob ourselves and drive the value with a drag gesture.
struct MonoSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double = 0

    private let trackHeight: CGFloat = 4
    private let knob: CGFloat = 16

    var body: some View {
        GeometryReader { geo in
            let span = max(range.upperBound - range.lowerBound, 0.0001)
            let frac = min(max((value - range.lowerBound) / span, 0), 1)
            let travel = max(geo.size.width - knob, 1)
            let x = CGFloat(frac) * travel

            ZStack(alignment: .leading) {
                Capsule().fill(Mono.ink(0.15)).frame(height: trackHeight)
                Capsule().fill(Mono.ink()).frame(width: x + knob / 2, height: trackHeight)
                Circle()
                    .fill(Mono.paper())
                    .frame(width: knob, height: knob)
                    .overlay(Circle().strokeBorder(Mono.ink(0.25), lineWidth: 1))
                    .shadow(color: Mono.ink(0.20), radius: 1, y: 0.5)
                    .offset(x: x)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let p = min(max(0, g.location.x - knob / 2), travel)
                        let candidate = range.lowerBound + Double(p / travel) * span
                        value = snappedAndClamped(candidate)
                    }
            )
            .accessibilityElement()
            .accessibilityValue(String(format: "%.0f", value))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    value = snappedAndClamped(value + accessibilityStep)
                case .decrement:
                    value = snappedAndClamped(value - accessibilityStep)
                @unknown default:
                    break
                }
            }
        }
        .frame(height: knob)
    }

    /// A drag and an accessibility increment must land on the same values. Quantising
    /// relative to the lower bound also keeps non-zero-based ranges aligned correctly.
    private func snappedAndClamped(_ candidate: Double) -> Double {
        var result = min(max(range.lowerBound, candidate), range.upperBound)
        if step > 0 {
            let steps = ((result - range.lowerBound) / step).rounded()
            result = range.lowerBound + steps * step
        }
        return min(max(range.lowerBound, result), range.upperBound)
    }

    private var accessibilityStep: Double {
        if step > 0 { return step }
        return max((range.upperBound - range.lowerBound) / 20, 0.01)
    }
}

// MARK: - ShortcutChip

/// Keycap-style rendering of a keyboard shortcut: one small cap per key, so
/// `⌥⌘Space` reads as three discrete keys instead of one cramped glyph run.
///
/// Two tones, because the same chip appears on the dark primary button and on
/// light rows. Both are pure Mono tokens — no tint, ever.
///
/// ```swift
/// ShortcutChip(shortcut, tone: .onDark)
/// ShortcutChip(keys: ["⏎"], tone: .onLight)
/// ```
struct ShortcutChip: View {
    enum Tone {
        case onLight    // rows, popover surfaces
        case onDark     // inside a Mono.ink() filled button
    }

    var keys: [String]
    var tone: Tone = .onLight

    init(keys: [String], tone: Tone = .onLight) {
        self.keys = keys
        self.tone = tone
    }

    /// Splits a `Shortcut` into its modifier glyphs plus the key name, in the
    /// canonical macOS order (⌃⌥⇧⌘ then key).
    init(_ shortcut: Shortcut, tone: Tone = .onLight) {
        var parts: [String] = []
        let f = shortcut.modifierFlags
        if f.contains(.control) { parts.append("⌃") }
        if f.contains(.option) { parts.append("⌥") }
        if f.contains(.shift) { parts.append("⇧") }
        if f.contains(.command) { parts.append("⌘") }
        parts.append(Shortcut.keyName(for: shortcut.keyCode))
        self.keys = parts
        self.tone = tone
    }

    // Cap geometry — 17 pt caps sit optically level with 13 pt body text.
    private let capHeight: CGFloat = 17
    private let capRadius: CGFloat = 4.5

    private var foreground: Color {
        switch tone {
        case .onLight: Mono.ink(0.62)
        case .onDark:  Mono.paper(0.80)
        }
    }

    private var fill: Color {
        switch tone {
        case .onLight: Mono.ink(0.06)
        case .onDark:  Mono.paper(0.16)
        }
    }

    private var stroke: Color {
        switch tone {
        case .onLight: Mono.ink(0.12)
        case .onDark:  Mono.paper(0.22)
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Text(key)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(foreground)
                    // Glyph keys (⌥⌘) are square; word keys (Space) need breathing room.
                    .padding(.horizontal, key.count > 1 ? 6 : 0)
                    .frame(minWidth: capHeight, minHeight: capHeight)
                    .background(
                        RoundedRectangle(cornerRadius: capRadius, style: .continuous)
                            .fill(fill)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: capRadius, style: .continuous)
                            .strokeBorder(stroke, lineWidth: 0.5)
                    )
            }
        }
        .fixedSize()
        .accessibilityElement()
        .accessibilityLabel(keys.joined(separator: " "))
    }
}

// MARK: - MonoProgressBar

/// Monochrome progress bar. `value` 0...1, or `nil` for an indeterminate pulse.
/// AppKit's `NSProgressIndicator` ignores `.tint`; this is pure SwiftUI.
struct MonoProgressBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var value: Double?
    var height: CGFloat = 4
    @State private var pulse = false

    var body: some View {
        Capsule()
            .fill(Mono.ink(0.12))
            .frame(height: height)
            .overlay(alignment: .leading) {
                if let value {
                    Capsule()
                        .fill(Mono.ink(0.70))
                        .frame(maxWidth: .infinity)
                        .frame(height: height)
                        .scaleEffect(x: CGFloat(min(max(value, 0), 1)), anchor: .leading)
                        .animation(reduceMotion ? nil : Motion.snap, value: value)
                } else if reduceMotion {
                    Capsule()
                        .fill(Mono.ink(0.70))
                        .frame(maxWidth: .infinity)
                        .frame(height: height)
                        .scaleEffect(x: 0.35, anchor: .leading)
                        .opacity(0.7)
                } else {
                    Capsule()
                        .fill(Mono.ink(0.70))
                        .frame(maxWidth: .infinity)
                        .frame(height: height)
                        .scaleEffect(x: 0.35, anchor: .leading)
                        .opacity(pulse ? 0.4 : 1)
                        .onAppear {
                            pulse = false
                            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                                pulse = true
                            }
                        }
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Progress")
            .accessibilityValue(
                value.map { "\(Int((min(max($0, 0), 1) * 100).rounded())) percent" }
                    ?? "In progress"
            )
    }
}

// MARK: - Previews

#if DEBUG
/// Preview words as keys that are not literals, so they stay out of Localizable.xcstrings.
private func demo(_ text: String) -> LocalizedStringKey { LocalizedStringKey(text) }

#Preview("MonoCard") {
    VStack(spacing: 16) {
        MonoCard(title: demo("Model")) {
            SettingRow(label: demo("Speed"),
                       sublabel: demo("Tokens per second")) {
                DotMeter(filled: 4)
            }
            SettingRow(label: demo("Accuracy")) {
                DotMeter(filled: 5)
            }
        }

        MonoCard {
            SettingRow(label: demo("No title card")) {
                Text(verbatim: "Value")
                    .font(Typo.secondary)
                    .foregroundStyle(Mono.secondaryText)
            }
        }
    }
    .padding(24)
    .background(Mono.windowBackground)
    .frame(width: 400)
}

#Preview("DotMeter") {
    VStack(alignment: .leading, spacing: 8) {
        ForEach(0...5, id: \.self) { n in
            HStack {
                Text(verbatim: "\(n)/5")
                    .font(Typo.mono)
                    .foregroundStyle(Mono.secondaryText)
                    .frame(width: 32, alignment: .leading)
                    .monospacedDigit()
                DotMeter(filled: n)
            }
        }
    }
    .padding(24)
    .background(Mono.windowBackground)
}

#Preview("SettingRow") {
    MonoCard {
        VStack(spacing: 0) {
            SettingRow(label: demo("Launch at login")) {
                Toggle("", isOn: .constant(true))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            Divider().opacity(0.3)
            SettingRow(label: demo("Injection method"),
                       sublabel: demo("How text is delivered")) {
                Text(verbatim: "Paste (⌘V)")
                    .font(Typo.secondary)
                    .foregroundStyle(Mono.secondaryText)
            }
        }
    }
    .padding(24)
    .background(Mono.windowBackground)
    .frame(width: 400)
}
#endif
