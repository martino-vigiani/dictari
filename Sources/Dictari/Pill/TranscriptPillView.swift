import AppKit
import SwiftUI

/// Clipboard fallback only. Value inputs keep this view previewable without starting dictation.
struct TranscriptPillView: View {
    let transcript: String
    /// Unsure words, dotted-underlined. nil (the default) renders the plain transcript.
    var uncertainSpans: [UncertainSpan]? = nil
    let isExpanded: Bool
    let onImprove: () -> Void
    let onCopy: () -> Void
    let onToggleExpansion: () -> Void
    let onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var copyConfirmed = false
    @State private var copyFeedbackTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                if isExpanded {
                    Spacer(minLength: 0)

                    Button(action: onToggleExpansion) {
                        Image(systemName: "chevron.up")
                    }
                    .buttonStyle(TranscriptActionButtonStyle())
                    .accessibilityLabel("Collapse transcript")
                    .accessibilityHint("Hides the full transcript")
                    .help("Collapse transcript")
                } else if TranscriptPillPolicy.canExpand(transcript) {
                    Button(action: onToggleExpansion) {
                        collapsedPreview(showsExpansionHint: true)
                    }
                    .buttonStyle(TranscriptPreviewButtonStyle())
                    .accessibilityLabel("Expand copied transcript")
                    .accessibilityHint("Shows the full transcript")
                    .help("Expand transcript")
                } else {
                    collapsedPreview(showsExpansionHint: false)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Transcript copied to clipboard")
                }

                Button(action: onImprove) { Image(systemName: "text.badge.checkmark") }
                    .buttonStyle(TranscriptActionButtonStyle())
                    .accessibilityLabel("Improve transcript")
                    .help("Correct or rewrite with Apple Intelligence")
                    .disabled(transcript.isEmpty)

                Button(action: copyTranscript) {
                    Image(systemName: copyConfirmed ? "checkmark" : "doc.on.doc")
                        .contentTransition(.opacity)
                }
                .buttonStyle(TranscriptActionButtonStyle())
                .accessibilityLabel(copyConfirmed ? "Copied" : "Copy transcript")
                .accessibilityHint("Copies the full transcript to the clipboard")
                .help(copyConfirmed ? "Copied" : "Copy transcript")
                .disabled(transcript.isEmpty)

                // The copy is already on the clipboard; closing only retires the reminder.
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(TranscriptActionButtonStyle())
                    .accessibilityLabel("Close")
                    .accessibilityHint("Dismisses the copied transcript. It stays on the clipboard.")
                    .help("Close (Esc)")
            }
            .padding(.horizontal, 12)
            .frame(height: PillGeometry.collapsedTranscriptHeight)

            if isExpanded {
                Rectangle()
                    .fill(Mono.pillOn(0.12))
                    .frame(height: 1)
                    .padding(.horizontal, 16)
                    .accessibilityHidden(true)

                ScrollView(.vertical) {
                    Text(displayedTranscript)
                        .font(Typo.body)
                        .foregroundStyle(Mono.pillOn(0.92))
                        .lineSpacing(4)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                }
                .scrollIndicators(.visible)
                .frame(maxHeight: .infinity)
                .overlay(alignment: .bottom) {
                    LinearGradient(
                        colors: [Mono.pillFill.opacity(0), Mono.pillFill],
                        startPoint: .top, endPoint: .bottom
                    )
                    .frame(height: 16)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
                .padding(.bottom, 12)
                .transition(.opacity)
            }
        }
        .frame(
            width: isExpanded ? PillGeometry.expandedTranscriptWidth : PillGeometry.transcriptWidth,
            height: isExpanded
                ? PillGeometry.expandedTranscriptHeight : PillGeometry.collapsedTranscriptHeight,
            alignment: .top
        )
        .onChange(of: transcript) { resetCopyFeedback() }
        .onDisappear(perform: resetCopyFeedback)
    }

    /// The pill is always dark, so the underline uses the pill's own on-color, dimmed to stay
    /// a hint beside the text rather than compete with it.
    private var displayedTranscript: AttributedString {
        UncertainSpanRendering.attributed(text: transcript, spans: uncertainSpans,
                                          underline: Mono.pillOn(0.55))
    }

    private func collapsedPreview(showsExpansionHint: Bool) -> some View {
        HStack(spacing: 7) {
            Text(displayedTranscript)
                .font(Typo.pillControl)
                .foregroundStyle(Mono.pillOn(0.95))
                .lineLimit(2)
                .truncationMode(.tail)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            if showsExpansionHint {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Mono.pillOn(0.58))
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Mono.pillOn(0.08)))
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
        .contentShape(.rect(cornerRadius: 9))
    }

    private func copyTranscript() {
        onCopy()
        copyFeedbackTask?.cancel()
        withAnimation(.easeOut(duration: 0.1)) { copyConfirmed = true }
        copyFeedbackTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(TranscriptPillPolicy.copyConfirmationSeconds))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.1)) { copyConfirmed = false }
        }
    }

    private func resetCopyFeedback() {
        copyFeedbackTask?.cancel()
        copyFeedbackTask = nil
        copyConfirmed = false
    }
}

/// The preview itself is the expansion control. It stays visually quiet at rest, then responds
/// as one continuous object instead of looking like a status label beside an unrelated chevron.
private struct TranscriptPreviewButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 7)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Mono.pillOn(configuration.isPressed ? 0.12 : (isHovered ? 0.07 : 0)))
            )
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(
                Motion.reduced(configuration.isPressed ? Motion.press : Motion.hover,
                               reduceMotion: reduceMotion),
                value: configuration.isPressed
            )
            .animation(Motion.reduced(Motion.hover, reduceMotion: reduceMotion), value: isHovered)
            .onHover { isHovered = $0 }
            .modifier(PointingHandCursorModifier())
    }
}

/// Both transcript actions share the same glyph weight, hit target, fill and feedback.
private struct TranscriptActionButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Mono.pillOn(isEnabled ? 0.82 : 0.35))
            .frame(width: 28, height: 28)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Mono.pillOn(configuration.isPressed ? 0.22 : (isHovered ? 0.15 : 0.08)))
            )
            .contentShape(.rect(cornerRadius: 8))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.1), value: isHovered)
            .onHover { isHovered = $0 }
            .modifier(PointingHandCursorModifier())
    }
}

/// SwiftUI's plain macOS buttons keep the arrow cursor. These compact pill actions are explicit
/// click targets, so balance AppKit's cursor stack and expose the conventional pointing hand.
private struct PointingHandCursorModifier: ViewModifier {
    @State private var cursorIsPushed = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                if hovering, !cursorIsPushed {
                    NSCursor.pointingHand.push()
                    cursorIsPushed = true
                } else if !hovering, cursorIsPushed {
                    NSCursor.pop()
                    cursorIsPushed = false
                }
            }
            .onDisappear {
                if cursorIsPushed {
                    NSCursor.pop()
                    cursorIsPushed = false
                }
            }
    }
}
