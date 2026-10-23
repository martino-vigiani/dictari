import AppKit
import SwiftUI

enum VocabularyLearningMode: String, Identifiable, CaseIterable {
    case history, sentence
    var id: String { rawValue }
    var title: String {
        switch self {
        case .history: String(localized: "From history", comment: "Vocabulary learning source tab")
        case .sentence: String(localized: "From a sentence", comment: "Vocabulary learning source tab")
        }
    }
}

struct VocabularyLearningSheet: View {
    let term: VocabularyTerm
    let history: [HistoryEntry]
    let knownTerms: [VocabularyTerm]
    let onAdd: ([String]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var mode: VocabularyLearningMode
    @State private var suggestions: [VocabularySuggestion] = []
    @State private var selectedIDs: Set<String> = []
    @State private var loading = false
    @State private var loaded = false
    @State private var sentence = ""
    @State private var selectedPhrase = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(term: VocabularyTerm, history: [HistoryEntry], knownTerms: [VocabularyTerm],
         mode: VocabularyLearningMode, onAdd: @escaping ([String]) -> Void) {
        self.term = term
        self.history = history
        self.knownTerms = knownTerms
        self.onAdd = onAdd
        _mode = State(initialValue: mode)
    }

    private var selectionMessage: String? {
        VocabularySuggestions.validationMessage(for: selectedPhrase, term: term, knownTerms: knownTerms)
    }

    private var chosenPhrases: [String] {
        if mode == .sentence { return selectionMessage == nil ? [selectedPhrase] : [] }
        return suggestions.filter { selectedIDs.contains($0.id) }.map(\.phrase)
    }

    var body: some View {
        SettingsSheet("Improve \(term.text)",
                      subtitle: "Choose the spellings Dictari should replace with \(term.text).",
                      width: 560, height: 500) {
            VStack(alignment: .leading, spacing: 14) {
                MonoSegmented(selection: $mode,
                              options: VocabularyLearningMode.allCases.map { (value: $0, label: $0.title) })
                    .frame(maxWidth: 280)
                    .accessibilityLabel(Text("Source", comment: "Accessibility: picker choosing where vocabulary suggestions come from"))

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if mode == .history {
                            historyContent.transition(.opacity)
                        } else {
                            sentenceContent.transition(.opacity)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 2)
                }
                .monoAnimation(Motion.reveal, value: loaded)
                .monoAnimation(Motion.reveal, value: selectionMessage == nil)

                SettingsFootnote("Affects future transcriptions. History stays unchanged.")
                    .padding(.horizontal, -4)
            }
        } actions: {
            Button("Cancel") { dismiss() }
                .buttonStyle(MonoActionButtonStyle(.secondary))
                .keyboardShortcut(.cancelAction)
            Button(chosenPhrases.count > 1
                   ? String(localized: "Add \(chosenPhrases.count) Variants",
                            comment: "Vocabulary: adds the selected misheard spellings (count > 1)")
                   : String(localized: "Add to Heard as",
                            comment: "Vocabulary: \"Heard as\" is the name of the alternatives field")) {
                onAdd(chosenPhrases)
                dismiss()
            }
            .buttonStyle(MonoActionButtonStyle(.primary))
            .keyboardShortcut(.defaultAction)
            .disabled(chosenPhrases.isEmpty)
            .contentTransition(.numericText())
            .monoAnimation(Motion.swap, value: chosenPhrases.count)
        }
        .task(id: mode) {
            selectedPhrase = ""
            if mode == .history && !loaded { await loadSuggestions() }
        }
    }

