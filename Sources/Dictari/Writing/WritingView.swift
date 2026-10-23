import AppKit
import SwiftUI

struct WritingView: View {
    @Environment(AppCoordinator.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var text: String
    @State private var action: WritingAction = .correct
    @State private var editorExpanded = false
    @State private var choosingPassage = false
    @State private var actionGuideExpanded = false
    private let editorOnly: Bool

    init(text: String = "") { _text = State(initialValue: text); editorOnly = !text.isEmpty }

    private var isLongText: Bool { text.count > 3000 || text.utf8.count > 12000 }

    var body: some View {
        let writing = app.textRefinement
        let displayedText = writing.result ?? writing.partialResult
        SettingsScrollPane(
            title: editorOnly ? String(localized: "Writing", comment: "Title of the Writing editor sheet") : SettingsSection.writing.label,
            subtitle: editorOnly ? nil : "Fix mistakes and revise text with Apple Intelligence, on this Mac."
        ) {
            availabilityLine(writing)
            if !editorOnly {
                SettingsCard(title: "Dictate & fix",
                             footer: "Fixes only mistakes. If it fails, the original stays in History.") {
                    SettingsRow("Dictate and Fix Mistakes", sublabel: "Fixes spelling, grammar and punctuation before inserting.") {
                        KeyRecorderView(shortcut: .constant(.revisionDictation), allowsRecording: false)
                    }
                    .settingsSearchAnchor("writing.fixMistakes")
                }
                WritingRulesView()
                    .settingsSearchAnchor("writing.appRules")
                SettingsAdvancedDisclosure(title: "Edit existing text", isExpanded: $editorExpanded) {
                    editorCard(writing)
                }
                .settingsSearchAnchor("writing.editor")
            } else {
                editorCard(writing)
            }
            if let displayedText {
                SettingsCard(title: writing.isBusy ? "Working draft" : "Edited text") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(displayedText).font(Typo.body).foregroundStyle(Mono.primaryText).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let result = writing.result {
                            HStack {
                                Spacer()
                                MonoCopyButton(size: .small) {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(result, forType: .string)
                                }
                            }
                            .transition(.opacity)
                        }
                    }.padding(Metrics.cardPadding)
                }
                .transition(.monoReveal(reduceMotion: reduceMotion))
            }
        }
        // Presence changes only — a result arriving, work starting or failing — never each
        // streamed token of the draft.
        .monoAnimation(Motion.reveal, value: displayedText == nil)
        .monoAnimation(Motion.reveal, value: writing.result == nil)
        .monoAnimation(Motion.reveal, value: writing.isBusy)
        .monoAnimation(Motion.reveal, value: writing.error)
        .monoAnimation(Motion.reveal, value: isLongText)
        .sheet(isPresented: $choosingPassage) { WritingSheet(text: text) }
        .onSettingsSearchReveal(["writing.editor"]) { _ in editorExpanded = true }
        .onAppear { app.textRefinement.clear(); app.textRefinement.refreshAvailability() }
        .onDisappear { app.textRefinement.clear() }
        .onChange(of: scenePhase) { if scenePhase == .active { writing.refreshAvailability() } }
        .onChange(of: text) { writing.clear() }
        .onChange(of: action) { writing.clear() }
    }

    /// Whether Apple Intelligence can run right now, with a way to re-check after the
    /// user changes it in System Settings.
    private func availabilityLine(_ writing: TextRefinement) -> some View {
        HStack(spacing: 8) {
            Image(systemName: writing.unavailableReason == nil ? "pencil.line" : "exclamationmark.circle")
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(Mono.secondaryText)
                .contentTransition(.symbolEffect(.replace))
                .accessibilityHidden(true)
            Text(writing.unavailableReason
                 ?? String(localized: "Apple Intelligence · On device", comment: "Writing: availability line when ready"))
                .font(Typo.secondary)
                .foregroundStyle(writing.unavailableReason == nil ? Mono.secondaryText : Mono.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
            Spacer()
            Button { writing.refreshAvailability() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(MonoGlyphButtonStyle())
                .help("Refresh availability")
                .accessibilityLabel("Refresh availability")
        }
        .padding(.horizontal, 4)
        .monoAnimation(Motion.swap, value: writing.unavailableReason)
    }

    private func editorCard(_ writing: TextRefinement) -> some View {
        SettingsCard(title: "Original") {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .trailing, spacing: 6) {
                    TextEditor(text: $text)
                        .font(Typo.body).foregroundStyle(Mono.primaryText)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .frame(minHeight: 130, maxHeight: 200)
                        .background(
                            RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous)
                                .fill(Mono.fieldFill)
                        )
                        .disabled(writing.isBusy)
                        .accessibilityLabel("Original text")
                    Text("\(text.count) / 3,000 characters")
                        .font(Typo.secondary)
                        .foregroundStyle(isLongText ? Mono.primaryText : Mono.tertiaryText)
                        .monospacedDigit()
                }
                if isLongText {
                    VStack(alignment: .leading, spacing: 8) {
                        SettingsNotice("Long text is revised in passages. The original stays unchanged.",
                                       systemImage: "text.alignleft")
                        Button("Choose a Passage…") { choosingPassage = true }
                            .buttonStyle(MonoActionButtonStyle(.secondary, size: .small))
                            .disabled(writing.isBusy)
                    }
                    .transition(.monoReveal(reduceMotion: reduceMotion))
                }
                MonoSegmented(selection: $action,
                              options: WritingAction.allCases.map { (value: $0, label: $0.compactLabel) })
                    .disabled(writing.isBusy)
                    .accessibilityLabel("Writing action")
                WritingActionGuide(action: action, expanded: $actionGuideExpanded)
                HStack(spacing: 8) {
                    if writing.isBusy {
                        HStack(spacing: 8) {
                            MonoProgressBar(value: nil).frame(width: 48)
                            Text("\(action.progressLabel) on this Mac…")
                                .font(Typo.secondary)
                                .foregroundStyle(Mono.secondaryText)
                            Button("Cancel") { writing.cancel() }
                                .buttonStyle(MonoActionButtonStyle(.secondary, size: .small))
                        }
                        .transition(.opacity)
                    }
                    Spacer()
                    Button("Apply") { app.improveText(text, action: action) }
                        .buttonStyle(MonoActionButtonStyle(.primary))
                        .disabled(writing.isBusy || writing.unavailableReason != nil || (try? TextRefinement.validate(text)) == nil || app.state.isActive || app.mediaLibrary.isBusy)
                        .accessibilityLabel(action.applyAccessibilityLabel)
                }
                if let error = writing.error {
                    SettingsNotice(error, systemImage: "exclamationmark.triangle")
                        .transition(.monoReveal(reduceMotion: reduceMotion))
                }
            }.padding(Metrics.cardPadding)
        }
    }
}

