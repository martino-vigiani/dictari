// PillView.swift
// Dictari — the floating dictation pill.
//
// ONE theme: a small DARK capsule with white content, in every state. It stays small
// even while speaking — showing only the waveform lines. The only state that grows is
// the "show transcript" box (used when there's no focused field to paste into).

import AppKit
import SwiftUI

struct PillView: View {

    @Environment(AppCoordinator.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The orb replaces the idle/listening capsule; result and error states keep their text.
    private var isOrb: Bool { app.settings.data.pillStyle == .orb }
    private var isExpandedStyle: Bool { app.settings.data.pillStyle == .expanded }

    var body: some View {
        // The shell keeps its identity across every state. Only the artwork crossfades;
        // replacing a capsule with a separate card cannot interpolate their geometry.
        PillMorphingSurface(width: renderedSize.width, height: renderedSize.height, radius: min(renderedSize.height / 2, 22)) {
            ZStack(alignment: .top) {
                content
                    .id(presentationID)
                    .transition(.opacity)
            }
            .animation(Motion.reduced(Motion.snap, reduceMotion: reduceMotion), value: presentationID)
        }
            .animation(reduceMotion ? nil : (app.pillVisible ? Motion.morph : Motion.pillDismiss), value: renderedSize)
            .scaleEffect(reduceMotion || app.pillVisible ? 1 : 0.86, anchor: shellAnchor)
            .opacity(app.pillVisible ? 1 : 0)
            .animation(
                Motion.reduced(app.pillVisible ? Motion.appear : Motion.pillDismiss,
                               reduceMotion: reduceMotion),
                value: app.pillVisible
            )
            .allowsHitTesting(app.pillVisible)
            .padding(.horizontal, PillGeometry.horizontalInset)
            .padding(.vertical, PillGeometry.verticalInset)
            // A spring can briefly exceed the destination width. Keep the transparent host
            // fixed so that overshoot cannot resize the window and move its anchor.
            .frame(width: PillGeometry.panelSize.width, height: PillGeometry.panelSize.height,
                   alignment: contentAlignment)
            .coordinateSpace(name: "pillHost")
    }

    @ViewBuilder private var content: some View {
        switch app.state {
        case .idle, .cancelled:
            if app.pillExpanded { expandedMenu }
            else if isOrb { orbPill }
            else { idlePill }
        case .listening:
            if app.conversationPillLayout != .none { conversationCard }
            else { listeningPill }
        case .transcribing:
            dotsPill
        case .success(let kind):
            if app.pillWritingVisible { WritingPillView() }
            else { successPill(kind) }
        case .error(let message):
            errorPill(message)
        }
    }

    private var shellSize: CGSize {
        if app.pillWritingVisible {
            return CGSize(width: PillGeometry.expandedTranscriptWidth,
                          height: app.pillWritingExpanded ? PillGeometry.expandedTranscriptHeight : PillGeometry.writingPromptHeight)
        }
        return CGSize(
            width: PillGeometry.visibleWidth(state: app.state, style: app.settings.data.pillStyle,
                                             isExpanded: app.pillExpanded, transcriptExpanded: app.transcriptExpanded,
                                             conversation: app.conversationPillLayout),
            height: PillGeometry.visibleHeight(state: app.state, style: app.settings.data.pillStyle,
                                               idleMenuExpanded: app.pillExpanded, transcriptExpanded: app.transcriptExpanded,
                                               conversation: app.conversationPillLayout)
        )
    }

    // A hidden presentation rests at the small capsule, so first appearance grows from its
    // anchor and dismissal contracts there before the window disappears.
    private var renderedSize: CGSize {
        app.pillVisible ? shellSize : CGSize(width: PillGeometry.idleWidth, height: 26)
    }

    private var shellAnchor: UnitPoint {
        switch app.settings.data.pillPosition {
        case .topCenter: return .top
        case .bottomLeading: return .bottomLeading
        case .bottomTrailing: return .bottomTrailing
        case .bottomCenter, .cursor: return .bottom
        }
    }

    private var presentationID: String {
        switch app.state {
        case .idle, .cancelled: return app.pillExpanded ? "menu" : "idle"
        case .listening: return app.conversationPillLayout == .none ? "listening" : "conversation"
        case .transcribing: return "processing"
        case .success(let kind):
            if app.pillWritingVisible { return "writing" }
            switch kind {
            case .inserted: return "inserted"
            case .pastedUnverified: return "pasted"
            case .submitFailed: return "submitFailed"
            case .copiedToClipboard: return "transcript"
            }
        case .error: return "error"
        }
    }

    // Must match PillGeometry.visibleRect, including the bottom anchor used near the cursor.
    private var contentAlignment: Alignment {
        switch app.settings.data.pillPosition {
        case .topCenter: return .top
        case .bottomLeading: return .bottomLeading
        case .bottomTrailing: return .bottomTrailing
        case .bottomCenter, .cursor: return .bottom
        }
    }

    // MARK: - States (all dark capsule, white content)

    private var idlePill: some View {
        Button { app.togglePillMenu() } label: {
        HStack(spacing: 5) {
            ForEach(0..<5, id: \.self) { _ in
                Circle().fill(Mono.pillOn(0.45)).frame(width: 3.5, height: 3.5)
            }
        }
        .frame(width: PillGeometry.idleWidth, height: 26)
        .contentShape(Capsule())
        }
        .buttonStyle(PillMenuButtonStyle())
        .accessibilityLabel("Show Dictari controls")
    }

    // MARK: - Expanded menu

    private var expandedMenu: some View {
        HStack(spacing: 4) {
            menuButton(icon: "mic.fill", label: "Record") { app.startDictation() }
            Rectangle().fill(Mono.pillOn(0.18)).frame(width: 1, height: 18)
            menuButton(icon: "xmark", label: nil) { app.collapsePillMenu() }
                .accessibilityLabel("Close menu")
        }
        .padding(.horizontal, 6)
        .frame(width: PillGeometry.expandedMenuWidth, height: 36)
        .contentShape(Capsule())
    }

    private func menuButton(icon: String, label: LocalizedStringKey?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                if let label { Text(label).font(Typo.pillControl) }
            }
            .foregroundStyle(Mono.pillOn())
            .padding(.horizontal, 12)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(PillMenuButtonStyle())
    }

