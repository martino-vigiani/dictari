import SwiftUI

/// Keeps focus in the destination app; preview actions never replace its text.
struct WritingPillView: View {
    @Environment(AppCoordinator.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showOriginal = false
    @State private var copied = false
    @State private var lastPresentation: Presentation?

    private struct Presentation: Equatable {
        var expanded: Bool
        var busy: Bool
        var original: String
        var text: String
        var hasResult: Bool
        var actionLabel: String
    }

    private var currentPresentation: Presentation {
        let writing = app.pillRefinement
        return Presentation(expanded: app.pillWritingExpanded, busy: writing.isBusy,
                            original: app.lastTranscript,
                            text: writing.error ?? writing.unavailableReason ?? writing.result ?? app.lastTranscript,
                            hasResult: writing.result != nil, actionLabel: app.pillWritingAction.label)
    }

    var body: some View {
        // Environment updates also reach a departing transition. Freeze its last visible
        // values so clearing the model cannot collapse or erase the outgoing preview.
        let live = currentPresentation
        let display = app.pillWritingVisible && app.pillVisible ? live : (lastPresentation ?? live)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "pencil.line").font(.system(size: 17, weight: .medium))
                    .frame(width: 34, height: 34)
                    .background(Mono.pillOn(0.10), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text(display.expanded ? "Edit text" : "Improve this text?")
                        .font(.system(size: 12, weight: .semibold))
                    Text(display.expanded
                         ? String(localized: "On your Mac", comment: "Writing card subtitle: the revision runs locally")
                         : display.actionLabel)
                        .font(.system(size: 10)).foregroundStyle(Mono.pillOn(0.55))
                }
                Spacer(minLength: 0)
                HStack(spacing: 2) {
                    if !display.expanded {
                        iconButton("Improve text", icon: "arrow.up.right", prominent: true) { app.beginPillRevision(app.pillWritingAction) }
                    } else if !display.busy {
                        iconButton(showOriginal ? "Show revision" : "Show original", icon: showOriginal ? "pencil.line" : "arrow.uturn.backward") { showOriginal.toggle() }
                            .disabled(!display.hasResult)
                        iconButton(copied ? "Copied" : "Copy revision", icon: copied ? "checkmark" : "doc.on.doc", prominent: true) { app.copyPillRevision(); copied = true }
                            .disabled(!display.hasResult)
                    }
                    Rectangle()
                        .fill(Mono.pillOn(0.12))
                        .frame(width: 1, height: 16)
                        .padding(.horizontal, 2)
                        .accessibilityHidden(true)
                    iconButton("Close", icon: "xmark") { app.dismissPillWriting() }
                }
                .padding(3)
                .background(Mono.pillOn(0.07), in: Capsule(style: .continuous))
            }
            if display.expanded {
                Group {
                    if display.busy {
                        HStack(spacing: 10) {
                            PillProcessingIndicator(isRevising: true, isActive: app.pillVisible)
                                .frame(width: 38, height: 16)
                            Text("Revising").font(Typo.pillControl)
                                .foregroundStyle(Mono.pillOn(0.65))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.opacity)
                    } else {
                        ScrollView {
                            Text(showOriginal ? display.original : display.text)
                                .font(.system(size: 12)).lineSpacing(3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentTransition(.opacity)
                                .animation(Motion.reduced(Motion.snap, reduceMotion: reduceMotion), value: showOriginal)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                            .transition(.opacity)
                    }
                }
                .animation(Motion.reduced(Motion.snap, reduceMotion: reduceMotion), value: display.busy)
                if display.busy {
                    HStack(spacing: 6) {
                        Button("Cancel") { app.pillRefinement.cancel() }
                            .buttonStyle(WritingPillTextButtonStyle())
                        Spacer(minLength: 0)
                    }
                } else {
                    HStack(spacing: 2) {
                        ForEach(WritingAction.allCases) { action in
                            Button(action.compactLabel) {
                                showOriginal = false
                                copied = false
                                app.beginPillRevision(action)
                            }
                            .buttonStyle(WritingPillActionStyle(isCurrent: action == app.pillWritingAction))
                            .accessibilityLabel(action.label)
                            .accessibilityValue(action == app.pillWritingAction ? "Current action" : "")
                            .accessibilityAddTraits(action == app.pillWritingAction ? .isSelected : [])
                            .help(action.explanation)
                        }
                    }
                    .padding(3)
                    .background(Mono.pillOn(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
        .foregroundStyle(Mono.pillOn(0.95))
        .padding(12)
        .frame(width: PillGeometry.expandedTranscriptWidth,
               height: display.expanded ? PillGeometry.expandedTranscriptHeight : PillGeometry.writingPromptHeight)
        .onAppear { lastPresentation = live }
        .onChange(of: live) { _, value in
            if app.pillWritingVisible && app.pillVisible { lastPresentation = value }
        }
        .help(String(localized: "\(app.pillWritingStatus). Preview only; pasted text stays unchanged.",
                     comment: "Writing card tooltip; the argument is the card status"))
    }
    private func iconButton(_ label: LocalizedStringKey, icon: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                .contentTransition(.opacity)
                .foregroundStyle(prominent ? Mono.pillFill : Mono.pillOn(0.65))
                .frame(width: 28, height: 28)
                .background(prominent ? Mono.pillOn(0.95) : Color.clear, in: Circle())
                .contentShape(Rectangle())
        }.buttonStyle(WritingPillIconStyle()).accessibilityLabel(label).help(label)
    }
}

private struct WritingPillTextButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Mono.pillOn(0.90))
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(
                Mono.pillOn(configuration.isPressed ? 0.16 : 0.08),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(
                Motion.reduced(configuration.isPressed ? Motion.press : Motion.snap, reduceMotion: reduceMotion),
                value: configuration.isPressed
            )
    }
}

private struct WritingPillActionStyle: ButtonStyle {
    let isCurrent: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: isCurrent ? .semibold : .medium))
            .foregroundStyle(Mono.pillOn(enabled ? (isCurrent ? 0.98 : 0.72) : 0.35))
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .background(
                Mono.pillOn(isCurrent ? 0.16 : (configuration.isPressed ? 0.12 : 0)),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(
                Motion.reduced(configuration.isPressed ? Motion.press : Motion.snap, reduceMotion: reduceMotion),
                value: configuration.isPressed
            )
            .animation(Motion.reduced(Motion.hover, reduceMotion: reduceMotion), value: isCurrent)
    }
}

private struct WritingPillIconStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(enabled ? (configuration.isPressed ? 0.65 : 1) : 0.35)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.95 : 1)
            .animation(Motion.reduced(Motion.snap, reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}
