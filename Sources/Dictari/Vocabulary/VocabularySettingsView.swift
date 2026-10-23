// VocabularySettingsView.swift
// Dictari — the words Dictari must get right, and a place to prove that it does.
//
// Mounted by the settings root as `VocabularySettingsView(store: app.vocabulary)`.

import SwiftUI
import UniformTypeIdentifiers

struct VocabularySettingsView: View {
    var store: VocabularyStore
    var history: [HistoryEntry]

    @State private var isTransferring = false
    @State private var transferMessage: String?
    @State private var transferError: String?
    @State private var expandedID: UUID?
    @State private var isScanning = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(store: VocabularyStore, history: [HistoryEntry] = []) {
        self.store = store
        self.history = history
    }

    var body: some View {
        SettingsScrollPane(title: "Vocabulary",
                           subtitle: "Names, products or jargon for Dictari to correct.") {
            SettingsCard(title: "Words") {
                // Own views with their own text state: as properties of this page, every
                // keystroke re-ran this body and with it every word row below.
                VocabularyAddRow(store: store)

                if store.terms.isEmpty {
                    SettingsCardDivider()
                    SettingsEmptyState(
                        systemImage: "character.book.closed",
                        title: "No words yet",
                        message: "Add your name or another word Dictari often gets wrong."
                    )
                    .transition(.monoReveal(reduceMotion: reduceMotion))
                } else {
                    ForEach(store.terms) { term in
                        // Divider and row travel together, so a removed word takes its
                        // hairline with it instead of leaving a doubled line behind.
                        VStack(spacing: 0) {
                            SettingsCardDivider()
                            VocabularyTermRow(
                                term: term,
                                history: history,
                                knownTerms: store.terms,
                                isExpanded: expandedID == term.id,
                                onToggleExpanded: {
                                    withAnimation(Motion.reduced(Motion.reveal, reduceMotion: reduceMotion)) {
                                        expandedID = expandedID == term.id ? nil : term.id
                                    }
                                },
                                onUpdate: { store.update($0) },
                                onDelete: {
                                    withAnimation(Motion.reduced(Motion.reveal, reduceMotion: reduceMotion)) {
                                        if expandedID == term.id { expandedID = nil }
                                        store.delete(term)
                                    }
                                }
                            )
                        }
                        .transition(.monoReveal(reduceMotion: reduceMotion))
                    }
                }
            }
            .settingsSearchAnchor("vocabulary.words")

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Button("Import…", action: importVocabulary)
                        .buttonStyle(MonoActionButtonStyle(.secondary))
                        .settingsSearchAnchor("vocabulary.import")
                    Button("Export…", action: exportVocabulary)
                        .buttonStyle(MonoActionButtonStyle(.secondary))
                        .disabled(store.terms.isEmpty)
                        .settingsSearchAnchor("vocabulary.export")
                    Spacer()
                    // Every enabled word at once; the per-word picker stays on each row.
                    Button("Scan History…") { isScanning = true }
                        .buttonStyle(MonoActionButtonStyle(.secondary))
                        .disabled(!store.terms.contains(where: \.enabled) || history.isEmpty)
                        .help("Find phrases in your history that sound like your words")
                        .settingsSearchAnchor("vocabulary.scan")
                }
                .disabled(isTransferring)

                if let transferMessage {
                    Label(transferMessage, systemImage: "checkmark")
                        .symbolRenderingMode(.monochrome)
                        .font(Typo.secondary)
                        .foregroundStyle(Mono.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                        .accessibilityLabel(transferMessage)
                        .transition(.monoReveal(reduceMotion: reduceMotion))
                }
                if let error = store.persistenceError {
                    SettingsNotice(error, systemImage: "exclamationmark.triangle")
                        .transition(.monoReveal(reduceMotion: reduceMotion))
                }
            }
            .monoAnimation(Motion.reveal, value: transferMessage)
            .monoAnimation(Motion.reveal, value: store.persistenceError)

            VocabularyTryItCard(store: store).settingsSearchAnchor("vocabulary.tryIt")

        }
        .sheet(isPresented: $isScanning) {
            VocabularyScanSheet(store: store, history: history)
        }
        .alert("Vocabulary", isPresented: Binding(
            get: { transferError != nil },
            set: { if !$0 { transferError = nil } }
        )) {
            Button("OK", role: .cancel) { transferError = nil }
        } message: {
            Text(transferError ?? "")
        }
    }

    private func importVocabulary() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = String(localized: "Import words and alternatives. Existing words and on/off choices stay unchanged.",
                               comment: "Open panel message for vocabulary import")
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            transferMessage = nil
            isTransferring = true
            Task { @MainActor in
                defer { isTransferring = false }
                do {
                    let limit = VocabularyStore.maximumImportBytes
                    let data = try await Task.detached(priority: .userInitiated) {
                        // Bounded read also handles a file that grows after the panel closes.
                        let handle = try FileHandle(forReadingFrom: url)
                        defer { try? handle.close() }
                        return try handle.read(upToCount: limit + 1) ?? Data()
                    }.value
                    let summary = try store.importData(data)
                    transferMessage = String(localized: "Added \(summary.added) words; merged \(summary.merged) existing entries.",
                                             comment: "Vocabulary import result; both numbers need plural forms")
                } catch {
                    transferError = error.localizedDescription
                }
            }
        }
    }

    private func exportVocabulary() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Dictari Vocabulary.json"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            transferMessage = nil
            isTransferring = true
            Task { @MainActor in
                defer { isTransferring = false }
                do {
                    let data = try store.exportData()
                    try await Task.detached(priority: .userInitiated) {
                        try data.write(to: url, options: .atomic)
                    }.value
                    transferMessage = String(localized: "Vocabulary exported.", comment: "Vocabulary export result")
                } catch {
                    transferError = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Add row

private struct VocabularyAddRow: View {
    let store: VocabularyStore
    @State private var draft = ""
    @FocusState private var addFieldFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// One field, one Return. Adding a word is a single action, not a form to fill in —
    /// the details (alternatives, on/off) live on the row afterwards, where they belong.
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus")
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(draft.isEmpty ? Mono.tertiaryText : Mono.primaryText)
                .imageScale(.small)
                .frame(width: 16)

            TextField("Add a word or phrase, then press Return", text: $draft)
                .textFieldStyle(.plain)
                .font(Typo.body)
                .foregroundStyle(Mono.primaryText)
                .focused($addFieldFocused)
                .onSubmit(commitDraft)

            if !draft.isEmpty {
                Button("Add", action: commitDraft)
                    .buttonStyle(MonoActionButtonStyle(.primary, size: .small))
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .frame(minHeight: Metrics.controlHeightSmall)
        .padding(Metrics.cardPadding)
        .monoAnimation(Motion.snap, value: draft.isEmpty)
        .contentShape(Rectangle())
        .onTapGesture { addFieldFocused = true }
    }

    private func commitDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        withAnimation(Motion.reduced(Motion.reveal, reduceMotion: reduceMotion)) {
            store.add(VocabularyTerm(text: text))
            draft = ""
        }
        addFieldFocused = true
    }
}

// MARK: - Try it card

private struct VocabularyTryItCard: View {
    let store: VocabularyStore
    @State private var trial = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// An invisible feature nobody trusts is a feature nobody keeps enabled. Typing a
    /// sentence here shows exactly what would happen to it — including nothing happening.
    var body: some View {
        let result = store.corrector.result(for: trial)
        let corrections = result.corrections
        let corrected = result.text
        let hasInput = !trial.trimmingCharacters(in: .whitespaces).isEmpty

        return SettingsCard(title: "Try it") {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Type or paste a sentence…", text: $trial, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .font(Typo.body)
                    .foregroundStyle(Mono.primaryText)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous)
                            .fill(Mono.fieldFill)
                    )

                if hasInput {
                    Group {
                        if corrections.isEmpty {
                            Label("Nothing to correct", systemImage: "equal")
                                .symbolRenderingMode(.monochrome)
                                .font(Typo.secondary)
                                .foregroundStyle(Mono.secondaryText)
                        } else {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Image(systemName: "arrow.turn.down.right")
                                        .symbolRenderingMode(.monochrome)
                                        .font(Typo.secondary)
                                        .foregroundStyle(Mono.tertiaryText)
                                        .accessibilityHidden(true)
                                    Text(corrected)
                                        .font(Typo.body)
                                        .foregroundStyle(Mono.primaryText)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .textSelection(.enabled)
                                }

                                FlowRow(spacing: 6) {
                                    ForEach(corrections, id: \.self) { correction in
                                        CorrectionChip(correction: correction)
                                            .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96)))
                                    }
                                }
                            }
                        }
                    }
                    .transition(.monoReveal(reduceMotion: reduceMotion))
                }
            }
            .padding(Metrics.cardPadding)
            // Only the verdict animates, never each keystroke: the value is the set of
            // corrections, which changes far less often than the text.
            .monoAnimation(Motion.reveal, value: corrections)
            .monoAnimation(Motion.reveal, value: hasInput)
        }
    }
}