    /// The minimal presentation: one disc, live bars, nothing else. It is tappable in idle
    /// exactly like the capsule, so the Dynamic-Island menu is still reachable.
    @ViewBuilder private var orbPill: some View {
        if app.state.isActive {
            Button { app.stopDictation() } label: { orbArtwork }
                .buttonStyle(PillMenuButtonStyle())
                .accessibilityLabel("Stop Recording")
        } else {
            Button { app.togglePillMenu() } label: { orbArtwork }
                .buttonStyle(PillMenuButtonStyle())
                .accessibilityLabel("Show Dictari controls")
        }
    }

    private var orbArtwork: some View {
        OrbView(levels: app.levels, isActive: app.state == .listening)
            .frame(width: PillGeometry.orbWidth, height: PillGeometry.orbWidth)
            .contentShape(Circle())
            .accessibilityElement(children: .ignore)
    }

    private var listeningPill: some View {
        let showsStatusText = isExpandedStyle && app.settings.data.showTranscriptPreview
        let conversation = app.conversationActive
        return HStack(spacing: 6) {
            recordingActionButton(
                icon: "xmark",
                label: conversation ? "Cancel Turn" : "Cancel Dictation",
                hint: conversation ? "Discards what you are saying now and ends the conversation"
                    : "Discards this recording",
                prominent: false
            ) {
                app.cancelDictation()
            }

            HStack(spacing: 6) {
                if isExpandedStyle {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Mono.pillOn(0.72))
                        .accessibilityHidden(true)
                }

                // Recording feedback is driven by the microphone state, not model warm-up. The old
                // branch replaced this live waveform with three loading dots while capture was already
                // running, which made a healthy dictation look stuck.
                WaveformContainer()
                    .frame(width: showsStatusText ? 58 : 64, height: 22)
                    .accessibilityHidden(true)

                if showsStatusText {
                    Text(conversation ? "Conversation" : "Listening")
                        .font(Typo.pillControl)
                        .foregroundStyle(Mono.pillOn(0.72))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 108, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Recording")
            .accessibilityValue(conversation ? "Conversation, listening" : "Listening")

            recordingActionButton(
                icon: "checkmark",
                label: conversation ? "End Conversation" : "Finish Dictation",
                hint: conversation ? "Delivers what you are saying and stops listening"
                    : "Stops recording and transcribes",
                prominent: true
            ) {
                app.stopDictation()
            }
        }
        .padding(.horizontal, 5)
        .frame(
            width: isExpandedStyle
                ? PillGeometry.expandedListeningWidth
                : PillGeometry.listeningWidth,
            height: PillGeometry.listeningHeight
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Dictation controls")
    }

    /// Conversation mode after a turn had nowhere to paste: the listening controls stay on top
    /// and the conversation's transcript grows underneath, pinned to its newest line, until the
    /// conversation ends. The card keeps listening, so it must not look like a finished result.
    private var conversationCard: some View {
        let isExpanded = app.conversationPillLayout == .expanded
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                recordingActionButton(
                    icon: "xmark",
                    label: "Cancel Turn",
                    hint: "Discards what you are saying now and ends the conversation",
                    prominent: false
                ) {
                    app.cancelDictation()
                }

                WaveformContainer()
                    .frame(width: 64, height: 22)
                    .accessibilityHidden(true)

                Text("Conversation")
                    .font(Typo.pillControl)
                    .foregroundStyle(Mono.pillOn(0.72))
                    .lineLimit(1)

                Spacer(minLength: 0)

                recordingActionButton(
                    icon: "doc.on.doc",
                    label: "Copy Conversation",
                    hint: "Copies everything that could not be pasted",
                    prominent: false
                ) {
                    app.copyConversationTranscript()
                }

                recordingActionButton(
                    icon: "checkmark",
                    label: "End Conversation",
                    hint: "Delivers what you are saying and stops listening",
                    prominent: true
                ) {
                    app.stopDictation()
                }
            }
            .padding(.horizontal, 5)
            .frame(height: PillGeometry.listeningHeight)

            Rectangle()
                .fill(Mono.pillOn(0.12))
                .frame(height: 1)
                .padding(.horizontal, 16)
                .accessibilityHidden(true)

            ScrollView(.vertical) {
                Text(app.conversationCopiedTranscript)
                    .font(isExpanded ? Typo.body : Typo.pillControl)
                    .foregroundStyle(Mono.pillOn(0.92))
                    .lineSpacing(isExpanded ? 4 : 2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, isExpanded ? 12 : 8)
                    .accessibilityLabel("Conversation transcript")
                    .accessibilityValue(app.conversationCopiedTranscript)
            }
            .scrollIndicators(isExpanded ? .visible : .hidden)
            // Newest turn in view: the card follows the conversation as it grows.
            .defaultScrollAnchor(.bottom)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .frame(maxHeight: .infinity)
            .padding(.bottom, isExpanded ? 10 : 4)
        }
        .frame(
            width: PillGeometry.expandedTranscriptWidth,
            height: isExpanded
                ? PillGeometry.expandedTranscriptHeight : PillGeometry.conversationCompactHeight,
            alignment: .top
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Conversation controls")
    }

    private func recordingActionButton(
        icon: String,
        label: LocalizedStringKey,
        hint: LocalizedStringKey,
        prominent: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Circle()
                .fill(prominent ? Mono.pillOn() : Mono.pillOn(0.14))
                .overlay {
                    Image(systemName: icon)
                        .font(.system(size: prominent ? 15 : 13, weight: .semibold))
                        .foregroundStyle(prominent ? Mono.pillFill : Mono.pillOn(0.92))
                        .accessibilityHidden(true)
                }
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .buttonStyle(PillRecordingButtonStyle())
        .accessibilityLabel(label)
        .accessibilityHint(hint)
        .help(label)
    }

    private var dotsPill: some View {
        HStack(spacing: 8) {
            PillProcessingIndicator(isRevising: app.isRevising, isActive: app.pillVisible)
                .frame(width: app.isRevising ? 38 : 24, height: 16)
            if isExpandedStyle {
                Text(app.isRevising ? "Revising" : "Transcribing")
                    .font(Typo.pillControl)
                    .foregroundStyle(Mono.pillOn(0.72))
            }
        }
            .frame(
                width: isExpandedStyle
                    ? PillGeometry.expandedTranscribingWidth
                    : PillGeometry.transcribingWidth,
                height: 28
            )
                .accessibilityElement(children: .ignore)
            .accessibilityLabel(app.isRevising ? "Revising text on your Mac" : "Transcribing")
    }

    private func successPill(_ kind: DictationState.SuccessKind) -> some View {
        Group {
            switch kind {
            case .inserted:
                // Pasted into the focused field — just a brief confirmation.
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Mono.pillOn())
                    .frame(width: PillGeometry.insertedWidth, height: 28)
            case .pastedUnverified:
                // ⌘V went into a real target, we just couldn't watch it land. Confirm like a
                // paste, with a clipboard glyph as the quiet hint that there's a copy to fall
                // back on — showing the whole transcript here read as "this failed".
                HStack(spacing: 5) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Mono.pillOn())
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Mono.pillOn(0.45))
                }
                .frame(width: PillGeometry.pastedUnverifiedWidth, height: 28)
            case .submitFailed:
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Check, then Return")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(Mono.pillOn())
                .frame(width: PillGeometry.submitFailedWidth, height: 28)
            case .copiedToClipboard:
                // Nowhere to paste (or auto-paste off): show the transcript in the box.
                TranscriptPillView(
                    transcript: app.lastTranscript,
                    uncertainSpans: app.lastTranscriptUncertainty?.spans(for: app.lastTranscript),
                    isExpanded: app.transcriptExpanded,
                    onImprove: app.openPillWriting,
                    onCopy: app.copyLastTranscriptFromPill,
                    onToggleExpansion: app.toggleTranscriptExpansion,
                    onClose: app.dismissCopiedPill
                )
            }
        }
    }

    private func errorPill(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "waveform.slash")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Mono.pillOn(0.7))
            Text(message)
                .font(Typo.pillControl)
                .foregroundStyle(Mono.pillOn(0.7))
                .lineLimit(1)
        }
        .padding(.horizontal, 13)
        .frame(maxWidth: PillGeometry.errorWidth)
        .frame(height: 28)
    }

}