    @ViewBuilder private var historyContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Matches from your last \(VocabularySuggestions.historyLimit) transcriptions. Check the context before adding.")
                .font(Typo.secondary)
                .foregroundStyle(Mono.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if loading || !loaded {
                VocabularySearchingIndicator(label: "Searching history…")
            } else if suggestions.isEmpty {
                SettingsEmptyState(
                    systemImage: "magnifyingglass",
                    title: "No similar spellings found",
                    message: "History stores final text only. If the error isn't there, use a sentence."
                ) {
                    Button("Use a Sentence…") { mode = .sentence }
                        .buttonStyle(MonoActionButtonStyle(.secondary))
                }
                .transition(.monoReveal(reduceMotion: reduceMotion))
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(suggestions) { suggestion in
                        VocabularyLearningSuggestionRow(
                            suggestion: suggestion,
                            term: term.text,
                            isSelected: selectedIDs.contains(suggestion.id)
                        ) {
                            withAnimation(Motion.reduced(Motion.snap, reduceMotion: reduceMotion)) {
                                if !selectedIDs.insert(suggestion.id).inserted { selectedIDs.remove(suggestion.id) }
                            }
                        }
                    }
                }
                .transition(.monoReveal(reduceMotion: reduceMotion))
            }
        }
    }

    private var sentenceContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Paste a sentence and select the wrong word or phrase.")
                .font(Typo.secondary)
                .foregroundStyle(Mono.secondaryText)
            VocabularySentenceEditor(text: $sentence, selectedPhrase: $selectedPhrase)
                .frame(height: 130)
                .background(Mono.fieldFill,
                            in: RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous))
            if let message = selectionMessage {
                Label(message, systemImage: "text.cursor")
                    .symbolRenderingMode(.monochrome)
                    .font(Typo.secondary)
                    .foregroundStyle(Mono.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Text(selectedPhrase)
                            .foregroundStyle(Mono.secondaryText)
                            .strikethrough(true, color: Mono.tertiaryText)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Mono.tertiaryText)
                            .accessibilityHidden(true)
                        Text(term.text)
                            .foregroundStyle(Mono.primaryText)
                    }
                    .font(Typo.body.weight(.medium))
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(selectedPhrase) becomes \(term.text)")

                    Rectangle().fill(Mono.cardBorder).frame(height: 0.5)

                    SettingsSectionLabel("Preview")
                    Text(preview)
                        .font(Typo.body)
                        .foregroundStyle(Mono.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .padding(Metrics.cardPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                        .fill(Mono.card)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                        .strokeBorder(Mono.cardBorder, lineWidth: 0.5)
                )
                .transition(.monoReveal(reduceMotion: reduceMotion))
            }
        }
    }

    private var preview: String {
        var edited = term
        edited.enabled = true
        edited.alternatives.append(selectedPhrase)
        return VocabularyCorrector(terms: [edited]).correct(sentence)
    }

    @MainActor private func loadSuggestions() async {
        loading = true
        let term = term, history = history, knownTerms = knownTerms
        let work = Task.detached(priority: .utility) {
            try VocabularySuggestions.find(for: term, in: history, knownTerms: knownTerms,
                                           limit: VocabularySuggestions.candidatePool)
        }
        do {
            let result = try await withTaskCancellationHandler {
                try await work.value
            } onCancel: { work.cancel() }
            guard !Task.isCancelled else { return }
            // Dictionary check on the main actor, over a few dozen candidates at most.
            let lexicon = SpellingLexicon()
            suggestions = VocabularySuggestions.filtered(result, limit: 12) { lexicon.isKnownWord($0) }
            loaded = true
            loading = false
        } catch {
            // Cancellation is the only thrown outcome; reopening restarts the search.
            loading = false
        }
    }
}

/// One suggestion as a selectable card: the whole card toggles it, with a check that
/// swaps in place and a firmer outline while selected. Ink only.
private struct VocabularyLearningSuggestionRow: View {
    let suggestion: VocabularySuggestion
    let term: String
    let isSelected: Bool
    let toggle: () -> Void
    @State private var hovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.cardRadius - 2, style: .continuous)
        Button(action: toggle) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(isSelected ? Mono.primaryText : Mono.tertiaryText)
                    .contentTransition(.symbolEffect(.replace))
                    .accessibilityHidden(true)
                VocabularySuggestionSummary(suggestion: suggestion, term: term)
            }
            .foregroundStyle(Mono.primaryText)
            .padding(12)
            .background {
                shape.fill(Mono.card)
                shape.fill(isSelected || hovered ? Mono.hover : Color.clear)
            }
            .overlay(shape.strokeBorder(isSelected ? Mono.ink(0.45) : Mono.cardBorder,
                                        lineWidth: isSelected ? 1 : 0.5))
            .contentShape(shape)
        }
        .buttonStyle(MonoPlainButtonStyle(scales: false))
        .onHover { hovered = $0 }
        .monoAnimation(Motion.hover, value: hovered)
        .accessibilityLabel(VocabularySuggestionSummary.accessibilityText(suggestion, term: term))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Indeterminate progress for a background search: a short bar and what it is doing.
/// Shared by the per-word picker and the history scan.
struct VocabularySearchingIndicator: View {
    let label: LocalizedStringKey

    var body: some View {
        VStack(spacing: 10) {
            MonoProgressBar(value: nil)
                .frame(width: 140)
            Text(label)
                .font(Typo.secondary)
                .foregroundStyle(Mono.secondaryText)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
        .accessibilityElement(children: .combine)
    }
}

/// NSTextView provides selection ranges on macOS 14, where SwiftUI TextEditor has no
/// selection binding. Keep editing native (paste, keyboard selection, accessibility).
private struct VocabularySentenceEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var selectedPhrase: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        guard let editor = scroll.documentView as? NSTextView else { return scroll }
        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.drawsBackground = false
        editor.font = .systemFont(ofSize: 13)
        editor.textColor = NSColor(Mono.primaryText)
        editor.insertionPointColor = NSColor(Mono.primaryText)
        editor.selectedTextAttributes = [.backgroundColor: NSColor(Mono.selection),
                                         .foregroundColor: NSColor(Mono.selectionText)]
        editor.textContainerInset = NSSize(width: 10, height: 10)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.setAccessibilityLabel(String(localized: "Sentence to learn from",
                                            comment: "Accessibility: text view where the user pastes a sentence"))
        editor.delegate = context.coordinator
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? NSTextView, editor.string != text else { return }
        context.coordinator.updating = true
        editor.string = text
        context.coordinator.updating = false
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: VocabularySentenceEditor
        var updating = false
        init(_ parent: VocabularySentenceEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard !updating, let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
            updateSelection(editor)
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard !updating, let editor = notification.object as? NSTextView else { return }
            updateSelection(editor)
        }
        private func updateSelection(_ editor: NSTextView) {
            parent.selectedPhrase = VocabularySuggestions.selectedPhrase(in: editor.string, range: editor.selectedRange())
        }
    }
}
