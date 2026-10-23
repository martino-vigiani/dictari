// HistoryCorrectionSheet.swift
// Dictari — correct a history entry by hand, then optionally teach the vocabulary.
//
// Two steps on purpose. Saving the correction is always safe (it only touches this entry);
// learning changes every future dictation, so it is a separate, explicit confirmation with
// each proposal visible and individually removable.

import SwiftUI

struct HistoryCorrectionSheet: View {
    let entry: HistoryEntry
    let history: HistoryStore
    let vocabulary: VocabularyStore
    @Environment(\.dismiss) private var dismiss

    @State private var draft: String
    @State private var proposals: [Proposal] = []
    @State private var selectedIDs: Set<String> = []
    @State private var step: Step = .edit
    @State private var refusals: [String] = []
    @State private var selection: TextSelection?
    @FocusState private var editorFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Computed once: the entry's original text and spans do not change while the sheet is up.
    private let uncertainRanges: [Range<String.Index>]

    private enum Step { case edit, learn, done }

    /// A diff proposal plus what the vocabulary would do with it right now.
    private struct Proposal: Identifiable {
        let substitution: Substitution
        let refusal: String?
        let extendsExistingTerm: Bool
        var id: String { substitution.id }
    }

    init(entry: HistoryEntry, history: HistoryStore, vocabulary: VocabularyStore) {
        self.entry = entry
        self.history = history
        self.vocabulary = vocabulary
        _draft = State(initialValue: entry.displayText)
        uncertainRanges = UncertainSpanRendering.ranges(in: entry.text, spans: entry.uncertainSpans)
    }

    private var chosen: [Proposal] {
        proposals.filter { selectedIDs.contains($0.id) && $0.refusal == nil }
    }

    private var draftIsEmpty: Bool {
        !draft.contains(where: { !$0.isWhitespace })
    }

    var body: some View {
        // Each step is a whole sheet of its own; they cross-fade in one frame so the window
        // never resizes between "edit" and "learn".
        ZStack(alignment: .topLeading) {
            switch step {
            case .edit: editContent.transition(.monoReveal(reduceMotion: reduceMotion))
            case .learn: learnContent.transition(.monoReveal(reduceMotion: reduceMotion))
            case .done: doneContent.transition(.monoReveal(reduceMotion: reduceMotion))
            }
        }
        .frame(width: 580, height: 460, alignment: .topLeading)
        .background(Mono.windowBackground)
    }

    private func go(to next: Step) {
        withAnimation(Motion.reduced(Motion.reveal, reduceMotion: reduceMotion)) { step = next }
    }

    // MARK: - Step 1: edit