// MARK: - Term row

private struct VocabularyTermRow: View {
    let term: VocabularyTerm
    let history: [HistoryEntry]
    let knownTerms: [VocabularyTerm]
    let isExpanded: Bool
    let onToggleExpanded: () -> Void
    let onUpdate: (VocabularyTerm) -> Void
    let onDelete: () -> Void

    @State private var isHovered = false
    @State private var learningMode: VocabularyLearningMode?
    @State private var alternativesDraft = ""
    @State private var textDraft = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { term.enabled },
            set: { newValue in
                var next = term
                next.enabled = newValue
                onUpdate(next)
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Button(action: toggleEditing) {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(term.text)
                                .font(Typo.body.weight(isExpanded ? .medium : .regular))
                                .foregroundStyle(term.enabled ? Mono.primaryText : Mono.tertiaryText)
                            Text(subtitle)
                                .font(Typo.secondary)
                                .foregroundStyle(Mono.tertiaryText)
                                .lineLimit(1)
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .symbolRenderingMode(.monochrome)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(isHovered || isExpanded ? Mono.secondaryText : Mono.tertiaryText)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(MonoPlainButtonStyle(scales: false))
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(isExpanded ? "Finish editing \(term.text)" : "Edit \(term.text)")
                .accessibilityValue(subtitle)

                Button(action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(MonoGlyphButtonStyle())
                .accessibilityLabel("Remove \(term.text)")
                .help("Remove this word")

                Toggle("", isOn: enabledBinding)
                    .labelsHidden()
                    .toggleStyle(MonoToggleStyle())
                    .accessibilityLabel(term.enabled ? "Disable \(term.text)" : "Enable \(term.text)")
                    .help(term.enabled ? "Applied to every transcription" : "Ignored")
            }
            .padding(Metrics.cardPadding)
            .onHover { isHovered = $0 }

            if isExpanded {
                editor
            }
        }
        // The open row keeps a faint wash so the editor reads as belonging to this word.
        .background(isExpanded ? Mono.fieldFill.opacity(0.5) : (isHovered ? Mono.hover.opacity(0.5) : Color.clear))
        .monoAnimation(Motion.hover, value: isHovered)
        .monoAnimation(Motion.snap, value: term.enabled)
        .sheet(item: $learningMode) { mode in
            VocabularyLearningSheet(term: editedTerm, history: history, knownTerms: knownTerms,
                                    mode: mode, onAdd: addLearnedAlternatives)
        }
    }

