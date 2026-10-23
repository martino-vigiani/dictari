// VocabularyScanSheet.swift
// Dictari — "Scan history": every vocabulary term at once, one decision per phrase.
//
// The per-term picker (`VocabularyLearningSheet`) answers "how has Dictari misheard *this*
// word?". This sheet answers the question users actually arrive with — "what has it been
// getting wrong?" — by scanning recent history for phrases that sound like any enabled term.
// Nothing is applied automatically: each phrase is approved (becomes a "Heard as"
// alternative through `VocabularyStore.learn`, the same path History corrections use) or
// dismissed, one by one, with the sentence it came from in view.

import SwiftUI

struct VocabularyScanSheet: View {
    var store: VocabularyStore
    let history: [HistoryEntry]
    @Environment(\.dismiss) private var dismiss

    @State private var results: [VocabularyScanResult] = []
    @State private var loaded = false
    /// Per-row outcome messages ("Added to Heard as", or why `learn` refused).
    @State private var notes: [String: String] = [:]
    @State private var added = 0
    /// Whether the scan found anything at all, so an emptied list reads as "done", not
    /// as "nothing found".
    @State private var foundAny = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        SettingsSheet("Scan History",
                      subtitle: "Phrases from your last \(VocabularySuggestions.historyLimit) transcriptions that sound like your words. Nothing changes until you add one.",
                      width: 600, height: 560) {
            VStack(alignment: .leading, spacing: 14) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if !loaded {
                            VocabularySearchingIndicator(label: "Scanning history…")
                        } else if results.isEmpty {
                            emptyState
                                .transition(.monoReveal(reduceMotion: reduceMotion))
                        } else {
                            ForEach(results) { result in
                                termGroup(result)
                                    .transition(.monoReveal(reduceMotion: reduceMotion))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 2)
                }
                .monoAnimation(Motion.reveal, value: loaded)

                HStack(spacing: 6) {
                    if added > 0 {
                        Image(systemName: "checkmark")
                            .symbolRenderingMode(.monochrome)
                            .accessibilityHidden(true)
                            .transition(.opacity)
                    }
                    Text(added == 0
                         ? "Affects future transcriptions. History stays unchanged."
                         : "Added \(added) to Heard as. Affects future transcriptions; history stays unchanged.")
                        .contentTransition(.numericText())
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(Typo.secondary)
                .foregroundStyle(Mono.secondaryText)
                .monoAnimation(Motion.swap, value: added)
            }
        } actions: {
            Button("Done") { dismiss() }
                .buttonStyle(MonoActionButtonStyle(.primary))
                .keyboardShortcut(.defaultAction)
        }
        .task { await scan() }
    }

    @ViewBuilder private var emptyState: some View {
        if foundAny {
            SettingsEmptyState(
                systemImage: "checkmark.circle",
                title: "All reviewed",
                message: "Every suggestion has been added or dismissed."
            )
        } else {
            SettingsEmptyState(
                systemImage: "magnifyingglass",
                title: "No likely mishearings found",
                message: "History stores final text only. If a word was corrected while you dictated, it won't show up here."
            )
        }
    }

    private func termGroup(_ result: VocabularyScanResult) -> some View {
        VStack(alignment: .leading, spacing: Metrics.cardLabelGap) {
            SettingsSectionLabel(result.term.text)
                .padding(.leading, 4)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(result.suggestions) { suggestion in
                    row(suggestion, term: result.term)
                        .transition(.monoReveal(reduceMotion: reduceMotion))
                }
            }
        }
    }

    private func row(_ suggestion: VocabularySuggestion, term: VocabularyTerm) -> some View {
        let noteKey = Self.noteKey(term, suggestion)
        let shape = RoundedRectangle(cornerRadius: Metrics.cardRadius - 2, style: .continuous)
        return VStack(alignment: .leading, spacing: 10) {
            VocabularySuggestionSummary(suggestion: suggestion, term: term.text)
            HStack(alignment: .center, spacing: 8) {
                if let note = notes[noteKey] {
                    Label(note, systemImage: "exclamationmark.circle")
                        .symbolRenderingMode(.monochrome)
                        .font(Typo.secondary)
                        .foregroundStyle(Mono.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .transition(.monoReveal(reduceMotion: reduceMotion))
                }
                Spacer()
                Button("Dismiss") {
                    store.dismissSuggestion(suggestion.phrase, for: term.id)
                    remove(suggestion, from: term)
                }
                    .buttonStyle(MonoActionButtonStyle(.outline, size: .small))
                    .accessibilityLabel("Dismiss \(suggestion.phrase)")
                Button("Add to Heard as") { approve(suggestion, for: term) }
                    .buttonStyle(MonoActionButtonStyle(.primary, size: .small))
                    .accessibilityLabel("Add \(suggestion.phrase) to Heard as for \(term.text)")
            }
            .monoAnimation(Motion.reveal, value: notes[noteKey])
        }
        .foregroundStyle(Mono.primaryText)
        .padding(12)
        .background(shape.fill(Mono.card))
        .overlay(shape.strokeBorder(Mono.cardBorder, lineWidth: 0.5))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(VocabularySuggestionSummary.accessibilityText(suggestion, term: term.text))
    }

    private static func noteKey(_ term: VocabularyTerm, _ suggestion: VocabularySuggestion) -> String {
        term.id.uuidString + "|" + suggestion.id
    }

    private func approve(_ suggestion: VocabularySuggestion, for term: VocabularyTerm) {
        switch store.learn(heard: suggestion.phrase, written: term.text) {
        case .addedAlternative, .addedTerm, .alreadyKnown:
            added += 1
            remove(suggestion, from: term)
        case .rejected(let reason):
            // Keep the row so the reason is readable; the user can still dismiss it.
            notes[Self.noteKey(term, suggestion)] = reason
        }
    }

    private func remove(_ suggestion: VocabularySuggestion, from term: VocabularyTerm) {
        withAnimation(Motion.reduced(Motion.reveal, reduceMotion: reduceMotion)) {
            guard let index = results.firstIndex(where: { $0.term.id == term.id }) else { return }
            results[index].suggestions.removeAll { $0.id == suggestion.id }
            if results[index].suggestions.isEmpty { results.remove(at: index) }
        }
    }

    /// Pure scan off the main actor; the dictionary pass after it needs the main actor
    /// (`SpellingLexicon`) and only sees the candidates. Dismissing the sheet cancels both.
    @MainActor private func scan() async {
        let terms = store.terms.filter(\.enabled)
        let known = store.terms
        let history = history
        let work = Task.detached(priority: .utility) {
            try VocabularySuggestions.scan(terms: terms, in: history, knownTerms: known,
                                           limit: VocabularySuggestions.candidatePool)
        }
        do {
            let raw = try await withTaskCancellationHandler {
                try await work.value
            } onCancel: { work.cancel() }
            guard !Task.isCancelled else { return }
            let lexicon = SpellingLexicon()
            results = raw.compactMap { result in
                let kept = VocabularySuggestions.filtered(result.suggestions, limit: 12) { lexicon.isKnownWord($0) }
                return kept.isEmpty ? nil : VocabularyScanResult(term: result.term, suggestions: kept)
            }
            foundAny = !results.isEmpty
            loaded = true
        } catch {
            // Cancellation is the only thrown outcome; reopening the sheet scans again.
        }
    }
}