// MARK: - Waveform leaf (isolates the ~50Hz levels read)

private struct WaveformContainer: View {
    @Environment(AppCoordinator.self) private var app
    var body: some View {
        WaveformView(levels: app.levels, isActive: true, tint: Mono.pillOn())
    }
}

// MARK: - Expanded-menu button style

private struct PillMenuButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Capsule().fill(Mono.pillOn(configuration.isPressed ? 0.22 : 0.0))
            )
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.95 : 1)
            .animation(Motion.reduced(Motion.snap, reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}

/// Recording actions already draw their own circular surfaces. This style adds tactile press
/// feedback without tinting the monochrome artwork or changing the non-activating panel behavior.
private struct PillRecordingButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.72 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.92 : 1)
            .animation(
                Motion.reduced(Motion.snap, reduceMotion: reduceMotion),
                value: configuration.isPressed
            )
    }
}

// A bounded drawing leaf keeps revision feedback out of the coordinator observation graph.
// Pausing explicitly matters when Settings temporarily hides a still-running revision.
struct PillProcessingIndicator: View {
    let isRevising: Bool
    let isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isActive || reduceMotion)) { timeline in
            Canvas { context, size in
                let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                if isRevising {
                    // Three text strokes pass a quiet highlight from left to right.
                    for row in 0..<3 {
                        let width = size.width * (row == 1 ? 0.72 : 0.94)
                        let y = size.height / 2 + CGFloat(row - 1) * 5 - 1
                        let rect = CGRect(x: (size.width - width) / 2, y: y, width: width, height: 2)
                        let path = Path(roundedRect: rect, cornerRadius: 1)
                        context.fill(path, with: .color(Mono.pillOn(0.28)))
                        let phase = (time / 1.5 + Double(row) * 0.14).truncatingRemainder(dividingBy: 1)
                        let center = reduceMotion ? 0.5 : CGFloat(phase) * 1.6 - 0.3
                        context.fill(path, with: .linearGradient(
                            Gradient(colors: [Mono.pillOn(0), Mono.pillOn(0.88), Mono.pillOn(0)]),
                            startPoint: CGPoint(x: (center - 0.35) * size.width, y: y),
                            endPoint: CGPoint(x: (center + 0.35) * size.width, y: y)
                        ))
                    }
                } else {
                    for index in 0..<3 {
                        let opacity = reduceMotion ? 0.72 : 0.38 + 0.5 * (0.5 + 0.5 * sin(time * 5 - Double(index) * 0.9))
                        let rect = CGRect(x: size.width / 2 + CGFloat(index - 1) * 8 - 2,
                                          y: size.height / 2 - 2, width: 4, height: 4)
                        context.fill(Path(ellipseIn: rect), with: .color(Mono.pillOn(opacity)))
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Interpolating layout dimensions explicitly makes the overlay and clipping boundary follow
/// the same intermediate surface, instead of laying out only at the destination rectangle.
private nonisolated struct PillMorphingSurface<Content: View>: View, Animatable {
    var width: CGFloat
    var height: CGFloat
    var radius: CGFloat
    @ViewBuilder var content: () -> Content

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
        get { AnimatablePair(AnimatablePair(width, height), radius) }
        set {
            width = newValue.first.first
            height = newValue.first.second
            radius = newValue.second
        }
    }

    @MainActor var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Mono.pillFill)
            .frame(width: max(1, width), height: max(1, height))
            .overlay(alignment: .top) { content() }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .background {
                #if DEBUG
                if ProcessInfo.processInfo.environment["DICTARI_WRITING_UI_PREVIEW"] == "motion" {
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { PillMotionProbe.record(frame: proxy.frame(in: .named("pillHost"))) }
                            .onChange(of: proxy.frame(in: .named("pillHost"))) { _, frame in
                                PillMotionProbe.record(frame: frame)
                            }
                    }
                }
                #endif
            }
    }
}