    private var subtitle: String {
        if term.alternatives.isEmpty {
            return String(localized: "Also fixes close misspellings",
                          comment: "Vocabulary word row subtitle when it has no alternatives")
        }
        // The alternatives are the user's own spellings: listed as typed, never translated.
        return String(localized: "Also heard as \(term.alternatives.joined(separator: ", "))",
                      comment: "Vocabulary word row subtitle; %@ is the user's comma-separated alternatives")
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 12) {
            labelledField(
                Text("Word", comment: "Vocabulary editor field label"),
                placeholder: Text(verbatim: "Martino"),
                text: $textDraft,
                help: nil
            )
            labelledField(
                Text("Heard as", comment: "Vocabulary editor field label: misheard spellings of the word"),
                placeholder: Text("Spellings you have seen in transcriptions",
                                  comment: "Placeholder of the Heard as field"),
                text: $alternativesDraft,
                help: Text("Add real mishearings, separated by commas. Dictari matches them exactly.",
                           comment: "Help under the Heard as field")
            )

            HStack(spacing: 8) {
                Group {
                    Button("Suggest from History") { learningMode = .history }
                    Button("Use a Sentence…") { learningMode = .sentence }
                }
                .buttonStyle(MonoActionButtonStyle(.secondary, size: .small))
                .disabled(textDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Spacer()

                Button("Done") {
                    commit()
                    onToggleExpanded()
                }
                .buttonStyle(MonoActionButtonStyle(.primary, size: .small))
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, Metrics.cardPadding)
        .padding(.bottom, Metrics.cardPadding)
        .transition(.monoReveal(reduceMotion: reduceMotion))
    }

    @ViewBuilder
    private func labelledField(
        _ label: Text,
        placeholder: Text,
        text: Binding<String>,
        help: Text?
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsSectionLabel(label)
            // Label slot = placeholder, as `TextField(_:text:)` does with its title.
            TextField(text: text) { placeholder }
                .textFieldStyle(.plain)
                .font(Typo.body)
                .foregroundStyle(Mono.primaryText)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous)
                        .fill(Mono.fieldFill)
                )
                .onSubmit(commit)
            if let help {
                help
                    .font(Typo.secondary)
                    .foregroundStyle(Mono.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func beginEditing() {
        textDraft = term.text
        alternativesDraft = term.alternatives.joined(separator: ", ")
        onToggleExpanded()
    }

    private func toggleEditing() {
        if isExpanded {
            commit()
            onToggleExpanded()
        } else {
            beginEditing()
        }
    }

    private var editedTerm: VocabularyTerm {
        var next = term
        let trimmed = textDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { next.text = trimmed }
        next.alternatives = alternativesDraft
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return next
    }

    private func addLearnedAlternatives(_ phrases: [String]) {
        var next = editedTerm
        for phrase in phrases {
            guard VocabularySuggestions.validationMessage(for: phrase, term: next, knownTerms: knownTerms) == nil else { continue }
            next.alternatives.append(phrase)
        }
        alternativesDraft = next.alternatives.joined(separator: ", ")
        onUpdate(next)
    }

    private func commit() {
        onUpdate(editedTerm)
    }
}

// MARK: - Correction chip

private struct CorrectionChip: View {
    let correction: VocabularyCorrection

    var body: some View {
        HStack(spacing: 5) {
            Text(correction.original)
                .foregroundStyle(Mono.tertiaryText)
                .strikethrough(true, color: Mono.tertiaryText)
            Image(systemName: "arrow.right")
                .symbolRenderingMode(.monochrome)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(Mono.tertiaryText)
            Text(correction.replacement)
                .foregroundStyle(Mono.primaryText)
        }
        .font(Typo.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule(style: .continuous).fill(Mono.fieldFill))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(correction.original) becomes \(correction.replacement)")
    }
}

// MARK: - Flow layout

/// Wraps chips onto as many lines as they need. `Layout` rather than an `HStack` because the
/// number of corrections is whatever the sentence produced, and a horizontal run would clip.
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                widest = max(widest, x - spacing)
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        widest = max(widest, x - spacing)
        return CGSize(width: min(widest, maxWidth), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

// MARK: - Button styles

/// Kept for the screens that still use it (AI Agents, Dictation, History, Team). Vocabulary
/// itself has moved to `MonoActionButtonStyle(.primary, size: .small)`, which this mirrors.
struct VocabularyQuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typo.secondary.weight(.medium))
            .foregroundStyle(Mono.selectionText)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule(style: .continuous).fill(Mono.selection))
            .modifier(MonoPressFeedback(isPressed: configuration.isPressed))
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Vocabulary") {
    VocabularySettingsView(store: VocabularyStore(terms: [
        VocabularyTerm(text: "Martino", alternatives: ["Martin"]),
        VocabularyTerm(text: "Dictari"),
        VocabularyTerm(text: "Parakeet TDT", enabled: false),
    ]))
    .frame(width: 640, height: 620)
}
#endif