/// Phrase, how often it was heard, why it was suggested, and the sentence it came from.
/// Shared by the per-term picker and the history scan so a suggestion reads the same in both.
struct VocabularySuggestionSummary: View {
    let suggestion: VocabularySuggestion
    let term: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(suggestion.phrase).font(Typo.body.weight(.medium))
                if suggestion.match == .sound {
                    // A spelling far from the term is only credible with the reason in view.
                    Text("Sounds like \(term)")
                        .font(Typo.secondary)
                        .foregroundStyle(Mono.secondaryText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule(style: .continuous).fill(Mono.fieldFill))
                }
                Spacer()
                Text(Self.occurrences(suggestion))
                    .font(Typo.secondary)
                    .foregroundStyle(Mono.secondaryText)
                    .monospacedDigit()
            }
            Text(suggestion.context)
                .font(Typo.secondary)
                .foregroundStyle(Mono.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Text(suggestion.date, format: .dateTime.day().month().year())
                .font(Typo.secondary)
                .foregroundStyle(Mono.tertiaryText)
        }
    }

    /// One key with a plural variation in the catalog ("1 occurrence" / "%lld occurrences").
    static func occurrences(_ suggestion: VocabularySuggestion) -> String {
        String(localized: "\(suggestion.occurrences) occurrences",
               comment: "How many times a misheard phrase appears in history")
    }

    static func accessibilityText(_ suggestion: VocabularySuggestion, term: String) -> String {
        let count = occurrences(suggestion)
        if suggestion.match == .sound {
            return String(localized: "\(suggestion.phrase), sounds like \(term), \(count). \(suggestion.context)",
                          comment: "Accessibility: phrase, vocabulary word, occurrence count, sentence it came from")
        }
        return String(localized: "\(suggestion.phrase), \(count). \(suggestion.context)",
                      comment: "Accessibility: phrase, occurrence count, sentence it came from")
    }
}