    private var editContent: some View {
        SettingsSheet(
            "Correct Transcription",
            subtitle: "Fix what Dictari misheard. The original is kept for reference.",
            width: 580, height: 460
        ) {
            VStack(alignment: .leading, spacing: 14) {
                if !uncertainRanges.isEmpty { uncertainReference }
                TextEditor(text: $draft, selection: $selection)
                    .focused($editorFocused)
                    .font(Typo.body)
                    .lineSpacing(2)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous).fill(Mono.card)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                            .strokeBorder(editorFocused ? Mono.ink(0.35) : Mono.cardBorder,
                                          lineWidth: editorFocused ? 1 : 0.5)
                    )
                    .monoAnimation(Motion.hover, value: editorFocused)
                    .accessibilityLabel("Corrected transcription")
                HStack(spacing: 8) {
                    if entry.correctedText != nil {
                        Button("Restore Original") {
                            history.setCorrectedText(nil, for: entry.id)
                            dismiss()
                        }
                        .buttonStyle(MonoActionButtonStyle(.outline))
                    }
                    Spacer()
                    Text("⌘↩ to save")
                        .font(Typo.secondary)
                        .foregroundStyle(Mono.tertiaryText)
                        .accessibilityHidden(true)
                }
            }
        } actions: {
            Button("Cancel") { dismiss() }
                .buttonStyle(MonoActionButtonStyle())
                .keyboardShortcut(.cancelAction)
            // ⌘Return, not Return: Return must insert a newline in the editor above.
            Button("Save") { save() }
                .buttonStyle(MonoActionButtonStyle(.primary))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(draftIsEmpty)
        }
    }

    /// The original transcript with the words the model was unsure of underlined. Each one is
    /// a link: clicking it selects the same word in the editor, so fixing it is one click and a
    /// retype. Spans index `entry.text`, which is why the reference shows the original even
    /// when the editor starts from an earlier correction.
    private var uncertainReference: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsSectionLabel("Check the underlined words")
            ScrollView {
                Text(referenceText)
                    .font(Typo.body)
                    .foregroundStyle(Mono.secondaryText)
                    // Links take the tint; keep them in the monochrome palette.
                    .tint(Mono.primaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .environment(\.openURL, OpenURLAction { url in
                        selectUncertainWord(from: url)
                        return .handled
                    })
            }
            .frame(maxHeight: 72)
            .accessibilityHint("Underlined words may be misheard. Activate one to select it in the editor.")
        }
    }

    private var referenceText: AttributedString {
        var attributed = UncertainSpanRendering.attributed(
            text: entry.text, spans: entry.uncertainSpans, underline: Mono.secondaryText.opacity(0.7)
        )
        for (index, range) in uncertainRanges.enumerated() {
            guard let target = Range<AttributedString.Index>(range, in: attributed),
                  let url = URL(string: "\(Self.uncertainScheme)://word/\(index)") else { continue }
            attributed[target].link = url
            attributed[target].foregroundColor = Mono.primaryText
        }
        return attributed
    }

    private static let uncertainScheme = "dictari-uncertain"

    private func selectUncertainWord(from url: URL) {
        guard url.scheme == Self.uncertainScheme,
              let index = Int(url.lastPathComponent), uncertainRanges.indices.contains(index),
              let range = UncertainSpanRendering.matchingRange(
                of: uncertainRanges[index], in: entry.text, draft: draft
              ) else { return }
        editorFocused = true
        selection = TextSelection(range: range)
    }

    private func save() {
        history.setCorrectedText(draft, for: entry.id)
        // Always diff against the model's original words: "heard as" must be what the model
        // produced, not an earlier hand edit. Mappings the vocabulary already has are hidden.
        proposals = CorrectionDiff.substitutions(original: entry.text, edited: draft).compactMap { substitution in
            switch vocabulary.learningOutcome(heard: substitution.heard, written: substitution.written) {
            case .alreadyKnown: return nil
            case .rejected(let reason):
                return Proposal(substitution: substitution, refusal: reason, extendsExistingTerm: false)
            case .addedAlternative:
                return Proposal(substitution: substitution, refusal: nil, extendsExistingTerm: true)
            case .addedTerm:
                return Proposal(substitution: substitution, refusal: nil, extendsExistingTerm: false)
            }
        }
        guard proposals.contains(where: { $0.refusal == nil }) else {
            dismiss()
            return
        }
        selectedIDs = Set(proposals.filter { $0.refusal == nil }.map(\.id))
        go(to: .learn)
    }

    // MARK: - Step 2: learn

    private var learnContent: some View {
        SettingsSheet(
            "Learn From This Correction",
            subtitle: "Correction saved. Add these to Vocabulary so they’re fixed next time?",
            width: 580, height: 460
        ) {
            VStack(alignment: .leading, spacing: 12) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(proposals) { proposal in proposalRow(proposal) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                SettingsFootnote("Each mapping replaces the exact phrase on the left whenever it is heard. Uncheck anything that could be a real word in other sentences.")
            }
        } actions: {
            Button("Not Now") { dismiss() }
                .buttonStyle(MonoActionButtonStyle())
                .keyboardShortcut(.cancelAction)
            Button(chosen.count > 1
                   ? String(localized: "Add \(chosen.count) to Vocabulary",
                            comment: "Button: add the selected mappings (always more than one) to Vocabulary")
                   : String(localized: "Add to Vocabulary", comment: "Button: add the one selected mapping")) { learn() }
                .buttonStyle(MonoActionButtonStyle(.primary))
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty)
                .contentTransition(.numericText())
                .monoAnimation(Motion.snap, value: chosen.count)
        }
    }

    private func proposalRow(_ proposal: Proposal) -> some View {
        let selected = selectedIDs.contains(proposal.id)
        let enabled = proposal.refusal == nil
        // `refusal` comes from the vocabulary already worded; only the two fallbacks are ours.
        let subtitle = proposal.refusal
            ?? (proposal.extendsExistingTerm
                ? String(localized: "Adds a Heard as spelling to \(proposal.substitution.written)",
                         comment: "Learn step: the mapping extends an existing Vocabulary word. “Heard as” is the Vocabulary field name.")
                : String(localized: "Adds \(proposal.substitution.written) to Vocabulary",
                         comment: "Learn step: the mapping creates a new Vocabulary word"))
        return Button {
            guard enabled else { return }
            withAnimation(Motion.reduced(Motion.snap, reduceMotion: reduceMotion)) {
                if !selectedIDs.insert(proposal.id).inserted { selectedIDs.remove(proposal.id) }
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: !enabled ? "minus.circle" : (selected ? "checkmark.circle.fill" : "circle"))
                    .symbolRenderingMode(.monochrome)
                    .contentTransition(.symbolEffect(.replace))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Heard as \(proposal.substitution.heard) → write \(proposal.substitution.written)",
                         comment: "Learn step: what the model heard, then the word to write instead")
                        .font(Typo.body.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(subtitle)
                        .font(Typo.secondary)
                        .foregroundStyle(Mono.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(enabled ? Mono.primaryText : Mono.secondaryText)
            .padding(12)
            .background(selected && enabled ? Mono.hover : Mono.card,
                        in: RoundedRectangle(cornerRadius: Metrics.cardRadius - 2, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.cardRadius - 2, style: .continuous)
                    .strokeBorder(selected && enabled ? Mono.ink(0.25) : Mono.cardBorder, lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(MonoPlainButtonStyle(scales: false))
        .disabled(!enabled)
        .accessibilityLabel("Heard as \(proposal.substitution.heard), write \(proposal.substitution.written). \(subtitle)")
        .accessibilityAddTraits(selected && enabled ? .isSelected : [])
    }

    private func learn() {
        refusals = chosen.compactMap { proposal in
            // Re-checked at apply time: an earlier mapping in this batch can claim a phrase.
            if case .rejected(let reason) = vocabulary.learn(heard: proposal.substitution.heard,
                                                              written: proposal.substitution.written) {
                return String(localized: "\(proposal.substitution.heard) → \(proposal.substitution.written): \(reason)",
                              comment: "A mapping that could not be learned: heard → written: reason")
            }
            return nil
        }
        if refusals.isEmpty { dismiss() } else { go(to: .done) }
    }

    // MARK: - Step 3: only when something could not be added

    private var doneContent: some View {
        SettingsSheet(
            "Some Mappings Were Not Added",
            subtitle: "Your correction is saved. These could not go into Vocabulary.",
            width: 580, height: 460
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(refusals, id: \.self) { refusal in
                        SettingsNotice(refusal, systemImage: "minus.circle")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } actions: {
            Button("Done") { dismiss() }
                .buttonStyle(MonoActionButtonStyle(.primary))
                .keyboardShortcut(.defaultAction)
        }
    }
}