private struct WritingActionGuide: View {
    let action: WritingAction
    @Binding var expanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !expanded {
                Text("\(action.explanation) Language and tone stay with the original.")
                    .font(Typo.secondary)
                    .foregroundStyle(Mono.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
                    .transition(.opacity)
            }

            Button {
                withAnimation(Motion.reduced(Motion.reveal, reduceMotion: reduceMotion)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text("What each option does")
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(MonoPlainButtonStyle(scales: false))
            .font(Typo.secondary)
            .foregroundStyle(hovered || expanded ? Mono.primaryText : Mono.secondaryText)
            .onHover { hovered = $0 }
            .monoAnimation(Motion.hover, value: hovered)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")

            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(WritingAction.allCases) { option in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(option.label)
                                .font(Typo.secondary.weight(option == action ? .semibold : .medium))
                                .foregroundStyle(Mono.primaryText)
                                .frame(width: 108, alignment: .leading)
                            Text(option.explanation)
                                .font(Typo.secondary)
                                .foregroundStyle(option == action ? Mono.primaryText : Mono.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.top, 2)
                .transition(.monoReveal(reduceMotion: reduceMotion))
            }
        }
        .monoAnimation(Motion.swap, value: action)
    }
}

struct WritingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppCoordinator.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let passages: [String]
    @State private var index = 0

    init(text: String) {
        passages = text.count <= 3000 && text.utf8.count <= 12000 ? [text] : WritingPassages.split(text)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if passages.count > 1 {
                    Button { step(-1) } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(MonoGlyphButtonStyle())
                        .disabled(index == 0 || app.textRefinement.isBusy)
                        .accessibilityLabel("Previous passage").help("Previous passage")
                    Text("Passage \(index + 1) of \(passages.count)")
                        .font(Typo.secondary.weight(.medium))
                        .foregroundStyle(Mono.secondaryText)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Button { step(1) } label: { Image(systemName: "chevron.right") }
                        .buttonStyle(MonoGlyphButtonStyle())
                        .disabled(index == passages.count - 1 || app.textRefinement.isBusy)
                        .accessibilityLabel("Next passage").help("Next passage")
                }
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(MonoActionButtonStyle(.primary))
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, Metrics.pageGutter - 8)
            .padding(.top, 14)
            .padding(.bottom, passages.count > 1 ? 6 : 0)
            if passages.count > 1 {
                SettingsFootnote("Review and copy one passage at a time. The full original is unchanged.")
                    .padding(.horizontal, Metrics.pageGutter - 4)
            }
            WritingView(text: passages[index]).id(index)
                .transition(.opacity)
        }
        .frame(width: 660, height: 680)
        .background(Mono.windowBackground)
    }

    private func step(_ delta: Int) {
        withAnimation(Motion.reduced(Motion.swap, reduceMotion: reduceMotion)) { index += delta }
    }
}
